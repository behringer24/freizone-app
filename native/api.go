package main

import (
	"context"
	"fmt"
	"os"
	"sort"
	"time"

	"github.com/behringer24/freizone-server/pkg/client"
	"github.com/behringer24/freizone-server/pkg/group"
)

// The core's API as it crosses cgo.
//
// Shaped around what a screen asks for rather than mirroring every method the
// library has. A crossing costs a JSON encode, a copy and a decode, so "give me
// the chat list" is one call and not one per conversation -- while anything the
// shell can do better stays on its side of the boundary. Attachment bytes are
// the clearest case: they travel as a *path*, because moving several megabytes
// through a JSON envelope to reach a file reader that is already there would be
// silly.
//
// Everything here is synchronous and handle-based. Blocking calls -- the poll,
// anything that touches the network -- are called from a Dart isolate; that is
// the shell's problem and deliberately not modelled here.

// callTimeout bounds any single network-touching call, so a screen waiting on
// one cannot hang forever behind a server that accepted a connection and then
// went quiet.
const callTimeout = 30 * time.Second

func callContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), callTimeout)
}

// --- chats -----------------------------------------------------------------

// chatSummary is one row of the chat list. Peers and groups in one shape,
// because a chat list shows them in one list ordered by one clock, and making
// the shell merge two shapes would just move the sorting somewhere it has less
// to sort with.
type chatSummary struct {
	ChatID string `json:"chat_id"`
	Group  bool   `json:"group"`

	// Title is the group's name, empty for a peer -- whose display name is the
	// shell's business, since it comes from a local address book the core has
	// no part in.
	Title string `json:"title,omitempty"`
	Topic string `json:"topic,omitempty"`

	PeerServer string `json:"peer_server,omitempty"`

	LastActivityAt string `json:"last_activity_at,omitempty"`
	HasUnread      bool   `json:"has_unread,omitempty"`

	// Preview is the last line, so a list does not have to read a transcript
	// per row to draw itself.
	Preview       string `json:"preview,omitempty"`
	PreviewMine   bool   `json:"preview_mine,omitempty"`
	PreviewSender string `json:"preview_sender,omitempty"`

	Blocked         bool `json:"blocked,omitempty"`
	PendingApproval bool `json:"pending_approval,omitempty"`

	// PeerGone (SRV-29): the peer's account, not merely a device, was
	// confirmed gone by asking their server. One-to-one only, like the two
	// watermarks below -- a group expresses this as a fact in the member
	// list instead (see freizone-server's recordMemberGone).
	PeerGone bool `json:"peer_gone,omitempty"`

	// Members and Invited describe a group at a glance. Joined counts only
	// members who accepted, which is what a header shows.
	Members int  `json:"members,omitempty"`
	Invited bool `json:"invited,omitempty"`

	Dissolved bool `json:"dissolved,omitempty"`

	// PinnedMessageIDs and the two watermarks are what a screen needs and the
	// summary would otherwise force a second call for. Cheap here, because the
	// transcript has already been read for the preview.
	PinnedMessageIDs []string `json:"pinned_message_ids,omitempty"`

	// PeerDeliveredUpTo and PeerReadUpTo are how far the peer has got with our
	// messages, for the ticks. One-to-one only: a group has one per member and
	// they come with the membership.
	PeerDeliveredUpTo string `json:"peer_delivered_up_to,omitempty"`
	PeerReadUpTo      string `json:"peer_read_up_to,omitempty"`
}

func doCoreChats(req coreHandleRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	id, err := entry.client.Identity()
	if err != nil {
		return nil, err
	}

	convos, err := entry.client.Conversations()
	if err != nil {
		return nil, err
	}
	out := make([]chatSummary, 0, len(convos))
	for _, convo := range convos {
		row := chatSummary{
			ChatID: convo.PeerAccountID, PeerServer: convo.PeerServer,
			HasUnread: convo.HasUnread, Blocked: convo.Blocked,
			PendingApproval:   convo.PendingApproval,
			PeerGone:          convo.PeerGone,
			LastActivityAt:    formatOptional(convo.LastActivityAt),
			PeerDeliveredUpTo: formatOptional(convo.PeerDeliveredUpTo),
			PeerReadUpTo:      formatOptional(convo.PeerReadUpTo),
		}
		if err := fillPreview(entry.client, &row); err != nil {
			return nil, err
		}
		out = append(out, row)
	}

	groups, err := entry.client.Groups()
	if err != nil {
		return nil, err
	}
	for _, groupID := range groups {
		membership, err := entry.client.GroupMembership(groupID)
		if err != nil {
			return nil, err
		}
		chat, err := entry.client.GroupChat(groupID)
		if err != nil {
			return nil, err
		}
		row := chatSummary{ChatID: groupID, Group: true}
		if chat != nil {
			row.HasUnread = chat.HasUnread
			row.LastActivityAt = formatOptional(chat.LastActivityAt)
		}
		if membership != nil {
			row.Title, row.Topic, row.Dissolved = membership.Name, membership.Topic, membership.Dissolved
			for _, m := range membership.Members {
				if m.Joined {
					row.Members++
				}
				if m.AccountID == id.AccountID && !m.Joined {
					// An invitation we have not answered. The one group state
					// a list has to show differently, because nothing arrives
					// in it until the user decides.
					row.Invited = true
				}
			}
		}
		if err := fillPreview(entry.client, &row); err != nil {
			return nil, err
		}
		out = append(out, row)
	}

	// One clock for both kinds. Newest first, and a chat with no activity at
	// all sorts last rather than arbitrarily.
	sort.SliceStable(out, func(i, j int) bool {
		return out[i].LastActivityAt > out[j].LastActivityAt
	})
	return out, nil
}

