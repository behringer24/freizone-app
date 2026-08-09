package main

// The bridge from freizone-server's pkg/client to the FFI boundary (SRV-23).
//
// Deliberately cgo-free, like logic.go and for the same reason: everything that
// can be tested on the host lives outside core.go, so the handle lifecycle and
// the poll semantics below are covered by ordinary `go test` rather than only by
// running the app.
//
// The core's own API is idiomatic Go -- channels and contexts -- because that is
// what its other consumers want. Nothing of that shape can cross cgo, so this
// file is where it is adapted: an integer handle stands in for a *client.Client,
// and CorePoll turns the event channel into a blocking call Dart can make from
// an isolate. The adaptation belongs here rather than in the core, so a bot
// linking pkg/client directly never pays for it.

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/behringer24/freizone-server/pkg/client"
)

// coreHandle is one open account plus whatever is running against it.
type coreHandle struct {
	client *client.Client

	// mu guards the stream fields, which CoreStreamStart/Stop mutate while
	// CorePoll reads them.
	mu     sync.Mutex
	cancel context.CancelFunc
	events <-chan client.StreamEvent

	// openChatID is the chat on screen, the one thing that suppresses a
	// notification. Held here rather than passed per envelope, because the
	// receive loop runs in its own isolate and cannot know what the user is
	// looking at.
	openChatID string
}

var (
	handlesMu  sync.Mutex
	handles    = map[int64]*coreHandle{}
	nextHandle int64
)

// lookupHandle resolves a handle, or reports the misuse plainly. A stale handle
// is a caller bug rather than a runtime condition, so it says so instead of
// failing vaguely later.
func lookupHandle(h int64) (*coreHandle, error) {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	entry, ok := handles[h]
	if !ok {
		return nil, fmt.Errorf("core handle %d is not open", h)
	}
	return entry, nil
}

type coreOpenRequest struct {
	// Path is the account database file. Dart supplies it, because only the
	// platform side knows where an app may write.
	Path string `json:"path"`
}

type coreOpenResponse struct {
	Handle int64 `json:"handle"`
}

// doCoreOpen opens (creating and migrating if needed) one account database and
// returns a handle for it. One handle per account: two accounts are two files
// and two handles, never one connection with a discriminator.
func doCoreOpen(req coreOpenRequest) (any, error) {
	if req.Path == "" {
		return nil, fmt.Errorf("opening core: no database path given")
	}
	c, err := client.Open(req.Path)
	if err != nil {
		return nil, err
	}

	handlesMu.Lock()
	defer handlesMu.Unlock()
	nextHandle++
	handles[nextHandle] = &coreHandle{client: c}
	return &coreOpenResponse{Handle: nextHandle}, nil
}

type coreHandleRequest struct {
	Handle int64 `json:"handle"`
}

// doCoreClose stops anything running against the handle and closes it. Safe to
// call for a handle already gone, so a Dart-side teardown racing a hot restart
// does not have to be careful.
func doCoreClose(req coreHandleRequest) (any, error) {
	handlesMu.Lock()
	entry, ok := handles[req.Handle]
	delete(handles, req.Handle)
	handlesMu.Unlock()
	if !ok {
		return struct{}{}, nil
	}

	entry.stopStream()
	if err := entry.client.Close(); err != nil {
		return nil, err
	}
	return struct{}{}, nil
}

type coreSetIdentityRequest struct {
	Handle int64 `json:"handle"`

	AccountID string `json:"account_id"`
	Server    string `json:"server"`

	RootPub  []byte `json:"root_pub"`
	RootPriv []byte `json:"root_priv"`

	DeviceID   string `json:"device_id"`
	DevicePub  []byte `json:"device_pub"`
	DevicePriv []byte `json:"device_priv"`

	DHIdentityPub  []byte `json:"dh_identity_pub,omitempty"`
	DHIdentityPriv []byte `json:"dh_identity_priv,omitempty"`

	SignedPrekeyID   uint32 `json:"signed_prekey_id,omitempty"`
	SignedPrekeyPub  []byte `json:"signed_prekey_pub,omitempty"`
	SignedPrekeyPriv []byte `json:"signed_prekey_priv,omitempty"`

	NextSignedPrekeyID  uint32 `json:"next_signed_prekey_id,omitempty"`
	NextOneTimePrekeyID uint32 `json:"next_otpk_key_id,omitempty"`

	RecoveryBackupDone bool   `json:"recovery_backup_done,omitempty"`
	PushMechanism      string `json:"push_mechanism,omitempty"`
}

