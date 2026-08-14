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
	// notification.
	//
	// Set now and acted on when the receive loop moves in here, which happens
	// together with the UI switching to read from the core -- either half alone
	// leaves messages arriving somewhere nothing draws from. Held on the handle
	// rather than passed per envelope because that loop will run in its own
	// isolate, where nothing knows what the user is looking at.
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

	Outcome *pollOutcome `json:"outcome,omitempty"`

	// Error is present for "failed". A Go error cannot cross the boundary, so
	// this is its text -- for logging and for the app's own failure notice,
	// never for deciding anything.
	Error string `json:"error,omitempty"`

	// Code classifies that failure when it can be classified, because the
	// shell does have one thing to decide: whether this is worth a red banner.
	// It is not, when the server is merely away -- that retries itself and the
	// account is already dimmed. Without this the shell had only the text, so
	// it treated every failed connect as worth interrupting somebody over.
	Code string `json:"code,omitempty"`
}

// pollOutcome is what one envelope turned into, after HandleIncoming has
// already decided everything about it: decrypted, folded if it was a group
// fact, receipted, acknowledged. Deliberately not the envelope itself -- the
// shell has nothing left to decide, only somewhere to refresh and (sometimes)
// someone to tell.
type pollOutcome struct {
	// ChatID is which chat changed -- a peer account id or a group id, the one
	// namespace both share -- so the shell knows what to re-read. Empty for a
	// duplicate or a failed attempt: nothing changed, nothing to refresh.
	ChatID string `json:"chat_id,omitempty"`

	// Notify is whether this is worth interrupting the user for. False for the
	// ordinary "something changed, redraw the chat" case -- a receipt, a
	// non-invite group fact, a message into the chat already on screen.
	Notify bool `json:"notify,omitempty"`

	// Invitation: Notify is true because this was an invitation into a group
	// new to this account, not a message. Changes only the wording; the shell
	// still opens the group, not a message.
	Invitation bool `json:"invitation,omitempty"`

	// IsGroup: ChatID names a group rather than a peer -- res.Group != nil,
	// which is already known here and would otherwise have to be re-derived
	// on the Dart side by checking ChatID's version marker (see
	// client.IsGroupID), duplicating a protocol detail this side already
	// settled. A caller with a live AppState can tell the two apart another
	// way (state.groups.containsKey), but the background wake (push_manager
	// .dart's doCoreSync caller) has no such map to check against.
	IsGroup bool `json:"is_group,omitempty"`

	// Failure is why this envelope was not handled, for the shell to log.
	// Empty on success and on a duplicate, which is not a failure.
	//
	// Carried across rather than swallowed because swallowing it cost real
	// time three separate times in one afternoon: a message that fails to
	// decrypt is invisible from the app -- no error, no log, just a message
	// that never appears -- and every diagnosis started by rebuilding the
	// core with a throwaway log statement in this function. HandleIncoming
	// already returns a well-classified error (including, since the fix in
	// pkg/client/receive.go, the prekey-block failure that a fallback to the
	// existing session would otherwise mask); there is no reason for it to
	// stop here. Diagnostic only: nothing branches on it, and an envelope
	// that failed is still acknowledged or retried by exactly the rule above.
	Failure string `json:"failure,omitempty"`

	// AttachmentMessageID names the line this envelope stored, when that line
	// carried a picture. Empty otherwise, which is nearly always.
	//
	// Here so a foreground session can start the download the moment the
	// message lands rather than when its bubble is first looked at. That is an
	// optimisation over the lazy fetch and never a substitute: history, a
	// failed attempt and the background wake (which deliberately writes only
	// the inline thumbnail) all still rely on ImageAttachment asking for
	// itself. Said outright rather than left to be re-derived, so the shell
	// does not have to go rummaging in a transcript it has just refreshed to
	// find out whether there is anything to fetch.
	AttachmentMessageID string `json:"attachment_message_id,omitempty"`

	// SenderAccountID names who the failed envelope came from, since ChatID
	// is deliberately empty for one and a bare error text says nothing about
	// which conversation is broken.
	SenderAccountID string `json:"sender_account_id,omitempty"`
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
		out = append(out, convertEvent(entry, ev))
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
			out = append(out, convertEvent(entry, ev))
		default:
			return &corePollResponse{Events: out, Streaming: true}, nil
		}
	}
}

// receiveNetworkTimeout bounds the ack and the receipt a handled envelope
// triggers -- both best-effort, so a slow or dead connection delays the next
// poll iteration rather than the app.
const receiveNetworkTimeout = 15 * time.Second

func convertEvent(entry *coreHandle, ev client.StreamEvent) pollEvent {
	switch ev.Kind {
	case client.StreamConnected:
		return pollEvent{Kind: "connected"}
	case client.StreamMessage:
		entry.mu.Lock()
		openChatID := entry.openChatID
		entry.mu.Unlock()

		ctx, cancel := context.WithTimeout(context.Background(), receiveNetworkTimeout)
		defer cancel()
		outcome := handleAndAck(ctx, entry.client, ev.Message, client.ReceiveOptions{OpenChatID: openChatID})
		return pollEvent{Kind: "message", Outcome: &outcome}
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
			out.Code = errorCode(ev.Err)
		}
		return out
	default:
		return pollEvent{Kind: "unknown"}
	}
}