func fillPreview(c *client.Client, row *chatSummary) error {
	pinned, err := c.PinnedMessageIDs(row.ChatID)
	if err != nil {
		return err
	}
	row.PinnedMessageIDs = pinned

	last, err := c.LastMessage(row.ChatID)
	if err != nil || last == nil {
		return err
	}
	row.Preview, row.PreviewMine, row.PreviewSender = last.Text, last.Mine, last.SenderAccountID
	return nil
}

// --- transcript ------------------------------------------------------------

type coreMessagesRequest struct {
	Handle int64  `json:"handle"`
	ChatID string `json:"chat_id"`
}

type messageDTO struct {
	ID              string `json:"id"`
	Text            string `json:"text"`
	Mine            bool   `json:"mine,omitempty"`
	Timestamp       string `json:"timestamp"`
	SenderSentAt    string `json:"sender_sent_at,omitempty"`
	SenderAccountID string `json:"sender_account_id,omitempty"`

	ReplyToID            string `json:"reply_to_id,omitempty"`
	ReplyPreviewText     string `json:"reply_preview_text,omitempty"`
	ReplyPreviewMine     *bool  `json:"reply_preview_mine,omitempty"`
	ReplyPreviewAuthorID string `json:"reply_preview_author_id,omitempty"`

	Kind      string `json:"kind"`
	SendState string `json:"send_state"`

	Attachments []attachmentDTO `json:"attachments,omitempty"`
	Deliveries  []deliveryDTO   `json:"deliveries,omitempty"`
}

// attachmentDTO deliberately carries no key and no bytes. The key is the one
// secret in a message that the shell has no use for -- it fetches a picture by
// asking for its path, and the core does the opening.
type attachmentDTO struct {
	Kind     string `json:"kind"`
	BlobID   string `json:"blob_id"`
	MimeType string `json:"mime_type,omitempty"`
	ByteSize int    `json:"byte_size,omitempty"`
	Width    int    `json:"width,omitempty"`
	Height   int    `json:"height,omitempty"`

	// Pending marks an attachment whose upload has not finished, so a bubble
	// can show the local preview and a spinner rather than a broken picture.
	Pending bool `json:"pending,omitempty"`
}

type deliveryDTO struct {
	AccountID string `json:"account_id"`
	State     string `json:"state"`

	// Error is why this copy failed, empty for one that did not, phrased for
	// the reader: the delivery sheet is where "not delivered" has to become
	// something they can act on.
	Error string `json:"error,omitempty"`

	// Detail is the same failure in the words of whatever refused it. Never
	// shown -- it goes to the log line after a fan-out, so that saying the
	// first one plainly costs nothing in diagnosis.
	Detail string `json:"detail,omitempty"`

	// AttachmentSkipped: they got the caption but not the picture, because
	// their server would not take it. Not a delivery failure, so it rides
	// alongside the state rather than in it.
	AttachmentSkipped bool `json:"attachment_skipped,omitempty"`
}

func doCoreMessages(req coreMessagesRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	msgs, err := entry.client.Messages(req.ChatID)
	if err != nil {
		return nil, err
	}
	out := make([]messageDTO, 0, len(msgs))
	for _, m := range msgs {
		out = append(out, toMessageDTO(m))
	}
	return out, nil
}

