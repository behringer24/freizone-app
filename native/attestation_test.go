package main

import (
	"crypto/ed25519"
	"testing"
	"time"

	"github.com/behringer24/freizone-server/pkg/attest"
)

// withTestIssuer temporarily replaces attest.TrustedIssuers, mirroring
// freizone-server's cmd/server/attestation_test.go -- doVerifyAttestation is
// the one place in this package that consults that var directly, and this
// repo has no more access to the real production private keys than that one
// does (see docs/design/19-attested-servers.md in freizone-server on why
// they never live in a repository).
func withTestIssuer(t *testing.T, pub ed25519.PublicKey) {
	t.Helper()
	original := attest.TrustedIssuers
	attest.TrustedIssuers = []ed25519.PublicKey{pub}
	t.Cleanup(func() { attest.TrustedIssuers = original })
}

// signTestAttestation signs a fresh attestation with a freshly generated
// (test-only) issuer keypair, returning the encoded token and its public
// half -- pass the latter to withTestIssuer to make the token verify.
func signTestAttestation(t *testing.T, domain string, expiresAt time.Time) (string, ed25519.PublicKey) {
	t.Helper()
	pub, priv, err := attest.GenerateIssuerKey()
	if err != nil {
		t.Fatalf("GenerateIssuerKey() error = %v", err)
	}
	a, err := attest.Sign(domain, attest.TierCommunity, "Example GmbH", 0, time.Now(), expiresAt, priv)
	if err != nil {
		t.Fatalf("Sign() error = %v", err)
	}
	token, err := a.Encode()
	if err != nil {
		t.Fatalf("Encode() error = %v", err)
	}
	return token, pub
}

func TestDoVerifyAttestationValid(t *testing.T) {
	token, pub := signTestAttestation(t, "chat.example.org", time.Now().Add(24*time.Hour))
	withTestIssuer(t, pub)

	respAny, err := doVerifyAttestation(verifyAttestationRequest{Token: token, Domain: "chat.example.org"})
	if err != nil {
		t.Fatalf("doVerifyAttestation() error = %v", err)
	}
	resp := respAny.(attestationResult)
	if !resp.Valid {
		t.Fatal("expected Valid: true for a genuine, current, matching-domain attestation")
	}
	if resp.Tier != attest.TierCommunity || resp.Subject != "Example GmbH" {
		t.Errorf("unexpected tier/subject: %+v", resp)
	}

	// Valid checks the domain case-insensitively -- confirm that survives
	// the round trip through this wrapper too.
	respUpper, err := doVerifyAttestation(verifyAttestationRequest{Token: token, Domain: "CHAT.EXAMPLE.ORG"})
	if err != nil {
		t.Fatalf("doVerifyAttestation() error = %v", err)
	}
	if !respUpper.(attestationResult).Valid {
		t.Error("expected a case-insensitive domain match to still verify")
	}
}

func TestDoVerifyAttestationWrongDomain(t *testing.T) {
	token, pub := signTestAttestation(t, "chat.example.org", time.Now().Add(24*time.Hour))
	withTestIssuer(t, pub)

	resp, err := doVerifyAttestation(verifyAttestationRequest{Token: token, Domain: "evil.example.org"})
	if err != nil {
		t.Fatalf("doVerifyAttestation() error = %v", err)
	}
	if resp.(attestationResult).Valid {
		t.Error("expected Valid: false for a domain this attestation is not for -- a stolen token must not verify elsewhere")
	}
}

func TestDoVerifyAttestationExpired(t *testing.T) {
	token, pub := signTestAttestation(t, "chat.example.org", time.Now().Add(-time.Hour))
	withTestIssuer(t, pub)

	resp, err := doVerifyAttestation(verifyAttestationRequest{Token: token, Domain: "chat.example.org"})
	if err != nil {
		t.Fatalf("doVerifyAttestation() error = %v", err)
	}
	if resp.(attestationResult).Valid {
		t.Error("expected Valid: false for a lapsed attestation")
	}
}

func TestDoVerifyAttestationUntrustedIssuer(t *testing.T) {
	token, _ := signTestAttestation(t, "chat.example.org", time.Now().Add(24*time.Hour))
	// A different, unrelated key is "trusted" here -- the key that actually
	// signed the token is deliberately left out of the set.
	other, _, err := attest.GenerateIssuerKey()
	if err != nil {
		t.Fatalf("GenerateIssuerKey() error = %v", err)
	}
	withTestIssuer(t, other)

	resp, err := doVerifyAttestation(verifyAttestationRequest{Token: token, Domain: "chat.example.org"})
	if err != nil {
		t.Fatalf("doVerifyAttestation() error = %v", err)
	}
	if resp.(attestationResult).Valid {
		t.Error("expected Valid: false for a signature from an issuer key outside the trusted set")
	}
}

func TestDoVerifyAttestationMalformedToken(t *testing.T) {
	resp, err := doVerifyAttestation(verifyAttestationRequest{Token: "not-a-token", Domain: "chat.example.org"})
	if err != nil {
		t.Fatalf("doVerifyAttestation() error = %v", err)
	}
	if resp.(attestationResult).Valid {
		t.Error("expected Valid: false for a malformed token")
	}
}