// handleAndAck runs one envelope through HandleIncoming and does everything a
// caller owes it from there: acknowledges it to the server per the rule
// HandleIncoming documents (any result, or a failure that has now been given
// up on), and sends back whatever receipt the result calls for -- HandleIncoming
// itself does no network I/O, so nothing else does either unless this does.
//
// Shared by the live poll loop (convertEvent, above) and the background sync
// entry point (doCoreSync, api.go) so the two consumers of a device's queue
// cannot drift on what "handled" means -- which is exactly the defect this
// whole item exists to remove.
func handleAndAck(ctx context.Context, c *client.Client, msg client.IncomingMessage, opts client.ReceiveOptions) pollOutcome {
	res, err := c.HandleIncoming(msg, opts)

	var decryptErr *client.DecryptError
	shouldAck := err == nil || (errors.As(err, &decryptErr) && decryptErr.GaveUp)
	if shouldAck {
		// Best-effort by design (see AckMessage): a lost ack means redelivery,
		// which the duplicate check on the next attempt absorbs.
		_ = c.AckMessage(ctx, msg.MessageID)
	}
	if err != nil {
		return pollOutcome{Failure: err.Error(), SenderAccountID: msg.SenderAccountID}
	}
	if res.Duplicate {
		return pollOutcome{}
	}

	sendReceiptFor(ctx, c, res)
	if res.Group != nil {
		// HandleIncoming folds the envelope but does no network I/O -- acting on
		// what it found about the sender's own view (a state-hash mismatch, an
		// outright sync request, holding no facts at all) is this caller's job,
		// same as the receipt above. Best-effort: a failed reconcile just means
		// the divergence is answered on the next envelope instead of this one.
		_ = c.ReconcileGroup(ctx, *res.Group, res.PeerAccountID)
	}

	out := pollOutcome{Notify: res.ShouldNotify}
	if res.StoredMessageID != "" && len(res.Content.Attachments) > 0 {
		out.AttachmentMessageID = res.StoredMessageID
	}
	if res.Group != nil {
		out.ChatID = res.Group.GroupID
		out.Invitation = res.Group.Invited
		out.IsGroup = true
	} else {
		out.ChatID = res.PeerAccountID
	}
	return out
}

// coreSyncResponse is what one background-wake sync found.
type coreSyncResponse struct {
	Outcomes []pollOutcome `json:"outcomes"`

	// Problems is best-effort housekeeping (see doCoreMaintain) that did not
	// work -- reported rather than failing the whole sync, since one part
	// failing (an unreachable server for the prekey top-up, say) must not stop
	// the messages that were fetched from being handled.
	Problems []string `json:"problems,omitempty"`
}

// doCoreSync is the background-wake counterpart to the live poll loop: fetch
// whatever is queued for this device, run each envelope through the same
// HandleIncoming-then-ack-then-receipt path convertEvent's "message" case
// uses, and report what came of each.
//
// A separate entry point rather than reusing doCorePoll, because a wake has no
// open stream to poll -- only a queue to drain once. Sharing handleAndAck with
// the live path is the point: a message that arrives while the app is
// backgrounded has to be decided by exactly the same rules as one that arrives
// while it is open, or the two paths drift back apart into the two
// implementations this whole item exists to remove -- which is exactly what
// the previous, Dart-side background sync did.
func doCoreSync(req coreHandleRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}

	fetchCtx, cancel := callContext()
	msgs, err := entry.client.FetchMessages(fetchCtx)
	cancel()
	if err != nil {
		return nil, err
	}

	entry.mu.Lock()
	openChatID := entry.openChatID
	entry.mu.Unlock()

	outcomes := make([]pollOutcome, 0, len(msgs))
	for _, msg := range msgs {
		ctx, cancel := context.WithTimeout(context.Background(), receiveNetworkTimeout)
		outcomes = append(outcomes, handleAndAck(ctx, entry.client, msg, client.ReceiveOptions{OpenChatID: openChatID}))
		cancel()
	}

	// The same housekeeping a live reconnect does (see doCoreMaintain): a wake
	// is exactly the kind of fresh-connection moment it exists for, and the
	// prekey top-up in particular must run *somewhere* for an account that is
	// only ever opened by a wake and never brought to the foreground.
	// A value, not a pointer: doCoreMaintain returns maintainResponse itself.
	// Asserting for the pointer silently never matched, which left Problems
	// empty on every background wake -- the one path where nothing else reports
	// a failed prekey top-up.
	var problems []string
	if maintained, err := doCoreMaintain(coreHandleRequest{Handle: req.Handle}); err == nil {
		if m, ok := maintained.(maintainResponse); ok {
			problems = m.Problems
		}
	}

	return coreSyncResponse{Outcomes: outcomes, Problems: problems}, nil
}

// sendReceiptFor confirms delivery back to whoever is owed it. Best-effort and
// swallowed on failure: a receipt is a UI nicety on the recipient's side, never
// something the ratchet or the transcript depends on, and there is nowhere
// here to retry it from -- see docs/design/23-shared-client-core.md.
func sendReceiptFor(ctx context.Context, c *client.Client, res client.ReceiveResult) {
	if res.Group != nil && res.Group.DeliveredUpTo != nil {
		_ = c.SendGroupReceipt(ctx, res.Group.GroupID, res.PeerAccountID, client.ReceiptDelivered, *res.Group.DeliveredUpTo)
		return
	}
	if res.DeliveredUpTo != nil {
		_ = c.SendReceipt(ctx, res.PeerAccountID, client.ReceiptDelivered, *res.DeliveredUpTo)
	}
}