func toMessageDTO(m client.Message) messageDTO {
	dto := messageDTO{
		ID: m.ID, Text: m.Text, Mine: m.Mine,
		Timestamp:    m.Timestamp.UTC().Format(time.RFC3339Nano),
		SenderSentAt: formatOptional(m.SenderSentAt), SenderAccountID: m.SenderAccountID,
		ReplyToID: m.ReplyToID, ReplyPreviewText: m.ReplyPreviewText,
		ReplyPreviewMine: m.ReplyPreviewMine, ReplyPreviewAuthorID: m.ReplyPreviewAuthorID,
		Kind: string(m.Kind), SendState: string(m.SendState),
	}
	for _, a := range m.Attachments {
		dto.Attachments = append(dto.Attachments, attachmentDTO{
			Kind: a.Kind, BlobID: a.BlobID, MimeType: a.MimeType,
			ByteSize: a.ByteSize, Width: a.Width, Height: a.Height,
			Pending: a.BlobID == "",
		})
	}
	for _, d := range m.Deliveries {
		dto.Deliveries = append(dto.Deliveries, deliveryDTO{
			AccountID: d.AccountID, State: string(d.State),
			Error: d.Error, Detail: d.Detail, AttachmentSkipped: d.AttachmentSkipped,
		})
	}
	return dto
}

// --- sending ---------------------------------------------------------------

type coreSendRequest struct {
	Handle int64  `json:"handle"`
	ChatID string `json:"chat_id"`
	Text   string `json:"text"`

	ReplyToID        string `json:"reply_to_id,omitempty"`
	ReplyPreviewText string `json:"reply_preview_text,omitempty"`
	ReplyPreviewMine *bool  `json:"reply_preview_mine,omitempty"`

	// MediaPath is a file the shell already holds. A path rather than bytes:
	// the picture is on disk either way, and routing megabytes through a JSON
	// envelope to hand them back to a file system would be pure cost.
	MediaPath string `json:"media_path,omitempty"`
	MimeType  string `json:"mime_type,omitempty"`
	Width     int    `json:"width,omitempty"`
	Height    int    `json:"height,omitempty"`

	// ThumbPath is the tiny preview that rides inside the message.
	ThumbPath string `json:"thumb_path,omitempty"`
}

// doCoreSend sends into a chat, whichever kind it turns out to be.
//
// One call for both, because a chat id says which it is: account and group ids
// differ by a version marker, so dispatching is exact rather than a guess, and
// the shell does not have to track a distinction it would only get wrong.
func doCoreSend(req coreSendRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	opts := client.SendOptions{
		ReplyToID: req.ReplyToID, ReplyPreviewText: req.ReplyPreviewText,
		ReplyPreviewMine: req.ReplyPreviewMine,
	}
	if req.MediaPath != "" {
		media, err := readMedia(req)
		if err != nil {
			return nil, err
		}
		opts.Media = media
	}

	ctx, cancel := callContext()
	defer cancel()

	var res client.SendResult
	if client.IsGroupID(req.ChatID) {
		res, err = entry.client.SendGroupText(ctx, req.ChatID, req.Text, opts)
	} else {
		res, err = entry.client.SendText(ctx, req.ChatID, req.Text, opts)
	}
	// The line exists either way -- that is the point of writing it before the
	// network is touched -- so it comes back even on failure, marked failed,
	// alongside the error the shell shows.
	dto := toMessageDTO(res.Message)
	if err != nil {
		return nil, fmt.Errorf("%w (message %s)", err, dto.ID)
	}
	return dto, nil
}

func readMedia(req coreSendRequest) (*client.OutgoingMedia, error) {
	bytes, err := os.ReadFile(req.MediaPath)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", req.MediaPath, err)
	}
	media := &client.OutgoingMedia{
		Bytes: bytes, MimeType: req.MimeType,
		Width: req.Width, Height: req.Height, Kind: "image",
	}
	if req.ThumbPath != "" {
		// A missing thumbnail costs a preview, never the picture: it is a
		// nicety the sender produced, not part of the message.
		if thumb, err := os.ReadFile(req.ThumbPath); err == nil {
			media.Thumb = thumb
		}
	}
	return media, nil
}

// coreMessageRequest names one message in one chat -- retry, pin, unpin and
// delete all address exactly that.
type coreMessageRequest struct {
	Handle    int64  `json:"handle"`
	ChatID    string `json:"chat_id"`
	MessageID string `json:"message_id"`
}

// doCoreRetry dispatches on the chat id, same as doCoreSend: a group id and a
// peer account id share one namespace, so which retry applies is exact rather
// than a guess.
func doCoreRetry(req coreMessageRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	ctx, cancel := callContext()
	defer cancel()

	var res client.SendResult
	if client.IsGroupID(req.ChatID) {
		res, err = entry.client.RetryGroupMessage(ctx, req.ChatID, req.MessageID)
	} else {
		res, err = entry.client.RetryMessage(ctx, req.ChatID, req.MessageID)
	}
	if err != nil {
		return nil, err
	}
	return toMessageDTO(res.Message), nil
}