// doCoreSetIdentity writes the account's key material into the core.
//
// This is what lets the core do useful work before the app's own state layer
// has been migrated into it: the identity is handed across once at startup, and
// from then on the core can sign its own requests and hold its own stream.
func doCoreSetIdentity(req coreSetIdentityRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	if err := entry.client.SetIdentity(client.Identity{
		AccountID:           req.AccountID,
		Server:              req.Server,
		RootPub:             req.RootPub,
		RootPriv:            req.RootPriv,
		DeviceID:            req.DeviceID,
		DevicePub:           req.DevicePub,
		DevicePriv:          req.DevicePriv,
		DHIdentityPub:       req.DHIdentityPub,
		DHIdentityPriv:      req.DHIdentityPriv,
		SignedPrekeyID:      req.SignedPrekeyID,
		SignedPrekeyPub:     req.SignedPrekeyPub,
		SignedPrekeyPriv:    req.SignedPrekeyPriv,
		NextSignedPrekeyID:  req.NextSignedPrekeyID,
		NextOneTimePrekeyID: req.NextOneTimePrekeyID,
		RecoveryBackupDone:  req.RecoveryBackupDone,
		PushMechanism:       req.PushMechanism,
	}); err != nil {
		return nil, err
	}
	return struct{}{}, nil
}

// doCoreStreamStart opens the message stream. Starting one that is already
// running is a no-op, mirroring the app's own guard: a screen rebuilding must
// not be able to open a second subscriber slot on the server.
func doCoreStreamStart(req coreHandleRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}

	entry.mu.Lock()
	defer entry.mu.Unlock()
	if entry.cancel != nil {
		return struct{}{}, nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	entry.cancel = cancel
	entry.events = entry.client.Stream(ctx, client.StreamPolicy{})
	return struct{}{}, nil
}

// doCoreStreamStop closes the stream and releases this device's subscriber slot,
// so a message arriving afterwards triggers a push wake instead of being
// delivered into a stream nobody is reading.
func doCoreStreamStop(req coreHandleRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	entry.stopStream()
	return struct{}{}, nil
}

func (e *coreHandle) stopStream() {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.cancel == nil {
		return
	}
	e.cancel()
	e.cancel = nil
	e.events = nil
}

type corePollRequest struct {
	Handle int64 `json:"handle"`

	// TimeoutMS bounds the wait for the *first* event. Anything already
	// buffered behind it comes back in the same batch without waiting.
	TimeoutMS int `json:"timeout_ms"`
}

// pollEvent is one stream event in the shape that can cross cgo. Kind is a
// string rather than the core's integer enum so a Dart build and a core build
// that disagree about the set fail visibly on an unknown name instead of
// silently reinterpreting a number.
type pollEvent struct {
	Kind string `json:"kind"`

	Message *pollMessage `json:"message,omitempty"`

	// Error is present for "failed". A Go error cannot cross the boundary, so
	// this is its text -- for logging and for the app's own failure notice,
	// never for deciding anything.
	Error string `json:"error,omitempty"`
}

// pollMessage is what became of one envelope, not the envelope itself.
//
// The core opens it, files it and decides what follows; the shell is told the
// outcome. That is the point of the swap -- an envelope has to be handled by
// whoever decrypts it, because the ratchet has advanced and the id is marked by
// the time anybody looks at the payload, so handing one up unprocessed risks
// losing it for good.
type pollMessage struct {
	// ChatID is where it belongs: a peer account id, or a group id.
	ChatID          string `json:"chat_id"`
	SenderAccountID string `json:"sender_account_id"`

	// MessageID is the stored transcript line, empty for everything that is
	// never shown -- a receipt, a re-key, group membership, a blocked sender.
	MessageID string `json:"message_id,omitempty"`

	// Notify: the user should be told. Already accounts for the chat on screen.
	Notify bool `json:"notify,omitempty"`

	// Invitation marks the one group event worth interrupting somebody for.
	Invitation bool `json:"invitation,omitempty"`

	// Group is true when ChatID names a group, so the shell can open the right
	// screen without parsing an id.
	Group bool `json:"group,omitempty"`

	// Preview is the text a notification shows, empty when there is nothing to
	// show for it.
	Preview string `json:"preview,omitempty"`
}

type corePollResponse struct {
	// Events is empty when the timeout expired with nothing to report, which is
	// the ordinary case for an idle chat and must not read as an error.
	Events []pollEvent `json:"events"`

	// Streaming is false once the stream has stopped for good, so the caller's
	// poll loop knows to end rather than spin against a closed channel.
	Streaming bool `json:"streaming"`
}

