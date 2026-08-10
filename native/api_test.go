package main

import (
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/behringer24/freizone-server/pkg/client"
	"github.com/behringer24/freizone-server/pkg/group"
)

// The FFI surface, tested where it can be: these are the cgo-free halves of the
// exported calls, so what a screen would see is checked by ordinary `go test`
// rather than only by running the app.

// offlineHandle opens an account with an identity but no server worth reaching
// -- enough for everything that reads state rather than fetching it.
func offlineHandle(t *testing.T) (int64, *client.Client) {
	t.Helper()
	resp, err := doCoreOpen(coreOpenRequest{Path: filepath.Join(t.TempDir(), "account")})
	if err != nil {
		t.Fatalf("doCoreOpen: %v", err)
	}
	handle := resp.(*coreOpenResponse).Handle
	t.Cleanup(func() { doCoreClose(coreHandleRequest{Handle: handle}) }) //nolint:errcheck

	setIdentity(t, handle, "https://home.test")
	entry, err := lookupHandle(handle)
	if err != nil {
		t.Fatalf("lookupHandle: %v", err)
	}
	return handle, entry.client
}

func decodeAs[T any](t *testing.T, data any) T {
	t.Helper()
	raw, err := json.Marshal(data)
	if err != nil {
		t.Fatalf("marshalling: %v", err)
	}
	var out T
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("decoding: %v", err)
	}
	return out
}

// The chat list is one list. Peers and groups share a shape and a clock,
// because that is what a screen draws -- merging two shapes on the Dart side
// would move the sorting somewhere with less to sort with.
func TestChatListMergesPeersAndGroupsByOneClock(t *testing.T) {
	handle, c := offlineHandle(t)

	older := time.Date(2026, 8, 9, 10, 0, 0, 0, time.UTC)
	newer := time.Date(2026, 8, 9, 12, 0, 0, 0, time.UTC)

	if err := c.PutConversation(client.Conversation{
		PeerAccountID: "qpeeraccountid000000x", PeerServer: "https://home.test",
		LastActivityAt: &older, HasUnread: true,
	}); err != nil {
		t.Fatalf("PutConversation: %v", err)
	}
	if err := c.AppendMessage("qpeeraccountid000000x", client.Message{
		ID: "m1", Text: "from a peer", Timestamp: older,
		Kind: client.MessageNormal, SendState: client.SendSent,
	}); err != nil {
		t.Fatalf("AppendMessage: %v", err)
	}

	groupID := "8groupaccountid00000x"
	if err := c.PutGroupChat(client.GroupChat{GroupID: groupID, LastActivityAt: &newer}); err != nil {
		t.Fatalf("PutGroupChat: %v", err)
	}
	if err := c.AppendMessage(groupID, client.Message{
		ID: "g1", Text: "in the group", Timestamp: newer, SenderAccountID: "qsomebodyelse0000000x",
		Kind: client.MessageNormal, SendState: client.SendSent,
	}); err != nil {
		t.Fatalf("AppendMessage: %v", err)
	}

	raw, err := doCoreChats(coreHandleRequest{Handle: handle})
	if err != nil {
		t.Fatalf("doCoreChats: %v", err)
	}
	chats := decodeAs[[]chatSummary](t, raw)
	if len(chats) != 2 {
		t.Fatalf("want both chats in one list, got %d: %+v", len(chats), chats)
	}
	if chats[0].ChatID != groupID {
		t.Errorf("newest first: want the group at the top, got %q", chats[0].ChatID)
	}
	if !chats[0].Group {
		t.Error("the group row must say it is one, so the shell need not parse an id")
	}
	// The preview saves a transcript read per row, which is the point of
	// carrying it at all.
	if chats[0].Preview != "in the group" || chats[0].PreviewSender != "qsomebodyelse0000000x" {
		t.Errorf("group preview: %+v", chats[0])
	}
	if chats[1].Preview != "from a peer" || !chats[1].HasUnread {
		t.Errorf("peer row: %+v", chats[1])
	}
}