// --- reading ---------------------------------------------------------------

type coreOpenChatRequest struct {
	Handle int64  `json:"handle"`
	ChatID string `json:"chat_id"`
}

// doCoreSetOpenChat tells the core which chat is on screen.
//
// The only thing that suppresses a notification, and it has to live here
// rather than be passed per envelope: the receive loop runs in its own
// isolate and has no idea what the user is looking at.
func doCoreSetOpenChat(req coreOpenChatRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	entry.mu.Lock()
	entry.openChatID = req.ChatID
	entry.mu.Unlock()
	return struct{}{}, nil
}

// doCoreMarkRead clears a chat's unread flag and confirms it to the sender.
func doCoreMarkRead(req coreOpenChatRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	ctx, cancel := callContext()
	defer cancel()

	if client.IsGroupID(req.ChatID) {
		chat, err := entry.client.GroupChat(req.ChatID)
		if err != nil || chat == nil {
			return struct{}{}, err
		}
		chat.HasUnread = false
		if err := entry.client.PutGroupChat(*chat); err != nil {
			return nil, err
		}
		// A group receipt goes to the author of what was read, not into the
		// group: who has read what stays between reader and author. One per
		// author, because a group transcript has many -- confirming only the
		// author of the newest message leaves everybody else's permanently
		// unconfirmed, however long the chat has been open.
		msgs, err := entry.client.Messages(req.ChatID)
		if err != nil {
			return nil, err
		}
		for _, author := range newestPerAuthor(msgs) {
			// Best-effort per author, as everywhere else in a fan-out: one
			// member being unreachable must not cost the others their receipt.
			_ = entry.client.SendGroupReceipt(ctx, req.ChatID, author.accountID, client.ReceiptRead, author.upTo)
		}
		return struct{}{}, nil
	}

	convo, err := entry.client.Conversation(req.ChatID)
	if err != nil || convo == nil {
		return struct{}{}, err
	}
	convo.HasUnread = false
	if err := entry.client.PutConversation(*convo); err != nil {
		return nil, err
	}
	// One peer, so one watermark: the newest thing they said answers for
	// everything they said before it.
	last, err := entry.client.LastMessage(req.ChatID)
	if err != nil {
		return nil, err
	}
	if last != nil && !last.Mine {
		_ = entry.client.SendReceipt(ctx, req.ChatID, client.ReceiptRead, receiptAnchor(last))
	}
	return struct{}{}, nil
}

// receiptAnchor is the instant a receipt confirms up to: the sender's own
// stamp where there is one, since a watermark only means anything in the clock
// the sender used.
func receiptAnchor(m *client.Message) time.Time {
	if m.SenderSentAt != nil {
		return *m.SenderSentAt
	}
	return m.Timestamp
}

// authorAnchor is one author and the newest thing of theirs we have read.
type authorAnchor struct {
	accountID string
	upTo      time.Time
}

// newestPerAuthor reduces a group transcript to one anchor per other author.
//
// A watermark is cumulative -- confirming an author's newest message confirms
// every earlier one they wrote -- which is exactly why a receipt is one marker
// per member rather than one per message, and why nothing here has to be
// tracked per message. Each author's anchor is their *own* newest: anchoring
// everyone at the transcript's newest would hand each of them a reading of
// somebody else's clock, and the watermark is monotonic, so an anchor set too
// far ahead can never be walked back.
//
// Sorted by account id, so the fan-out below is in a fixed order rather than
// map order.
func newestPerAuthor(msgs []client.Message) []authorAnchor {
	newest := map[string]time.Time{}
	for i := range msgs {
		m := &msgs[i]
		if m.Mine || m.SenderAccountID == "" || m.Kind != client.MessageNormal {
			continue
		}
		anchor := receiptAnchor(m)
		if at, seen := newest[m.SenderAccountID]; !seen || anchor.After(at) {
			newest[m.SenderAccountID] = anchor
		}
	}
	anchors := make([]authorAnchor, 0, len(newest))
	for account, upTo := range newest {
		anchors = append(anchors, authorAnchor{accountID: account, upTo: upTo})
	}
	sort.Slice(anchors, func(i, j int) bool { return anchors[i].accountID < anchors[j].accountID })
	return anchors
}

// --- contacts --------------------------------------------------------------

type coreStartConversationRequest struct {
	Handle  int64  `json:"handle"`
	Address string `json:"address"`
	Server  string `json:"server,omitempty"`
}

