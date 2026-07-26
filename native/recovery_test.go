package main

// Host tests for the recovery seed-phrase logic (APP-01). Like core_test.go,
// these call the do* functions directly with plain Go values.

import (
	"bytes"
	"testing"
)

func TestRevealAndRestorePreservesAccount(t *testing.T) {
	orig, err := doGenerateIdentity()
	if err != nil {
		t.Fatalf("doGenerateIdentity() error = %v", err)
	}

	phraseAny, err := doRevealRecoveryPhrase(revealRecoveryPhraseRequest{RootPriv: orig.RootPriv})
	if err != nil {
		t.Fatalf("doRevealRecoveryPhrase() error = %v", err)
	}
	phrase := phraseAny.(recoveryPhraseResponse)
	if len(phrase.Words) != 24 {
		t.Fatalf("phrase has %d words, want 24", len(phrase.Words))
	}

	restoredAny, err := doRestoreIdentityFromSeed(restoreIdentityFromSeedRequest{Words: phrase.Words})
	if err != nil {
		t.Fatalf("doRestoreIdentityFromSeed() error = %v", err)
	}
	restored := restoredAny.(*generateIdentityResponse)

	// Same root key -> same account id / short id (the whole point of APP-01).
	if restored.AccountID != orig.AccountID {
		t.Errorf("account id changed: %q -> %q", orig.AccountID, restored.AccountID)
	}
	if !bytes.Equal(restored.RootPriv, orig.RootPriv) {
		t.Errorf("root private key not preserved")
	}
	if !bytes.Equal(restored.RootPub, orig.RootPub) {
		t.Errorf("root public key not preserved")
	}

	// ...but a *fresh* device keypair (the phrase carries the root key only).
	if restored.DeviceID == orig.DeviceID {
		t.Errorf("expected a fresh device id, got the original %q", orig.DeviceID)
	}
	if bytes.Equal(restored.DevicePriv, orig.DevicePriv) {
		t.Errorf("expected a fresh device private key")
	}
}

func TestRestoreRejectsBadPhrase(t *testing.T) {
	// 24 valid words but a deliberately wrong checksum (all "abandon").
	bad := make([]string, 24)
	for i := range bad {
		bad[i] = "abandon"
	}
	if _, err := doRestoreIdentityFromSeed(restoreIdentityFromSeedRequest{Words: bad}); err == nil {
		t.Fatal("expected error for bad-checksum phrase, got nil")
	}

	// Unknown word.
	unknown := append([]string(nil), bad...)
	unknown[0] = "notaword"
	if _, err := doRestoreIdentityFromSeed(restoreIdentityFromSeedRequest{Words: unknown}); err == nil {
		t.Fatal("expected error for unknown word, got nil")
	}
}

func TestRevealRejectsShortRootKey(t *testing.T) {
	if _, err := doRevealRecoveryPhrase(revealRecoveryPhraseRequest{RootPriv: make([]byte, 32)}); err == nil {
		t.Fatal("expected error for 32-byte root_priv (must be 64), got nil")
	}
}

func TestRecoveryWordlist(t *testing.T) {
	resp, err := doRecoveryWordlist()
	if err != nil {
		t.Fatalf("doRecoveryWordlist() error = %v", err)
	}
	if len(resp.Words) != 2048 {
		t.Fatalf("wordlist has %d words, want 2048", len(resp.Words))
	}
}
