package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"testing"
	"time"

	"github.com/behringer24/freizone-server/pkg/address"
	"github.com/behringer24/freizone-server/pkg/group"
)

// newGroupIdentity builds the identity block every group call takes -- the
// same material an AppState holds for the signed-in account.
func newGroupIdentity(t *testing.T) groupIdentity {
	t.Helper()

	rootPub, rootPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	accountID, err := address.DeriveID(rootPub)
	if err != nil {
		t.Fatal(err)
	}
	devicePub, devicePriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return groupIdentity{
		AccountID:  accountID,
		RootPub:    rootPub,
		RootPriv:   rootPriv,
		DeviceID:   "aabbccddeeff0011",
		DevicePub:  devicePub,
		DevicePriv: devicePriv,
	}
}

func groupCreate(t *testing.T, identity groupIdentity, name string) *groupStateResponse {
	t.Helper()
	out, err := doGroupCreate(groupCreateRequest{
		Identity: identity,
		Server:   "https://a.example.org",
		Name:     name,
		IssuedAt: time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC),
	})
	if err != nil {
		t.Fatalf("doGroupCreate: %v", err)
	}
	return out.(*groupStateResponse)
}

// signAndApply is the two-call shape a client uses: sign an event, then merge
// it into the state.
func signAndApply(
	t *testing.T,
	identity groupIdentity,
	state json.RawMessage,
	req groupSignEventRequest,
) (*groupStateResponse, *group.Event) {
	t.Helper()
	req.Identity = identity
	req.State = state
	if req.IssuedAt.IsZero() {
		req.IssuedAt = time.Date(2026, 8, 2, 12, 1, 0, 0, time.UTC)
	}

	signed, err := doGroupSignEvent(req)
	if err != nil {
		t.Fatalf("doGroupSignEvent(%s): %v", req.Type, err)
	}
	event := signed.(groupSignEventResponse).Event

	applied, err := doGroupApplyEvents(groupApplyEventsRequest{
		State:  state,
		Events: []*group.Event{event},
	})
	if err != nil {
		t.Fatalf("doGroupApplyEvents: %v", err)
	}
	return applied.(*groupStateResponse), event
}

func TestGroupCreateProducesASelfCertifyingGroup(t *testing.T) {
	founder := newGroupIdentity(t)
	out := groupCreate(t, founder, "Wandergruppe")

	if out.GroupID == "" || out.Resolved.GroupID != out.GroupID {
		t.Fatalf("group id missing or inconsistent: %+v", out)
	}
	// The marker is what keeps a group id and an account id apart.
	version, err := address.VersionOf(out.GroupID)
	if err != nil || version != address.VersionGroup {
		t.Fatalf("group id version = %d (err %v), want %d", version, err, address.VersionGroup)
	}
	if out.Resolved.Founder != founder.AccountID {
		t.Fatalf("founder = %q, want %q", out.Resolved.Founder, founder.AccountID)
	}
	if out.Resolved.Name != "Wandergruppe" {
		t.Fatalf("name = %q", out.Resolved.Name)
	}
	if len(out.Resolved.Members) != 1 {
		t.Fatalf("want the founder as the only member, got %d", len(out.Resolved.Members))
	}
	member := out.Resolved.Members[0]
	if member.Role != group.RoleFounder || !member.Joined {
		t.Fatalf("founder must be a joined member with founder rank: %+v", member)
	}
	// Without a server the founder is the one member nobody can deliver to.
	if member.Server != "https://a.example.org" {
		t.Fatalf("founder server = %q", member.Server)
	}
	if out.StateHash == "" {
		t.Fatal("state hash must be reported alongside the blob")
	}
}

func TestGroupStateBlobIsSelfContainedAcrossCalls(t *testing.T) {
	founder := newGroupIdentity(t)
	created := groupCreate(t, founder, "Wandergruppe")

	// The blob is all the caller keeps. Handing it straight back must
	// reproduce the same view -- this is the property that lets Dart persist
	// it without understanding a byte of it.
	out, err := doGroupResolveState(groupResolveStateRequest{State: created.State})
	if err != nil {
		t.Fatal(err)
	}
	resolved := out.(*groupStateResponse)
	if resolved.StateHash != created.StateHash {
		t.Fatal("a reloaded blob must hash identically")
	}
	if resolved.Resolved.Name != "Wandergruppe" {
		t.Fatal("metadata lost through the blob")
	}
}