func doCoreStartConversation(req coreStartConversationRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	ctx, cancel := callContext()
	defer cancel()

	convo, err := entry.client.StartConversation(ctx, req.Address, req.Server)
	if err != nil {
		return nil, err
	}
	return chatSummary{
		ChatID: convo.PeerAccountID, PeerServer: convo.PeerServer,
		PendingApproval: convo.PendingApproval,
	}, nil
}

type corePeerRequest struct {
	Handle    int64  `json:"handle"`
	AccountID string `json:"account_id"`
	Server    string `json:"server,omitempty"`
}

func doCoreBlockPeer(req corePeerRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	return struct{}{}, entry.client.BlockPeer(req.AccountID, req.Server)
}

func doCoreUnblockPeer(req corePeerRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	return struct{}{}, entry.client.UnblockPeer(req.AccountID)
}

func doCoreAcceptRequest(req corePeerRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	convo, err := entry.client.Conversation(req.AccountID)
	if err != nil || convo == nil {
		return struct{}{}, err
	}
	convo.PendingApproval = false
	if err := entry.client.PutConversation(*convo); err != nil {
		return nil, err
	}
	// Accepting is what makes them known, so a later deletion and a new
	// message from them do not arrive as a fresh request.
	return struct{}{}, entry.client.MarkPeerKnown(req.AccountID)
}

// doCoreClearChat empties a chat's history and its pictures, keeping the chat.
//
// The other half of doCoreDeleteChat, and separate for the one difference that
// matters: this keeps the conversation record (a peer) or the fact set (a
// group), so the chat stays in the list and the next message lands in it. The
// shell offers both actions side by side and they mean different things --
// "clear" is about the history, "delete" is about the chat.
func doCoreClearChat(req coreOpenChatRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	if err := entry.client.ClearTranscript(req.ChatID); err != nil {
		return nil, err
	}
	if err := entry.client.DeleteChatMedia(req.ChatID); err != nil {
		return nil, err
	}

	// An emptied chat has nothing left to be unread, so the flag goes too --
	// otherwise the list shows an unread badge over a chat with no messages in
	// it, and only opening it would clear it.
	//
	// Cleared here rather than by marking the chat read, deliberately: that
	// confirms to the sender that their message was read, and clearing a chat
	// says nothing to anybody. Nothing below touches the network.
	if client.IsGroupID(req.ChatID) {
		chat, err := entry.client.GroupChat(req.ChatID)
		if err != nil || chat == nil {
			return struct{}{}, err
		}
		chat.HasUnread = false
		return struct{}{}, entry.client.PutGroupChat(*chat)
	}
	convo, err := entry.client.Conversation(req.ChatID)
	if err != nil || convo == nil {
		return struct{}{}, err
	}
	convo.HasUnread = false
	return struct{}{}, entry.client.PutConversation(*convo)
}

func doCoreDeleteChat(req coreOpenChatRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	if err := entry.client.ClearTranscript(req.ChatID); err != nil {
		return nil, err
	}
	if err := entry.client.DeleteChatMedia(req.ChatID); err != nil {
		return nil, err
	}
	if client.IsGroupID(req.ChatID) {
		// The facts go too, which is what actually takes the group off the
		// list -- Client.Groups is a directory listing, so a group whose facts
		// are still here is still a row, however long ago one left it. Only
		// ever right for a group this account is out of; the caller that
		// offers the action is what enforces that (freizone-app's
		// group_actions.dart), because once the facts are gone nothing here
		// can tell "left" from "never joined".
		return struct{}{}, entry.client.ForgetGroup(req.ChatID)
	}
	// The session deliberately stays: the peer does not know their chat was
	// deleted here, and throwing it away would make their next message look
	// like a desync. The block, if any, outlives the conversation too.
	return struct{}{}, entry.client.DeleteConversation(req.ChatID)
}

// doCoreDeleteMessage removes one line from this device's own history --
// with its media, see pkg/client.DeleteMessage. The peer keeps their copy,
// and the server was never involved: its queue copy went with the ack.
func doCoreDeleteMessage(req coreMessageRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	return struct{}{}, entry.client.DeleteMessage(req.ChatID, req.MessageID)
}

// doCorePinMessage and doCoreUnpinMessage keep a purely local display
// preference -- never sent to the peer, the group or the server. They live
// here rather than in the shell because the pins ride the transcript
// (CoreChats reports them on every summary), and a preference stored where
// the transcript is not would vanish on the next rebuild from the core --
// which is exactly what it did while the shell kept its own copy.
func doCorePinMessage(req coreMessageRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	return struct{}{}, entry.client.PinMessage(req.ChatID, req.MessageID)
}

