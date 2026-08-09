package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"
)

// These tests drive the FFI bridge through its cgo-free do* functions, which is
// exactly why those live in client.go rather than core.go: the handle lifecycle
// and the poll semantics are the parts most likely to go wrong, and this way
// they are covered without building for a device.

func openHandle(t *testing.T) int64 {
	t.Helper()
	resp, err := doCoreOpen(coreOpenRequest{Path: filepath.Join(t.TempDir(), "account.db")})
	if err != nil {
		t.Fatalf("doCoreOpen: %v", err)
	}
	handle := resp.(*coreOpenResponse).Handle
	t.Cleanup(func() { doCoreClose(coreHandleRequest{Handle: handle}) }) //nolint:errcheck // best-effort teardown
	return handle
}

func setIdentity(t *testing.T, handle int64, server string) {
	t.Helper()
	if _, err := doCoreSetIdentity(coreSetIdentityRequest{
		Handle:     handle,
		AccountID:  "fz1account",
		Server:     server,
		RootPub:    []byte{1},
		RootPriv:   []byte{2},
		DeviceID:   "device-1",
		DevicePub:  []byte{3},
		DevicePriv: make([]byte, 64), // an ed25519-sized key; never verified here
	}); err != nil {
		t.Fatalf("doCoreSetIdentity: %v", err)
	}
}

// newStreamingHandle serves handler, opens a handle pointed at it, and tears
// both down in the one order that works.
//
// The order matters and is easy to get wrong: httptest.Server.Close waits for
// outstanding requests, and a stream request only ends when the core's context
// is cancelled. Closing the server first therefore deadlocks -- which a plain
// `defer srv.Close()` plus a t.Cleanup that closes the handle does, since defers
// run before cleanups. One cleanup doing both in sequence is the fix.
func newStreamingHandle(t *testing.T, handler http.HandlerFunc) int64 {
	t.Helper()
	srv := httptest.NewServer(handler)

	resp, err := doCoreOpen(coreOpenRequest{Path: filepath.Join(t.TempDir(), "account.db")})
	if err != nil {
		srv.Close()
		t.Fatalf("doCoreOpen: %v", err)
	}
	handle := resp.(*coreOpenResponse).Handle

	t.Cleanup(func() {
		doCoreClose(coreHandleRequest{Handle: handle}) //nolint:errcheck // best-effort teardown
		srv.Close()
	})

	setIdentity(t, handle, srv.URL)
	return handle
}

func poll(t *testing.T, handle int64, timeoutMS int) *corePollResponse {
	t.Helper()
	resp, err := doCorePoll(corePollRequest{Handle: handle, TimeoutMS: timeoutMS})
	if err != nil {
		t.Fatalf("doCorePoll: %v", err)
	}
	return resp.(*corePollResponse)
}

func TestCoreOpenGivesDistinctHandlesAndClosesCleanly(t *testing.T) {
	a, b := openHandle(t), openHandle(t)
	if a == b {
		t.Fatal("two opens returned the same handle")
	}

	if _, err := doCoreClose(coreHandleRequest{Handle: a}); err != nil {
		t.Fatalf("doCoreClose: %v", err)
	}
	// Closing twice must be harmless: a Dart-side teardown racing a hot restart
	// should not have to be careful.
	if _, err := doCoreClose(coreHandleRequest{Handle: a}); err != nil {
		t.Errorf("closing an already-closed handle should be a no-op, got %v", err)
	}
	// The other handle is untouched.
	if _, err := lookupHandle(b); err != nil {
		t.Errorf("closing one handle disturbed another: %v", err)
	}
}

func TestOperationsOnAnUnknownHandleSaySo(t *testing.T) {
	for name, call := range map[string]func() (any, error){
		"set identity": func() (any, error) { return doCoreSetIdentity(coreSetIdentityRequest{Handle: 9999}) },
		"stream start": func() (any, error) { return doCoreStreamStart(coreHandleRequest{Handle: 9999}) },
		"stream stop":  func() (any, error) { return doCoreStreamStop(coreHandleRequest{Handle: 9999}) },
		"poll":         func() (any, error) { return doCorePoll(corePollRequest{Handle: 9999}) },
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := call(); err == nil {
				t.Error("a stale handle is a caller bug and must be reported, not ignored")
			}
		})
	}
}

// Polling before anything is streaming is the ordinary state at startup, not an
// error -- and it has to report that the stream is not running so a Dart poll
// loop ends instead of spinning.
func TestPollWithoutAStreamReportsNotStreaming(t *testing.T) {
	handle := openHandle(t)
	got := poll(t, handle, 10)
	if got.Streaming {
		t.Error("nothing was started, so streaming must be false")
	}
	if len(got.Events) != 0 {
		t.Errorf("want no events, got %v", got.Events)
	}
}

func TestStreamStartIsIdempotent(t *testing.T) {
	handle := newStreamingHandle(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	})

	for i := 0; i < 3; i++ {
		if _, err := doCoreStreamStart(coreHandleRequest{Handle: handle}); err != nil {
			t.Fatalf("doCoreStreamStart: %v", err)
		}
	}
	// Starting again must not replace the channel, or the events already
	// buffered on the first one are lost -- and a second subscriber slot on the
	// server would make a backgrounded app stop getting push wakes.
	if got := poll(t, handle, 2000); len(got.Events) == 0 || got.Events[0].Kind != "connected" {
		t.Errorf("want the first stream's connected event, got %+v", got)
	}
}