// doCorePoll waits for stream activity and returns it as a batch.
//
// A batch rather than a single event on purpose: an FFI crossing per message is
// pure overhead when a reconnect has just delivered a backlog, and draining
// what is already buffered costs nothing. Blocking is why Dart calls this from
// an isolate -- it must never run on the UI thread.
func doCorePoll(req corePollRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}

	entry.mu.Lock()
	events := entry.events
	entry.mu.Unlock()

	if events == nil {
		return &corePollResponse{Events: []pollEvent{}, Streaming: false}, nil
	}

	timeout := time.Duration(req.TimeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = 25 * time.Second
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()

	out := []pollEvent{}
	select {
	case ev, ok := <-events:
		if !ok {
			return &corePollResponse{Events: out, Streaming: false}, nil
		}
		out = append(out, entry.convertEvent(ev))
	case <-timer.C:
		return &corePollResponse{Events: out, Streaming: true}, nil
	}

	// Drain the rest of the backlog without waiting for more.
	for {
		select {
		case ev, ok := <-events:
			if !ok {
				return &corePollResponse{Events: out, Streaming: false}, nil
			}
			out = append(out, entry.convertEvent(ev))
		default:
			return &corePollResponse{Events: out, Streaming: true}, nil
		}
	}
}

func (e *coreHandle) convertEvent(ev client.StreamEvent) pollEvent {
	switch ev.Kind {
	case client.StreamConnected:
		return pollEvent{Kind: "connected"}
	case client.StreamMessage:
		return e.handleIncoming(ev.Message)
	case client.StreamDisconnected:
		// Deliberately carries no error text even when one is set. A stream
		// that came up and then ended is a resume from background or a blip,
		// and the app's own rule is that only a *failed connect attempt*
		// reaches the user -- a clean end just reconnects.
		return pollEvent{Kind: "disconnected"}
	case client.StreamFailed:
		out := pollEvent{Kind: "failed"}
		if ev.Err != nil {
			out.Error = ev.Err.Error()
		}
		return out
	default:
		return pollEvent{Kind: "unknown"}
	}
}

// handleIncoming opens one envelope, files it, and reports what came of it.
//
// Everything that follows from an envelope happens here rather than above the
// boundary: decrypt, store, reconcile a group's facts, acknowledge it away.
// A caller that merely forwarded it would have to be trusted to finish the job,
// and the one caller that cannot be -- a background wake with no screen -- is
// exactly the one that must.
//
// A failure never stops the loop. A poison envelope is given up on after enough
// attempts and acknowledged away by the core; anything else is reported as a
// failed event and the next envelope is tried.
func (e *coreHandle) handleIncoming(msg client.IncomingMessage) pollEvent {
	e.mu.Lock()
	openChat := e.openChatID
	e.mu.Unlock()

	res, err := e.client.HandleIncoming(msg, client.ReceiveOptions{OpenChatID: openChat})
	if err != nil {
		var fail *client.DecryptError
		if errors.As(err, &fail) && fail.GaveUp {
			// Retried enough times to be certain it will never open: drop it
			// from the queue rather than let it block everything behind it.
			e.ack(msg.MessageID)
		}
		return pollEvent{Kind: "failed", Error: err.Error()}
	}
	e.ack(msg.MessageID)

	out := pollMessage{ChatID: res.PeerAccountID, SenderAccountID: res.PeerAccountID}
	if res.Group != nil && res.Group.GroupID != "" {
		out.ChatID, out.Group = res.Group.GroupID, true
		out.Invitation = res.Group.Invited
		// Reconciling is a send, so it belongs to the loop rather than to the
		// decrypt: the facts we hold may be behind the sender's, or they may
		// be asking for ours.
		ctx, cancel := callContext()
		if rerr := e.client.ReconcileGroup(ctx, *res.Group, res.PeerAccountID); rerr != nil {
			cancel()
			return pollEvent{Kind: "message", Message: &out, Error: rerr.Error()}
		}
		cancel()
	}
	out.MessageID = res.StoredMessageID
	out.Notify = res.ShouldNotify
	if res.StoredMessageID != "" {
		out.Preview = res.Content.Text
	}
	e.confirmDelivery(res)
	return pollEvent{Kind: "message", Message: &out}
}

// ack drops an envelope from the server queue, which is the only thing that
// drains it. Best effort: a lost acknowledgement means redelivery, which the
// duplicate check is there to absorb.
func (e *coreHandle) ack(messageID string) {
	ctx, cancel := callContext()
	defer cancel()
	_ = e.client.AckMessage(ctx, messageID)
}

// confirmDelivery tells the sender their message arrived.
//
// Delivered, never read: reading is something a person does, and the shell
// reports it when a chat is actually on screen. Best effort -- a receipt that
// does not go out costs a tick, never the message.
func (e *coreHandle) confirmDelivery(res client.ReceiveResult) {
	ctx, cancel := callContext()
	defer cancel()

	if res.Group != nil && res.Group.DeliveredUpTo != nil {
		_ = e.client.SendGroupReceipt(ctx, res.Group.GroupID, res.PeerAccountID,
			client.ReceiptDelivered, *res.Group.DeliveredUpTo)
		return
	}
	if res.DeliveredUpTo != nil {
		_ = e.client.SendReceipt(ctx, res.PeerAccountID, client.ReceiptDelivered, *res.DeliveredUpTo)
	}
}