func doCoreUnpinMessage(req coreMessageRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	return struct{}{}, entry.client.UnpinMessage(req.ChatID, req.MessageID)
}

// doCoreForgetPeer discards everything this device holds *about* a peer: the
// cached device and both ratchet sessions with them.
//
// The counterpart to deleting a chat, not a part of it. Deleting a chat keeps
// the session on purpose -- the peer does not know their chat was deleted here,
// and their next message must not look like a desync. This is for the case the
// shell gates behind evidence that the peer is genuinely gone (see
// peer_absence.dart), where there is no next message to protect and leaving
// their ratchet behind would make "nothing about this peer is left on the
// device" untrue.
//
// Deliberately not ResetSession, which discards in order to re-establish and
// tells the peer so. This one forgets.
func doCoreForgetPeer(req coreOpenChatRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	return struct{}{}, entry.client.ForgetPeerDevice(req.ChatID)
}

// --- attachments -----------------------------------------------------------

type coreAttachmentRequest struct {
	Handle    int64  `json:"handle"`
	ChatID    string `json:"chat_id"`
	MessageID string `json:"message_id"`
	Thumb     bool   `json:"thumb,omitempty"`

	// LocalOnly answers from disk or not at all -- never downloading.
	//
	// For a caller that has to decide something *about* a picture rather than
	// show it, and cannot wait: the long-press sheet leaves its save and share
	// entries out when there is no file, and asking the network first would
	// mean a menu that opens after a download instead of at once (up to
	// callTimeout, on a picture whose earlier download already failed).
	LocalOnly bool `json:"local_only,omitempty"`
}

type attachmentPathResponse struct {
	// Path is empty when there is nothing to show yet, which is not an error:
	// a picture nobody has looked at has simply not been fetched.
	Path string `json:"path,omitempty"`
}

// doCoreAttachmentPath returns where a message's picture is on disk, fetching
// it first if it has not been fetched.
//
// A path, never bytes. The shell has a file reader and an image decoder that
// want a file anyway, and a multi-megabyte round trip through JSON to reach
// them would cost more than the download.
func doCoreAttachmentPath(req coreAttachmentRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	if req.Thumb {
		return attachmentPathResponse{Path: entry.client.AttachmentThumbPath(req.ChatID, req.MessageID)}, nil
	}

	// A file already here needs no blob and no key. That is the sender's own
	// picture -- written before the network was touched, and since a group's
	// blob is per recipient server its line keeps a placeholder with no id at
	// all -- and equally anything downloaded earlier. Asked first, because the
	// blob-id check below would otherwise answer "nothing" for a picture
	// sitting on disk, which is what left a sender looking at their own
	// photograph as a blurred thumbnail.
	if path := entry.client.AttachmentPath(req.ChatID, req.MessageID); path != "" {
		if _, err := os.Stat(path); err == nil {
			return attachmentPathResponse{Path: path}, nil
		}
	}
	// Everything below downloads. An empty answer is the honest one for a
	// caller that said it would not wait -- and the same empty answer it
	// already gets for a picture there is nothing to fetch for.
	if req.LocalOnly {
		return attachmentPathResponse{}, nil
	}

	msgs, err := entry.client.Messages(req.ChatID)
	if err != nil {
		return nil, err
	}
	var attachment *client.Attachment
	for _, m := range msgs {
		if m.ID == req.MessageID && len(m.Attachments) > 0 {
			attachment = &m.Attachments[0]
			break
		}
	}
	// Nothing to fetch: a line whose attachment never finished uploading has no
	// blob anywhere to fetch it from, and asking would fail on the missing key
	// rather than on the missing blob.
	if attachment == nil || attachment.BlobID == "" {
		return attachmentPathResponse{}, nil
	}

	ctx, cancel := callContext()
	defer cancel()

	// A blob always lives on the RECIPIENT's own server -- the sender
	// federated-uploads it there, precisely so the recipient never has to
	// reach the sender's server to read something the sender sent (see
	// pkg/client/blobs.go's package comment and UploadAttachment, which
	// uploads to the recipient device's server, not the sender's own).
	// This side is always the recipient once a message has arrived, so the
	// fetch below is always local -- convo.PeerServer names where the
	// *sender* lives, which is a different server than the blob for exactly
	// the federated case this mattered for, and passing it here misrouted
	// the download through federated auth to a server that never received
	// this blob and answered 401 rather than "found nothing".
	if _, err := entry.client.EnsureAttachment(ctx, req.ChatID, req.MessageID, "", *attachment); err != nil {
		return nil, err
	}
	return attachmentPathResponse{Path: entry.client.AttachmentPath(req.ChatID, req.MessageID)}, nil
}