// An attachment crosses as metadata and a path, never as a key and never as
// bytes. The key is the one secret in a message the shell has no use for.
func TestAttachmentsCrossWithoutTheirKey(t *testing.T) {
	handle, c := offlineHandle(t)
	chatID := "qpeeraccountid000000x"

	if err := c.AppendMessage(chatID, client.Message{
		ID: "m1", Text: "look", Timestamp: time.Now().UTC(),
		Kind: client.MessageNormal, SendState: client.SendSent,
		Attachments: []client.Attachment{{
			Kind: "image", BlobID: "blob-1", Key: []byte("this must not cross"),
			MimeType: "image/jpeg", Width: 800, Height: 600,
		}},
	}); err != nil {
		t.Fatalf("AppendMessage: %v", err)
	}

	raw, err := doCoreMessages(coreMessagesRequest{Handle: handle, ChatID: chatID})
	if err != nil {
		t.Fatalf("doCoreMessages: %v", err)
	}
	encoded, err := json.Marshal(raw)
	if err != nil {
		t.Fatalf("marshalling: %v", err)
	}
	if string(encoded) == "" {
		t.Fatal("nothing came back")
	}
	if containsBytes(encoded, "this must not cross") {
		t.Fatal("the attachment key crossed the boundary")
	}

	msgs := decodeAs[[]messageDTO](t, raw)
	if len(msgs) != 1 || len(msgs[0].Attachments) != 1 {
		t.Fatalf("want one message with one attachment, got %+v", msgs)
	}
	att := msgs[0].Attachments[0]
	if att.BlobID != "blob-1" || att.Width != 800 || att.Pending {
		t.Errorf("attachment metadata: %+v", att)
	}

	// The thumbnail is asked for by path, and answering costs no download.
	pathRaw, err := doCoreAttachmentPath(coreAttachmentRequest{Handle: handle, ChatID: chatID, MessageID: "m1", Thumb: true})
	if err != nil {
		t.Fatalf("doCoreAttachmentPath: %v", err)
	}
	if decodeAs[attachmentPathResponse](t, pathRaw).Path == "" {
		t.Error("a thumbnail path must be answerable without fetching anything")
	}
}

// A one-to-one attachment's blob lives on this side's own server, never the
// sender's -- see pkg/client/blobs.go's UploadAttachment: the sender
// federated-uploads it to the *recipient's* server precisely so the
// recipient never has to reach back to the sender's. Passing
// Conversation.PeerServer (the sender's server) to EnsureAttachment sends
// the fetch federated to a server that was never handed the blob at all --
// found live, SRV-23, a picture over a genuinely federated 1:1 conversation
// (q3up8@chat.behringer24.de -> qrqxg@chatcentral.de) came back 401 instead
// of the picture. doCoreAttachmentPath must always reach for this side's own
// server for a one-to-one chat, whatever the sender's happens to be.
func TestOneToOneAttachmentFetchesFromOwnServerNotTheSenders(t *testing.T) {
	handle, c := offlineHandle(t)
	chatID := "qpeeraccountid000000x"

	// A federated peer: their server, not ours (offlineHandle's is
	// https://home.test), which is exactly the shape that misrouted the
	// download when this was still a live bug.
	if err := c.PutConversation(client.Conversation{
		PeerAccountID: chatID,
		PeerServer:    "https://elsewhere.test",
	}); err != nil {
		t.Fatalf("PutConversation: %v", err)
	}
	if err := c.AppendMessage(chatID, client.Message{
		ID: "m1", Text: "look", Timestamp: time.Now().UTC(),
		Kind: client.MessageNormal, SendState: client.SendSent,
		Attachments: []client.Attachment{{
			Kind: "image", BlobID: "blob-1", Key: []byte("key"),
			MimeType: "image/jpeg", Width: 800, Height: 600,
		}},
	}); err != nil {
		t.Fatalf("AppendMessage: %v", err)
	}

	// Neither server exists, so this fails either way -- what matters is
	// *which* host it failed to reach.
	_, err := doCoreAttachmentPath(coreAttachmentRequest{Handle: handle, ChatID: chatID, MessageID: "m1"})
	if err == nil {
		t.Fatal("want an error against a server that does not exist, got none")
	}
	if strings.Contains(err.Error(), "elsewhere.test") {
		t.Errorf("fetched from the sender's server instead of this side's own: %v", err)
	}
	if !strings.Contains(err.Error(), "home.test") {
		t.Errorf("want the fetch aimed at this side's own server (home.test), got: %v", err)
	}
}

// An attachment that never finished uploading is marked, so a bubble shows the
// local preview and a spinner rather than a broken picture.
func TestAPendingAttachmentSaysSo(t *testing.T) {
	handle, c := offlineHandle(t)
	chatID := "qpeeraccountid000000x"
	if err := c.AppendMessage(chatID, client.Message{
		ID: "m1", Timestamp: time.Now().UTC(), Mine: true,
		Kind: client.MessageNormal, SendState: client.SendPending,
		Attachments: []client.Attachment{{Kind: "image", MimeType: "image/jpeg"}},
	}); err != nil {
		t.Fatalf("AppendMessage: %v", err)
	}
	raw, err := doCoreMessages(coreMessagesRequest{Handle: handle, ChatID: chatID})
	if err != nil {
		t.Fatalf("doCoreMessages: %v", err)
	}
	msgs := decodeAs[[]messageDTO](t, raw)
	if !msgs[0].Attachments[0].Pending {
		t.Error("an attachment with no blob has not been uploaded and must say so")
	}
	// And its path answers empty rather than failing: a picture nobody has
	// fetched is the normal state, not an error.
	pathRaw, err := doCoreAttachmentPath(coreAttachmentRequest{Handle: handle, ChatID: chatID, MessageID: "m1"})
	if err != nil {
		t.Fatalf("doCoreAttachmentPath: %v", err)
	}
	if decodeAs[attachmentPathResponse](t, pathRaw).Path != "" {
		t.Error("there is nothing to point at yet")
	}
}