func TestGroupResolveStateAcceptsAnUnknownGroup(t *testing.T) {
	// What a device has before the first snapshot of a group it has just been
	// invited to arrives. It must answer emptily rather than fail: the UI asks
	// about a group it is only now hearing of.
	//
	// `{}` is in here for a concrete reason: it is what Dart's
	// `const <String, dynamic>{}` encodes to, and that is what the receive path
	// passes for an unknown group. It used to fail the whole call, which cost an
	// invitee their invitation outright -- see loadGroupState.
	for _, blob := range []json.RawMessage{
		nil,
		json.RawMessage("null"),
		json.RawMessage("{}"),
		json.RawMessage(`{"events":[]}`),
		json.RawMessage(`{"events":null}`),
	} {
		out, err := doGroupResolveState(groupResolveStateRequest{State: blob})
		if err != nil {
			t.Fatalf("empty state %s: %v", blob, err)
		}
		if got := out.(*groupStateResponse); got.GroupID != "" || len(got.Resolved.Members) != 0 {
			t.Fatalf("want an empty view, got %+v", got)
		}
	}
}

// The invitee's side of an invitation: a snapshot merged into the "nothing yet"
// blob the receive path actually passes, rather than into a state built by an
// earlier call in the same test. This is the path that was broken -- everything
// downstream of it (the group appearing, the notification, being able to accept)
// depends on this one call not failing.
func TestGroupSnapshotIntoAnEmptyBlobIsAccepted(t *testing.T) {
	founder := newGroupIdentity(t)
	invitee := newGroupIdentity(t)
	created := groupCreate(t, founder, "Wandergruppe")

	added, _ := signAndApply(t, founder, created.State, groupSignEventRequest{
		Type:    "member_add",
		Subject: invitee.AccountID,
		Server:  "https://b.example.org",
	})

	var snapshot struct {
		Events []*group.Event `json:"events"`
	}
	if err := json.Unmarshal(added.State, &snapshot); err != nil {
		t.Fatalf("reading the snapshot the inviter sends: %v", err)
	}

	for _, blob := range []json.RawMessage{nil, json.RawMessage("{}")} {
		out, err := doGroupApplyEvents(groupApplyEventsRequest{
			State:  blob,
			Events: snapshot.Events,
		})
		if err != nil {
			t.Fatalf("applying a snapshot onto %s: %v", blob, err)
		}
		got := out.(*groupStateResponse)
		if len(got.Rejected) > 0 {
			t.Fatalf("snapshot rejected: %+v", got.Rejected)
		}
		if got.GroupID != created.GroupID {
			t.Fatalf("group id = %q, want %q", got.GroupID, created.GroupID)
		}
		if got.StateHash != added.StateHash {
			t.Fatal("the invitee must end up on the inviter's state hash")
		}
		// Listed, and not joined: the invitation is a proposal until answered.
		var pending bool
		for _, m := range got.Resolved.Members {
			if m.AccountID == invitee.AccountID {
				pending = !m.Joined
			}
		}
		if !pending {
			t.Fatalf("want a pending membership for the invitee, got %+v", got.Resolved.Members)
		}
	}
}

func TestGroupInviteAndAcceptThroughTheFFIShape(t *testing.T) {
	founder := newGroupIdentity(t)
	invitee := newGroupIdentity(t)
	created := groupCreate(t, founder, "Wandergruppe")

	added, _ := signAndApply(t, founder, created.State, groupSignEventRequest{
		Type:    "member_add",
		Subject: invitee.AccountID,
		Server:  "https://b.example.org",
	})
	if added.Resolved.RoleOf(invitee.AccountID) != group.RoleMember {
		t.Fatal("the invitee must be listed as a member")
	}
	for _, m := range added.Resolved.Members {
		if m.AccountID == invitee.AccountID && m.Joined {
			t.Fatal("an invitation must not count as joined before it is accepted")
		}
	}

	accepted, _ := signAndApply(t, invitee, added.State, groupSignEventRequest{
		Type:     "join_accept",
		Subject:  invitee.AccountID,
		IssuedAt: time.Date(2026, 8, 2, 12, 2, 0, 0, time.UTC),
	})
	for _, m := range accepted.Resolved.Members {
		if m.AccountID == invitee.AccountID && !m.Joined {
			t.Fatal("after accepting, the invitee must be joined")
		}
	}
}

