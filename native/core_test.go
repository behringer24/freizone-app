package main

// Tests call the do* logic functions from logic.go directly, with plain Go
// values -- no cgo, no C strings. This file intentionally does not
// `import "C"`: Go's test tooling doesn't support cgo in _test.go files
// for cross-compiled test binaries, and this is what lets these tests run
// on the host even though the package as a whole (core.go) requires cgo.
// The thin core.go glue (JSON marshal/unmarshal, C string ownership) is
// exercised for real by the Dart FFI integration instead.

import (
	"testing"
	"time"

	"github.com/behringer24/freizone-server/pkg/devicecert"
)

func TestGenerateIdentityAndDeviceCertificateRoundTrip(t *testing.T) {
	identity, err := doGenerateIdentity()
	if err != nil {
		t.Fatalf("doGenerateIdentity() error = %v", err)
	}
	if identity.AccountID == "" || identity.DeviceID == "" {
		t.Fatalf("incomplete identity: %+v", identity)
	}

	addrResp, err := doVerifyAddressID(verifyAddressIDRequest{ID: identity.AccountID, RootPub: identity.RootPub})
	if err != nil {
		t.Fatalf("doVerifyAddressID() error = %v", err)
	}
	assertValid(t, addrResp, true)

	issuedAt := time.Now().UTC().Truncate(time.Second)
	certAny, err := doSignDeviceCertificate(signDeviceCertificateRequest{
		AccountID: identity.AccountID,
		DeviceID:  identity.DeviceID,
		DevicePub: identity.DevicePub,
		IssuedAt:  issuedAt,
		RootPriv:  identity.RootPriv,
	})
	if err != nil {
		t.Fatalf("doSignDeviceCertificate() error = %v", err)
	}
	cert, ok := certAny.(*devicecert.DeviceCertificate)
	if !ok {
		t.Fatalf("expected *devicecert.DeviceCertificate, got %T", certAny)
	}

	verifyResp, err := doVerifyDeviceCertificate(verifyDeviceCertificateRequest{
		Cert:    *cert,
		RootPub: identity.RootPub,
	})
	if err != nil {
		t.Fatalf("doVerifyDeviceCertificate() error = %v", err)
	}
	assertValid(t, verifyResp, true)

	// Tamper: verify against a different (freshly generated) root key must fail.
	other, err := doGenerateIdentity()
	if err != nil {
		t.Fatalf("doGenerateIdentity() error = %v", err)
	}
	tamperedResp, err := doVerifyDeviceCertificate(verifyDeviceCertificateRequest{
		Cert:    *cert,
		RootPub: other.RootPub,
	})
	if err != nil {
		t.Fatalf("doVerifyDeviceCertificate() error = %v", err)
	}
	assertValid(t, tamperedResp, false)
}

func TestX3DHAndDoubleRatchetAndEnvelopeRoundTrip(t *testing.T) {
	// Bob generates his DH identity + signed prekey.
	bobDH := mustX25519(t)
	bobSPK := mustX25519(t)

	bundle := remoteBundleDTO{
		DHIdentityPub:   bobDH.Pub,
		SignedPrekeyID:  1,
		SignedPrekeyPub: bobSPK.Pub,
	}

	// Alice initiates.
	aliceDH := mustX25519(t)
	initAny, err := doInitiateSession(initiateSessionRequest{
		LocalDHIdentityPriv: aliceDH.Priv,
		Remote:              bundle,
	})
	if err != nil {
		t.Fatalf("doInitiateSession() error = %v", err)
	}
	initResp := initAny.(initiateSessionResponse)

	// Bob responds.
	respAny, err := doRespondToSession(respondToSessionRequest{
		LocalDHIdentityPriv: bobDH.Priv,
		SignedPrekeyPriv:    bobSPK.Priv,
		Initial:             initResp.Initial,
	})
	if err != nil {
		t.Fatalf("doRespondToSession() error = %v", err)
	}
	respResp := respAny.(respondToSessionResponse)

	// Alice encrypts the first message.
	plaintext := []byte("hello from the FFI boundary")
	encAny, err := doSessionEncrypt(sessionEncryptRequest{Session: initResp.Session, Plaintext: plaintext})
	if err != nil {
		t.Fatalf("doSessionEncrypt() error = %v", err)
	}
	encResp := encAny.(sessionEncryptResponse)

	// Round-trip through BuildEnvelope/ParseEnvelope.
	buildAny, err := doBuildEnvelope(buildEnvelopeRequest{Initial: initResp.Initial, Header: encResp.Header, Ciphertext: encResp.Ciphertext})
	if err != nil {
		t.Fatalf("doBuildEnvelope() error = %v", err)
	}
	buildResp := buildAny.(buildEnvelopeResponse)

	parseAny, err := doParseEnvelope(parseEnvelopeRequest{Payload: buildResp.Payload})
	if err != nil {
		t.Fatalf("doParseEnvelope() error = %v", err)
	}
	parseResp := parseAny.(parseEnvelopeResponse)

	// Bob decrypts using the envelope-round-tripped header/ciphertext.
	decAny, err := doSessionDecrypt(sessionDecryptRequest{Session: respResp.Session, Header: parseResp.Header, Ciphertext: parseResp.Ciphertext})
	if err != nil {
		t.Fatalf("doSessionDecrypt() error = %v", err)
	}
	decResp := decAny.(sessionDecryptResponse)

	if string(decResp.Plaintext) != string(plaintext) {
		t.Errorf("plaintext = %q, want %q", decResp.Plaintext, plaintext)
	}
}

func mustX25519(t *testing.T) x25519KeyPair {
	t.Helper()
	pair, err := doGenerateX25519KeyPair()
	if err != nil {
		t.Fatalf("doGenerateX25519KeyPair() error = %v", err)
	}
	return *pair
}

func assertValid(t *testing.T, respAny any, want bool) {
	t.Helper()
	v, ok := respAny.(verifyResult)
	if !ok {
		t.Fatalf("expected verifyResult, got %T", respAny)
	}
	if v.Valid != want {
		t.Errorf("valid = %v, want %v", v.Valid, want)
	}
}