// One FFI crossing should return the whole backlog: an event per crossing is
// pure overhead exactly when a reconnect has just delivered a pile of them.
func TestPollReturnsABatch(t *testing.T) {
	const frames = 5
	handle := newStreamingHandle(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		for i := 0; i < frames; i++ {
			data, _ := json.Marshal(map[string]any{
				"message_id":        fmt.Sprintf("m%d", i),
				"sender_account_id": "fz1a",
				"sender_device_id":  "d1",
				"sent_at":           "2026-08-07T09:00:00Z",
				"payload":           map[string]any{"v": 1},
			})
			fmt.Fprintf(w, "event: message\ndata: %s\n\n", data)
		}
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	})
	if _, err := doCoreStreamStart(coreHandleRequest{Handle: handle}); err != nil {
		t.Fatalf("doCoreStreamStart: %v", err)
	}

	// Collect until every frame has arrived, however the batches fall.
	seen := map[string]bool{}
	deadline := time.Now().Add(10 * time.Second)
	for len(seen) < frames && time.Now().Before(deadline) {
		for _, ev := range poll(t, handle, 500).Events {
			if ev.Kind == "message" {
				if ev.Message == nil {
					t.Fatal("a message event arrived without a message")
				}
				seen[ev.Message.MessageID] = true
			}
		}
	}
	if len(seen) != frames {
		t.Errorf("want all %d messages, got %d: %v", frames, len(seen), seen)
	}
}

// A clean end is a resume from background or a blip. The app's rule is that only
// a failed *connect attempt* reaches the user, so "disconnected" must not carry
// an error the Dart side would show.
func TestDisconnectedCarriesNoErrorText(t *testing.T) {
	handle := newStreamingHandle(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		// End immediately: that is what a blip looks like.
	})
	if _, err := doCoreStreamStart(coreHandleRequest{Handle: handle}); err != nil {
		t.Fatalf("doCoreStreamStart: %v", err)
	}

	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		for _, ev := range poll(t, handle, 500).Events {
			if ev.Kind == "disconnected" {
				if ev.Error != "" {
					t.Errorf("a clean disconnect must not carry error text, got %q", ev.Error)
				}
				return
			}
		}
	}
	t.Fatal("never saw a disconnected event")
}

func TestFailedAttemptCarriesTheReason(t *testing.T) {
	handle := newStreamingHandle(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte(`{"error":{"code":"unavailable","message":"down"}}`))
	})
	if _, err := doCoreStreamStart(coreHandleRequest{Handle: handle}); err != nil {
		t.Fatalf("doCoreStreamStart: %v", err)
	}

	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		for _, ev := range poll(t, handle, 500).Events {
			if ev.Kind == "failed" {
				if ev.Error == "" {
					t.Error("a failed attempt should say why -- the app logs it")
				}
				return
			}
		}
	}
	t.Fatal("never saw a failed event")
}

func TestStreamStopEndsPolling(t *testing.T) {
	handle := newStreamingHandle(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	})
	if _, err := doCoreStreamStart(coreHandleRequest{Handle: handle}); err != nil {
		t.Fatalf("doCoreStreamStart: %v", err)
	}
	if got := poll(t, handle, 2000); !got.Streaming {
		t.Fatal("stream should be running")
	}

	if _, err := doCoreStreamStop(coreHandleRequest{Handle: handle}); err != nil {
		t.Fatalf("doCoreStreamStop: %v", err)
	}
	if got := poll(t, handle, 10); got.Streaming {
		t.Error("after stopping, polling must report the stream as gone so the loop ends")
	}
	// Stopping twice is harmless, same as closing twice.
	if _, err := doCoreStreamStop(coreHandleRequest{Handle: handle}); err != nil {
		t.Errorf("stopping an already-stopped stream should be a no-op, got %v", err)
	}
}

// Closing a handle with a stream still running must not leave the goroutine
// behind holding a database that has just been closed underneath it.
func TestCloseStopsARunningStream(t *testing.T) {
	handle := newStreamingHandle(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	})
	if _, err := doCoreStreamStart(coreHandleRequest{Handle: handle}); err != nil {
		t.Fatalf("doCoreStreamStart: %v", err)
	}
	poll(t, handle, 2000)

	if _, err := doCoreClose(coreHandleRequest{Handle: handle}); err != nil {
		t.Fatalf("doCoreClose with a live stream: %v", err)
	}
	if _, err := lookupHandle(handle); err == nil {
		t.Error("the handle should be gone after closing")
	}
}

// A poll already blocked when the stream is stopped must come back promptly,
// not sit out its whole timeout. Dart's close() depends on it: the loop only
// notices it should end when the poll it is waiting on returns.
func TestStopUnblocksAPollInFlight(t *testing.T) {
	handle := newStreamingHandle(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	})
	if _, err := doCoreStreamStart(coreHandleRequest{Handle: handle}); err != nil {
		t.Fatalf("doCoreStreamStart: %v", err)
	}
	poll(t, handle, 2000) // drain the connected event

	done := make(chan struct{})
	go func() {
		defer close(done)
		doCorePoll(corePollRequest{Handle: handle, TimeoutMS: 20000}) //nolint:errcheck // the timing is the assertion
	}()

	time.Sleep(200 * time.Millisecond) // let the poll get in and block
	if _, err := doCoreStreamStop(coreHandleRequest{Handle: handle}); err != nil {
		t.Fatalf("doCoreStreamStop: %v", err)
	}

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("stopping the stream left a poll blocked -- Dart's close() would hang until the poll timed out")
	}
}