// --- groups ----------------------------------------------------------------

type coreGroupCreateRequest struct {
	Handle int64  `json:"handle"`
	Name   string `json:"name"`
}

func doCoreGroupCreate(req coreGroupCreateRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	ctx, cancel := callContext()
	defer cancel()

	groupID, err := entry.client.CreateGroup(ctx, req.Name)
	if err != nil {
		return nil, err
	}
	return map[string]string{"group_id": groupID}, nil
}

type coreGroupMemberRequest struct {
	Handle    int64  `json:"handle"`
	GroupID   string `json:"group_id"`
	AccountID string `json:"account_id,omitempty"`
	Server    string `json:"server,omitempty"`
	Role      string `json:"role,omitempty"`
	Grant     bool   `json:"grant,omitempty"`
}

func doCoreGroupInvite(req coreGroupMemberRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	ctx, cancel := callContext()
	defer cancel()
	return struct{}{}, entry.client.InviteToGroup(ctx, req.GroupID, req.AccountID, req.Server)
}

func doCoreGroupAccept(req coreGroupMemberRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	ctx, cancel := callContext()
	defer cancel()
	return struct{}{}, entry.client.AcceptGroupInvitation(ctx, req.GroupID)
}

func doCoreGroupSetRole(req coreGroupMemberRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	role, err := parseRole(req.Role)
	if err != nil {
		return nil, err
	}
	ctx, cancel := callContext()
	defer cancel()
	return struct{}{}, entry.client.SetGroupRole(ctx, req.GroupID, req.AccountID, role, req.Grant)
}

func doCoreGroupRemove(req coreGroupMemberRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	ctx, cancel := callContext()
	defer cancel()
	return struct{}{}, entry.client.RemoveFromGroup(ctx, req.GroupID, req.AccountID)
}

func doCoreGroupLeave(req coreGroupMemberRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	ctx, cancel := callContext()
	defer cancel()
	return struct{}{}, entry.client.LeaveGroup(ctx, req.GroupID)
}

// doCoreGroupSyncRequest asks one member for the group's whole fact set.
//
// The shell's cue is a group screen opening, which is the moment a stale
// member list is about to be shown and acted on. Rate limited inside the core
// (see pkg/client.RequestGroupSync), so calling it on every open is correct
// rather than merely tolerable.
func doCoreGroupSyncRequest(req coreGroupMemberRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	ctx, cancel := callContext()
	defer cancel()
	return struct{}{}, entry.client.RequestGroupSync(ctx, req.GroupID)
}

func doCoreGroupDissolve(req coreGroupMemberRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	ctx, cancel := callContext()
	defer cancel()
	return struct{}{}, entry.client.DissolveGroup(ctx, req.GroupID)
}

type coreGroupMetaRequest struct {
	Handle  int64  `json:"handle"`
	GroupID string `json:"group_id"`
	Name    string `json:"name"`
	Topic   string `json:"topic"`
}

func doCoreGroupSetMeta(req coreGroupMetaRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	ctx, cancel := callContext()
	defer cancel()
	return struct{}{}, entry.client.SetGroupMeta(ctx, req.GroupID, req.Name, req.Topic)
}

type groupInfo struct {
	GroupID   string      `json:"group_id"`
	Name      string      `json:"name,omitempty"`
	Topic     string      `json:"topic,omitempty"`
	Founder   string      `json:"founder,omitempty"`
	Dissolved bool        `json:"dissolved,omitempty"`
	StateHash string      `json:"state_hash,omitempty"`
	MyRole    string      `json:"my_role,omitempty"`
	Members   []memberDTO `json:"members,omitempty"`
}

type memberDTO struct {
	AccountID string `json:"account_id"`
	Server    string `json:"server,omitempty"`
	Role      string `json:"role"`
	Joined    bool   `json:"joined,omitempty"`

	// DeliveredUpTo and ReadUpTo are how far this member has got with *our*
	// messages. Per member and never shared onward, which is why they are here
	// rather than on a message.
	DeliveredUpTo string `json:"delivered_up_to,omitempty"`
	ReadUpTo      string `json:"read_up_to,omitempty"`
}

