package main

// Groups (SRV-01 / APP-16). Like the rest of logic.go this file is
// deliberately cgo-free, so it builds and tests on the host.
//
// The whole point of putting groups here rather than in Dart is that the
// convergence rules exist once. Dart holds the state blob and hands it back
// untouched; it never interprets it, exactly as it already treats a ratchet
// session. A Dart-side bug therefore cannot produce a group state that
// disagrees with what another client computes from the same facts.

import (
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"time"

	"github.com/behringer24/freizone-server/pkg/devicecert"
	"github.com/behringer24/freizone-server/pkg/group"
)

// groupIdentity is the caller's own identity. Every group operation that
// signs something needs all of it: the account id and root key to say who is
// acting, the device key to actually sign, and the root private key both to
// mint the device certificate that proves the link and -- for the founder --
// to re-derive the group root key.
type groupIdentity struct {
	AccountID  string             `json:"account_id"`
	RootPub    ed25519.PublicKey  `json:"root_pub"`
	RootPriv   ed25519.PrivateKey `json:"root_priv"`
	DeviceID   string             `json:"device_id"`
	DevicePub  ed25519.PublicKey  `json:"device_pub"`
	DevicePriv ed25519.PrivateKey `json:"device_priv"`
}

// signer builds the self-describing identity block an event carries: a device
// certificate freshly signed under the root key, plus the account id and root
// key any recipient needs to check it against.
func (i groupIdentity) signer(issuedAt time.Time) (*group.Signer, error) {
	cert, err := devicecert.SignDeviceCertificate(
		i.AccountID, i.DeviceID, i.DevicePub, issuedAt, i.RootPriv,
	)
	if err != nil {
		return nil, fmt.Errorf("signing device certificate: %w", err)
	}
	return &group.Signer{
		AccountID:  i.AccountID,
		RootPubKey: i.RootPub,
		DeviceCert: *cert,
	}, nil
}

// groupEventTime normalizes a caller's timestamp to what the signing bytes
// can actually carry. Dart stamps milliseconds; pkg/group refuses anything
// finer than a second, because sub-second digits would be unsigned data that
// still influenced replay order. Truncating here rather than rejecting saves
// every caller from having to know that.
func groupEventTime(t time.Time) time.Time {
	if t.IsZero() {
		t = time.Now()
	}
	return t.UTC().Truncate(time.Second)
}

// loadGroupState reads a state blob back. An absent or empty blob is a group
// this device has not heard of yet -- the ordinary case for the first
// snapshot an invitee receives -- and starts empty rather than failing.
func loadGroupState(raw json.RawMessage) (*group.State, error) {
	state := group.NewState()
	if len(raw) == 0 || string(raw) == "null" {
		return state, nil
	}
	if err := json.Unmarshal(raw, state); err != nil {
		return nil, fmt.Errorf("reading group state: %w", err)
	}
	return state, nil
}

// groupStateResponse is what every mutating operation returns: the new blob,
// and the resolved view so the caller need not immediately ask for it.
type groupStateResponse struct {
	GroupID   string            `json:"group_id"`
	State     json.RawMessage   `json:"state"`
	StateHash string            `json:"state_hash"`
	Resolved  *group.Resolved   `json:"resolved"`
	Applied   []string          `json:"applied,omitempty"`
	Known     []string          `json:"known,omitempty"`
	Rejected  []group.Rejection `json:"rejected,omitempty"`
}

func newGroupStateResponse(state *group.State) (*groupStateResponse, error) {
	blob, err := json.Marshal(state)
	if err != nil {
		return nil, fmt.Errorf("writing group state: %w", err)
	}
	return &groupStateResponse{
		GroupID:   state.GroupID(),
		State:     blob,
		StateHash: state.StateHash(),
		Resolved:  state.Resolve(),
	}, nil
}

type groupCreateRequest struct {
	Identity groupIdentity `json:"identity"`

	// Server is this account's own home server, recorded in the genesis event
	// so every other member knows where to deliver to the founder. Without it
	// the founder is the one member nobody can address until they speak first.
	Server   string    `json:"server"`
	Name     string    `json:"name"`
	Topic    string    `json:"topic"`
	IssuedAt time.Time `json:"issued_at"`
}

// doGroupCreate founds a group.
//
// The group root key is derived from this account's root key and a fresh
// nonce that lives in the genesis event, so it survives total device loss:
// restore the seed phrase, get the state back from any member, re-derive.
// Nothing is stored that could be lost separately.
func doGroupCreate(req groupCreateRequest) (any, error) {
	if req.Server == "" {
		return nil, fmt.Errorf("group create: server is required")
	}
	nonce, err := group.NewNonce()
	if err != nil {
		return nil, err
	}
	rootPriv, err := group.DeriveRootKey(req.Identity.RootPriv.Seed(), nonce)
	if err != nil {
		return nil, err
	}
	groupID, err := group.DeriveID(rootPriv.Public().(ed25519.PublicKey))
	if err != nil {
		return nil, err
	}

	issuedAt := groupEventTime(req.IssuedAt)
	genesis := &group.Event{
		Type:       group.EventGenesis,
		GroupID:    groupID,
		IssuedAt:   issuedAt,
		RootPubKey: rootPriv.Public().(ed25519.PublicKey),
		Nonce:      nonce,
		Subject:    req.Identity.AccountID,
		Server:     req.Server,
	}
	if err := group.SignRoot(genesis, rootPriv); err != nil {
		return nil, err
	}

	events := []*group.Event{genesis}
	if req.Name != "" || req.Topic != "" {
		meta := &group.Event{
			Type:     group.EventMeta,
			GroupID:  groupID,
			IssuedAt: issuedAt,
			Name:     req.Name,
			Topic:    req.Topic,
		}
		signer, err := req.Identity.signer(issuedAt)
		if err != nil {
			return nil, err
		}
		if err := group.SignDevice(meta, signer, req.Identity.DevicePriv); err != nil {
			return nil, err
		}
		events = append(events, meta)
	}

	state := group.NewState()
	if result := state.Apply(events); len(result.Rejected) > 0 {
		return nil, fmt.Errorf("group create: own event rejected: %s", result.Rejected[0].Reason)
	}
	return newGroupStateResponse(state)
}