func TestGroupSignEventPicksTheKeyItself(t *testing.T) {
	founder := newGroupIdentity(t)
	member := newGroupIdentity(t)
	created := groupCreate(t, founder, "")

	added, _ := signAndApply(t, founder, created.State, groupSignEventRequest{
		Type: "member_add", Subject: member.AccountID, Server: "https://a.example.org",
	})

	// Admin is the founder's to give and needs the group root key, which is
	// re-derived here rather than stored. The caller never says which key to
	// use -- one fewer thing a client can get wrong.
	promoted, adminGrant := signAndApply(t, founder, added.State, groupSignEventRequest{
		Type: "role_grant", Subject: member.AccountID, Role: "admin",
		IssuedAt: time.Date(2026, 8, 2, 12, 3, 0, 0, time.UTC),
	})
	if adminGrant.Signer != nil {
		t.Fatal("an admin grant must be signed by the group root key, carrying no signer block")
	}
	if promoted.Resolved.RoleOf(member.AccountID) != group.RoleAdmin {
		t.Fatalf("role = %s, want admin", promoted.Resolved.RoleOf(member.AccountID))
	}

	// Moderator is within a device signature's authority, so it gets one.
	_, modGrant := signAndApply(t, founder, promoted.State, groupSignEventRequest{
		Type: "role_grant", Subject: member.AccountID, Role: "moderator",
		IssuedAt: time.Date(2026, 8, 2, 12, 4, 0, 0, time.UTC),
	})
	if modGrant.Signer == nil || modGrant.Signer.AccountID != founder.AccountID {
		t.Fatal("a moderator grant must carry the signer's own identity block")
	}
}

func TestOnlyTheFounderCanMintARootSignedEvent(t *testing.T) {
	founder := newGroupIdentity(t)
	other := newGroupIdentity(t)
	created := groupCreate(t, founder, "")

	added, _ := signAndApply(t, founder, created.State, groupSignEventRequest{
		Type: "member_add", Subject: other.AccountID, Server: "https://a.example.org",
	})

	// Not merely unauthorized -- impossible: the group root key is derived
	// from the founder's own root key, so nobody else can produce one.
	for _, req := range []groupSignEventRequest{
		{Type: "role_grant", Subject: other.AccountID, Role: "admin"},
		{Type: "dissolve"},
	} {
		req.Identity = other
		req.State = added.State
		req.IssuedAt = time.Date(2026, 8, 2, 12, 5, 0, 0, time.UTC)
		if _, err := doGroupSignEvent(req); err == nil {
			t.Fatalf("%s: a non-founder must not be able to sign this", req.Type)
		}
	}
}

func TestGroupApplyReportsPerEventVerdicts(t *testing.T) {
	founder := newGroupIdentity(t)
	member := newGroupIdentity(t)
	created := groupCreate(t, founder, "")

	added, addEvent := signAndApply(t, founder, created.State, groupSignEventRequest{
		Type: "member_add", Subject: member.AccountID, Server: "https://a.example.org",
	})

	// Re-delivering a fact is routine, not an error: the same snapshot arrives
	// from several members.
	again, err := doGroupApplyEvents(groupApplyEventsRequest{
		State:  added.State,
		Events: []*group.Event{addEvent},
	})
	if err != nil {
		t.Fatal(err)
	}
	repeat := again.(*groupStateResponse)
	if len(repeat.Applied) != 0 || len(repeat.Known) != 1 || len(repeat.Rejected) != 0 {
		t.Fatalf("want one known and nothing else, got %+v", repeat)
	}
	if repeat.StateHash != added.StateHash {
		t.Fatal("state hash must not move when nothing new arrived")
	}

	// A tampered event is rejected with a reason, and does not fail the call:
	// a snapshot from a hostile peer must cost only its bad entries.
	tampered := *addEvent
	tampered.Subject = founder.AccountID
	out, err := doGroupApplyEvents(groupApplyEventsRequest{
		State:  added.State,
		Events: []*group.Event{&tampered},
	})
	if err != nil {
		t.Fatalf("a bad event must not fail the whole call: %v", err)
	}
	if got := out.(*groupStateResponse); len(got.Rejected) != 1 {
		t.Fatalf("want one rejection, got %+v", got.Rejected)
	}
}

func TestGroupEventTimeIsTruncatedForTheCaller(t *testing.T) {
	founder := newGroupIdentity(t)
	created := groupCreate(t, founder, "")

	// Dart stamps milliseconds. pkg/group refuses anything finer than a
	// second, so the boundary truncates rather than making every caller know.
	_, event := signAndApply(t, founder, created.State, groupSignEventRequest{
		Type:     "meta",
		Name:     "Renamed",
		IssuedAt: time.Date(2026, 8, 2, 12, 6, 0, 123456789, time.UTC),
	})
	if event.IssuedAt.Nanosecond() != 0 {
		t.Fatalf("issued_at = %v, want whole seconds", event.IssuedAt)
	}
}
