package main

// Same no-cgo rule as core_test.go: these call the do* logic functions
// directly, so they run on the host without the NDK toolchain.

import (
	"errors"
	"fmt"
	"testing"

	"github.com/behringer24/freizone-server/pkg/ratchet"
)

// establishPair returns a matched initiator/responder pair, ready to exchange
// messages -- the starting point for driving a decrypt into failure.
func establishPair(t *testing.T) (initiator, responder *ratchet.Session) {
	t.Helper()
	bobDH := mustX25519(t)
	bobSPK := mustX25519(t)

	aliceDH := mustX25519(t)
	initAny, err := doInitiateSession(initiateSessionRequest{
		LocalDHIdentityPriv: aliceDH.Priv,
		Remote: remoteBundleDTO{
			DHIdentityPub:   bobDH.Pub,
			SignedPrekeyID:  1,
			SignedPrekeyPub: bobSPK.Pub,
		},
	})
	if err != nil {
		t.Fatalf("doInitiateSession() error = %v", err)
	}
	initResp := initAny.(initiateSessionResponse)

	respAny, err := doRespondToSession(respondToSessionRequest{
		LocalDHIdentityPriv: bobDH.Priv,
		SignedPrekeyPriv:    bobSPK.Priv,
		Initial:             initResp.Initial,
	})
	if err != nil {
		t.Fatalf("doRespondToSession() error = %v", err)
	}
	return initResp.Session, respAny.(respondToSessionResponse).Session
}

// The Dart receive path decides whether to recover a conversation from this
// code, so it has to survive the trip out of doSessionDecrypt.
func TestSessionDecryptTagsAuthenticationFailure(t *testing.T) {
	alice, bob := establishPair(t)

	encAny, err := doSessionEncrypt(sessionEncryptRequest{Session: alice, Plaintext: []byte("hello")})
	if err != nil {
		t.Fatalf("doSessionEncrypt() error = %v", err)
	}
	enc := encAny.(sessionEncryptResponse)
	tampered := append([]byte{}, enc.Ciphertext...)
	tampered[0] ^= 0xFF

	_, err = doSessionDecrypt(sessionDecryptRequest{
		Session:    bob,
		Header:     enc.Header,
		Ciphertext: tampered,
	})
	if err == nil {
		t.Fatal("doSessionDecrypt() succeeded on tampered ciphertext")
	}
	if got := errorCode(err); got != ratchet.FailureAuthentication {
		t.Errorf("errorCode() = %q, want %q", got, ratchet.FailureAuthentication)
	}
}

// A redelivery must be distinguishable from a desync, or the app would throw
// away healthy sessions over normal at-least-once delivery.
func TestSessionDecryptTagsDuplicate(t *testing.T) {
	alice, bob := establishPair(t)

	encAny, err := doSessionEncrypt(sessionEncryptRequest{Session: alice, Plaintext: []byte("hello")})
	if err != nil {
		t.Fatalf("doSessionEncrypt() error = %v", err)
	}
	enc := encAny.(sessionEncryptResponse)

	req := sessionDecryptRequest{Session: bob, Header: enc.Header, Ciphertext: enc.Ciphertext}
	if _, err := doSessionDecrypt(req); err != nil {
		t.Fatalf("doSessionDecrypt() error = %v", err)
	}
	_, err = doSessionDecrypt(req)
	if got := errorCode(err); got != ratchet.FailureDuplicateMessage {
		t.Errorf("errorCode() = %q, want %q", got, ratchet.FailureDuplicateMessage)
	}
}

func TestErrorCodeAbsentForUnclassifiedFailures(t *testing.T) {
	if _, err := doSessionDecrypt(sessionDecryptRequest{}); err == nil {
		t.Fatal("doSessionDecrypt() with no session succeeded")
	} else if got := errorCode(err); got != "" {
		t.Errorf("errorCode() = %q, want empty for a plain error", got)
	}

	// Still found once a caller has wrapped it with more context.
	wrapped := fmt.Errorf("while syncing: %w", codedError{code: "x", err: errors.New("boom")})
	if got := errorCode(wrapped); got != "x" {
		t.Errorf("errorCode(wrapped) = %q, want %q", got, "x")
	}
}