type groupSignEventRequest struct {
	Identity groupIdentity   `json:"identity"`
	State    json.RawMessage `json:"state"`
	IssuedAt time.Time       `json:"issued_at"`

	Type    string `json:"type"`
	Subject string `json:"subject"`
	Server  string `json:"server"`
	// Role is "moderator" or "admin". Spelled out rather than numbered, so
	// the wire's rank values stay an internal detail of pkg/group.
	Role  string `json:"role"`
	Name  string `json:"name"`
	Topic string `json:"topic"`
}

type groupSignEventResponse struct {
	Event *group.Event `json:"event"`
}

// doGroupSignEvent builds and signs one group event.
//
// Which key signs it is not the caller's decision and deliberately not their
// parameter: raising someone to admin is the founder's alone and needs the
// group root key, everything below it is an ordinary device signature. Asking
// the caller would be one more thing a client could get wrong for no benefit.
func doGroupSignEvent(req groupSignEventRequest) (any, error) {
	state, err := loadGroupState(req.State)
	if err != nil {
		return nil, err
	}
	genesis := state.Genesis()
	if genesis == nil {
		return nil, fmt.Errorf("group sign: no genesis event in this state")
	}

	eventType, err := parseGroupEventType(req.Type)
	if err != nil {
		return nil, err
	}
	event := &group.Event{
		Type:     eventType,
		GroupID:  state.GroupID(),
		IssuedAt: groupEventTime(req.IssuedAt),
		Subject:  req.Subject,
		Server:   req.Server,
		Name:     req.Name,
		Topic:    req.Topic,
	}

	needsRootKey := eventType == group.EventDissolve
	if eventType == group.EventRoleGrant || eventType == group.EventRoleRevoke {
		role, err := parseGroupRole(req.Role)
		if err != nil {
			return nil, err
		}
		event.Role = role
		// Only admin is above what a device signature can authorize.
		needsRootKey = role == group.RoleAdmin
	}

	if needsRootKey {
		if genesis.Subject != req.Identity.AccountID {
			return nil, fmt.Errorf("group sign: only the founder can do that")
		}
		rootPriv, err := group.DeriveRootKey(req.Identity.RootPriv.Seed(), genesis.Nonce)
		if err != nil {
			return nil, err
		}
		if err := group.SignRoot(event, rootPriv); err != nil {
			return nil, err
		}
		return groupSignEventResponse{Event: event}, nil
	}

	signer, err := req.Identity.signer(event.IssuedAt)
	if err != nil {
		return nil, err
	}
	if err := group.SignDevice(event, signer, req.Identity.DevicePriv); err != nil {
		return nil, err
	}
	return groupSignEventResponse{Event: event}, nil
}

type groupApplyEventsRequest struct {
	State  json.RawMessage `json:"state"`
	Events []*group.Event  `json:"events"`
}

// doGroupApplyEvents merges events into a state blob, whether they are this
// device's own or a peer's.
//
// Admission checks shape, signer chain and signature -- never authority.
// Whether the signer was *allowed* to do this depends on every other fact in
// the group and on when those facts arrive, so it is decided by the fold. An
// event that merely overtook the grant authorizing it must not be discarded:
// it would never come back.
func doGroupApplyEvents(req groupApplyEventsRequest) (any, error) {
	state, err := loadGroupState(req.State)
	if err != nil {
		return nil, err
	}
	result := state.Apply(req.Events)

	resp, err := newGroupStateResponse(state)
	if err != nil {
		return nil, err
	}
	resp.Applied = result.Applied
	resp.Known = result.Known
	resp.Rejected = result.Rejected
	return resp, nil
}

type groupResolveStateRequest struct {
	State json.RawMessage `json:"state"`
}

// doGroupResolveState folds a state blob into the view the UI renders:
// members with roles, who has accepted, the name and topic, the state hash.
func doGroupResolveState(req groupResolveStateRequest) (any, error) {
	state, err := loadGroupState(req.State)
	if err != nil {
		return nil, err
	}
	return newGroupStateResponse(state)
}

// groupEventTypes is the set a client may ask for. Genesis is deliberately
// absent: it is minted by doGroupCreate, which is the only place that has a
// group root key to sign it with and a nonce to put in it.
var groupEventTypes = map[string]group.EventType{
	"role_grant":    group.EventRoleGrant,
	"role_revoke":   group.EventRoleRevoke,
	"member_add":    group.EventMemberAdd,
	"member_remove": group.EventMemberRemove,
	"join_accept":   group.EventJoinAccept,
	"leave":         group.EventLeave,
	"meta":          group.EventMeta,
	"dissolve":      group.EventDissolve,
}

func parseGroupEventType(name string) (group.EventType, error) {
	if t, ok := groupEventTypes[name]; ok {
		return t, nil
	}
	return "", fmt.Errorf("group sign: unknown event type %q", name)
}

func parseGroupRole(name string) (group.Role, error) {
	switch name {
	case "moderator":
		return group.RoleModerator, nil
	case "admin":
		return group.RoleAdmin, nil
	default:
		return group.RoleNone, fmt.Errorf("group sign: role must be moderator or admin, got %q", name)
	}
}