// The open chat is held by the core, because the receive loop runs where
// nothing knows what the user is looking at.
func TestTheOpenChatSuppressesItsOwnNotification(t *testing.T) {
	handle, _ := offlineHandle(t)
	entry, err := lookupHandle(handle)
	if err != nil {
		t.Fatalf("lookupHandle: %v", err)
	}
	if _, err := doCoreSetOpenChat(coreOpenChatRequest{Handle: handle, ChatID: "qpeeraccountid000000x"}); err != nil {
		t.Fatalf("doCoreSetOpenChat: %v", err)
	}
	entry.mu.Lock()
	open := entry.openChatID
	entry.mu.Unlock()
	if open != "qpeeraccountid000000x" {
		t.Errorf("open chat: want the one that was set, got %q", open)
	}
}

// Housekeeping is best-effort: one part failing must not stop the others, so
// what went wrong is reported rather than returned.
func TestMaintenanceReportsProblemsRatherThanFailing(t *testing.T) {
	// A server that refuses everything, which is what a phone on a captive
	// network meets.
	handle := newStreamingHandle(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	})
	entry, err := lookupHandle(handle)
	if err != nil {
		t.Fatalf("lookupHandle: %v", err)
	}
	// A signed prekey has to be on file for a top-up to be the right call at
	// all -- without one the core short-circuits, and the test would be
	// watching a call that never reached the network.
	id, err := entry.client.Identity()
	if err != nil {
		t.Fatalf("Identity: %v", err)
	}
	id.SignedPrekeyPub = make([]byte, 32)
	if err := entry.client.SetIdentity(id); err != nil {
		t.Fatalf("SetIdentity: %v", err)
	}

	raw, err := doCoreMaintain(coreHandleRequest{Handle: handle})
	if err != nil {
		t.Fatalf("maintenance must not fail outright: %v", err)
	}
	out := decodeAs[maintainResponse](t, raw)
	if len(out.Problems) == 0 {
		t.Fatal("nothing worked, so something should have been reported")
	}
	if out.PrekeysToppedUp {
		t.Error("the prekey top-up cannot have succeeded against this server")
	}
}

// A chat id says which kind it is, which is what lets one send call serve both.
func TestChatIdsDistinguishGroupsFromPeers(t *testing.T) {
	if client.IsGroupID("qpeeraccountid000000x") {
		t.Error("an account id was read as a group")
	}
	if !client.IsGroupID(groupIDForTest(t)) {
		t.Error("a group id was not recognised")
	}
}

// A retry dispatches on the chat id, same as a send -- proven here by which
// error comes back for a message that was never sent (no network needed:
// each function fails before touching one), since RetryMessage and
// RetryGroupMessage phrase "no such message" differently.
func TestDoCoreRetryDispatchesOnChatID(t *testing.T) {
	handle, _ := offlineHandle(t)

	_, err := doCoreRetry(coreRetryRequest{Handle: handle, ChatID: "qpeeraccountid000000x", MessageID: "m1"})
	if err == nil || !strings.Contains(err.Error(), "in the chat with") {
		t.Errorf("a peer id should dispatch to RetryMessage, got: %v", err)
	}

	_, err = doCoreRetry(coreRetryRequest{Handle: handle, ChatID: groupIDForTest(t), MessageID: "m1"})
	if err == nil || !strings.Contains(err.Error(), "in group") {
		t.Errorf("a group id should dispatch to RetryGroupMessage, got: %v", err)
	}
}

func containsBytes(haystack []byte, needle string) bool {
	return len(needle) > 0 && len(haystack) >= len(needle) &&
		indexOf(string(haystack), needle) >= 0
}

func indexOf(haystack, needle string) int {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return i
		}
	}
	return -1
}

// groupIDForTest mints a real group id, since only the version marker inside
// tells one from an account id.
func groupIDForTest(t *testing.T) string {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	id, err := group.DeriveID(pub)
	if err != nil {
		t.Fatalf("deriving group id: %v", err)
	}
	return id
}