func doCoreGroupInfo(req coreGroupMemberRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	membership, err := entry.client.GroupMembership(req.GroupID)
	if err != nil {
		return nil, err
	}
	if membership == nil {
		return nil, fmt.Errorf("no facts about group %s", req.GroupID)
	}
	id, err := entry.client.Identity()
	if err != nil {
		return nil, err
	}
	chat, err := entry.client.GroupChat(req.GroupID)
	if err != nil {
		return nil, err
	}

	info := groupInfo{
		GroupID: membership.GroupID, Name: membership.Name, Topic: membership.Topic,
		Founder: membership.Founder, Dissolved: membership.Dissolved,
		StateHash: membership.StateHash, MyRole: membership.RoleOf(id.AccountID).String(),
	}
	for _, m := range membership.Members {
		dto := memberDTO{AccountID: m.AccountID, Server: m.Server, Role: m.RoleName, Joined: m.Joined}
		if chat != nil {
			if receipt, ok := chat.MemberReceipts[m.AccountID]; ok {
				dto.DeliveredUpTo = formatOptional(receipt.DeliveredUpTo)
				dto.ReadUpTo = formatOptional(receipt.ReadUpTo)
			}
		}
		info.Members = append(info.Members, dto)
	}
	return info, nil
}

func parseRole(name string) (group.Role, error) {
	switch name {
	case "member":
		return group.RoleMember, nil
	case "moderator":
		return group.RoleModerator, nil
	case "admin":
		return group.RoleAdmin, nil
	}
	return 0, fmt.Errorf("unknown role %q", name)
}

// --- maintenance -----------------------------------------------------------

type maintainResponse struct {
	PrekeysToppedUp bool     `json:"prekeys_topped_up,omitempty"`
	DebtsPaid       int      `json:"debts_paid,omitempty"`
	Recovered       []string `json:"recovered,omitempty"`

	// ReceiptsResent counts confirmations that had never got out and have now.
	ReceiptsResent int `json:"receipts_resent,omitempty"`

	// Problems are the things that did not work, as text. Housekeeping is
	// best-effort by nature -- one failing part must not stop the others -- so
	// they are reported rather than returned as an error.
	Problems []string `json:"problems,omitempty"`
}

// doCoreMaintain is everything that should happen on a fresh connection.
//
// One call rather than three, because the shell has no view on the order or on
// what each costs: top up the prekey pool so somebody can start a conversation
// while this device is off, settle any group facts owed, and re-establish the
// sessions the evidence says are broken.
func doCoreMaintain(req coreHandleRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*callTimeout)
	defer cancel()

	var out maintainResponse
	if err := entry.client.TopUpOneTimePrekeys(ctx); err != nil {
		out.Problems = append(out.Problems, "topping up prekeys: "+err.Error())
	} else {
		out.PrekeysToppedUp = true
	}
	if paid, gone, err := entry.client.PayGroupSnapshotDebts(ctx); err != nil {
		out.Problems = append(out.Problems, "settling group facts: "+err.Error())
	} else {
		out.DebtsPaid = paid
		// Said once, here, because nothing else will ever say it: a member
		// whose account is gone keeps their row in the group until a moderator
		// removes them, and this is the only moment anything found out.
		for _, account := range gone {
			out.Problems = append(out.Problems,
				"group member "+account+" no longer exists on their server")
		}
	}
	if recovered, err := entry.client.RecoverDesyncedSessions(ctx); err != nil {
		out.Problems = append(out.Problems, "recovering sessions: "+err.Error())
	} else {
		out.Recovered = recovered
	}
	// A confirmation lost to a failed send is not marked as sent, so it goes
	// again -- but only when there is something new to confirm, which a quiet
	// conversation may not offer for days. A fresh connection is when whatever
	// broke the last attempt has most likely passed.
	if resent, err := entry.client.ResendPendingReceipts(ctx); err != nil {
		out.Problems = append(out.Problems, "re-sending receipts: "+err.Error())
	} else {
		out.ReceiptsResent = resent
	}
	return out, nil
}

type coreReceiptsRequest struct {
	Handle  int64 `json:"handle"`
	Enabled bool  `json:"enabled"`
}

// doCoreSetReceiptsEnabled records the user's answer where every consumer of
// this account can see it -- including the background wake, which opens the
// account knowing nothing of the app's own settings.
func doCoreSetReceiptsEnabled(req coreReceiptsRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	return struct{}{}, entry.client.SetReceiptsEnabled(req.Enabled)
}

type coreResetSessionRequest struct {
	Handle    int64  `json:"handle"`
	AccountID string `json:"account_id"`
}

func doCoreResetSession(req coreResetSessionRequest) (any, error) {
	entry, err := lookupHandle(req.Handle)
	if err != nil {
		return nil, err
	}
	ctx, cancel := callContext()
	defer cancel()
	return struct{}{}, entry.client.ResetSession(ctx, req.AccountID, client.RekeyUserRequested)
}

func formatOptional(t *time.Time) string {
	if t == nil {
		return ""
	}
	return t.UTC().Format(time.RFC3339Nano)
}
