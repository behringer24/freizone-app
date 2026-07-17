package main

// All actual request/response types and logic live here, deliberately
// free of cgo ("C" types) so this file (and its tests) can be built and
// run on the host -- only core.go's thin //export wrappers need cgo and
// the Android NDK toolchain. Go's test tooling doesn't support cgo in
// _test.go files for cross-compiled test binaries, so keeping the cgo
// surface minimal and separate is what makes this package testable at
// all without a connected device.

import (
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/behringer24/freizone-server/pkg/address"
	"github.com/behringer24/freizone-server/pkg/devicecert"
	"github.com/behringer24/freizone-server/pkg/httpsig"
	"github.com/behringer24/freizone-server/pkg/ratchet"
	"github.com/behringer24/freizone-server/pkg/wire"
)

// resultEnvelope is the shared JSON shape every exported function returns:
// either {"ok":true,"data":...} or {"ok":false,"error":"..."}.
type resultEnvelope struct {
	OK    bool            `json:"ok"`
	Data  json.RawMessage `json:"data,omitempty"`
	Error string          `json:"error,omitempty"`
}

// verifyResult is the shared shape for "did this signature/certificate
// verify" calls: verification failure is a normal, expected outcome (not a
// call error), same as devclient's own error handling.
type verifyResult struct {
	Valid bool `json:"valid"`
}

// --- Identity -------------------------------------------------------------

type generateIdentityResponse struct {
	AccountID  string `json:"account_id"`
	RootPub    []byte `json:"root_pub"`
	RootPriv   []byte `json:"root_priv"`
	DeviceID   string `json:"device_id"`
	DevicePub  []byte `json:"device_pub"`
	DevicePriv []byte `json:"device_priv"`
}

// doGenerateIdentity generates a fresh root key, device key, and derives
// the account id.
func doGenerateIdentity() (*generateIdentityResponse, error) {
	rootPub, rootPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generating root key: %w", err)
	}
	devicePub, devicePriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generating device key: %w", err)
	}
	deviceID, err := devicecert.NewDeviceID()
	if err != nil {
		return nil, err
	}
	accountID, err := address.DeriveID(rootPub)
	if err != nil {
		return nil, fmt.Errorf("deriving account id: %w", err)
	}

	return &generateIdentityResponse{
		AccountID:  accountID,
		RootPub:    rootPub,
		RootPriv:   rootPriv,
		DeviceID:   deviceID,
		DevicePub:  devicePub,
		DevicePriv: devicePriv,
	}, nil
}

type verifyAddressIDRequest struct {
	ID      string `json:"id"`
	RootPub []byte `json:"root_pub"`
}

// doVerifyAddressID checks that req.ID is the correct, self-certifying
// address for req.RootPub.
func doVerifyAddressID(req verifyAddressIDRequest) (any, error) {
	ok, err := address.Verify(req.ID, ed25519.PublicKey(req.RootPub))
	if err != nil {
		return verifyResult{Valid: false}, nil
	}
	return verifyResult{Valid: ok}, nil
}

// --- Device certificate -----------------------------------------------------

type signDeviceCertificateRequest struct {
	AccountID string             `json:"account_id"`
	DeviceID  string             `json:"device_id"`
	DevicePub ed25519.PublicKey  `json:"device_pub"`
	IssuedAt  time.Time          `json:"issued_at"`
	RootPriv  ed25519.PrivateKey `json:"root_priv"`
}

// doSignDeviceCertificate signs a new device certificate with the
// account's root private key.
func doSignDeviceCertificate(req signDeviceCertificateRequest) (any, error) {
	return devicecert.SignDeviceCertificate(req.AccountID, req.DeviceID, req.DevicePub, req.IssuedAt, req.RootPriv)
}

type verifyDeviceCertificateRequest struct {
	Cert    devicecert.DeviceCertificate `json:"cert"`
	RootPub ed25519.PublicKey            `json:"root_pub"`
}

// doVerifyDeviceCertificate checks a device certificate against the
// account's root public key.
func doVerifyDeviceCertificate(req verifyDeviceCertificateRequest) (any, error) {
	cert := req.Cert
	return verifyResult{Valid: cert.Verify(req.RootPub) == nil}, nil
}

// --- X3DH key material: DH identity + signed prekey certificates ----------

type x25519KeyPair struct {
	Pub  []byte `json:"pub"`
	Priv []byte `json:"priv"`
}

// doGenerateX25519KeyPair generates a fresh X25519 keypair (used for DH
// identity keys, signed prekeys, and one-time prekeys).
func doGenerateX25519KeyPair() (*x25519KeyPair, error) {
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generating x25519 key pair: %w", err)
	}
	return &x25519KeyPair{Pub: priv.PublicKey().Bytes(), Priv: priv.Bytes()}, nil
}

type signDHIdentityCertificateRequest struct {
	AccountID  string             `json:"account_id"`
	DeviceID   string             `json:"device_id"`
	DHPub      []byte             `json:"dh_pub"`
	IssuedAt   time.Time          `json:"issued_at"`
	DevicePriv ed25519.PrivateKey `json:"device_priv"`
}

// doSignDHIdentityCertificate signs a device's X25519 DH identity key with
// its own Ed25519 device key.
func doSignDHIdentityCertificate(req signDHIdentityCertificateRequest) (any, error) {
	return devicecert.SignDHIdentityCertificate(req.AccountID, req.DeviceID, req.DHPub, req.IssuedAt, req.DevicePriv)
}

type verifyDHIdentityCertificateRequest struct {
	Cert      devicecert.DHIdentityCertificate `json:"cert"`
	DevicePub ed25519.PublicKey                `json:"device_pub"`
}

func doVerifyDHIdentityCertificate(req verifyDHIdentityCertificateRequest) (any, error) {
	cert := req.Cert
	return verifyResult{Valid: cert.Verify(req.DevicePub) == nil}, nil
}

type signSignedPrekeyCertificateRequest struct {
	AccountID     string             `json:"account_id"`
	DeviceID      string             `json:"device_id"`
	KeyID         uint32             `json:"key_id"`
	DHIdentityPub []byte             `json:"dh_identity_pub"`
	PrekeyPub     []byte             `json:"prekey_pub"`
	IssuedAt      time.Time          `json:"issued_at"`
	DevicePriv    ed25519.PrivateKey `json:"device_priv"`
}

// doSignSignedPrekeyCertificate signs a rotatable X3DH signed prekey,
// bound to a specific DH identity key, with the device's own Ed25519 key.
func doSignSignedPrekeyCertificate(req signSignedPrekeyCertificateRequest) (any, error) {
	return devicecert.SignSignedPrekeyCertificate(req.AccountID, req.DeviceID, req.KeyID, req.DHIdentityPub, req.PrekeyPub, req.IssuedAt, req.DevicePriv)
}

type verifySignedPrekeyCertificateRequest struct {
	Cert      devicecert.SignedPrekeyCertificate `json:"cert"`
	DevicePub ed25519.PublicKey                  `json:"device_pub"`
}

func doVerifySignedPrekeyCertificate(req verifySignedPrekeyCertificateRequest) (any, error) {
	cert := req.Cert
	return verifyResult{Valid: cert.Verify(req.DevicePub) == nil}, nil
}

// --- X3DH session establishment -------------------------------------------

type remoteBundleDTO struct {
	DHIdentityPub    []byte  `json:"dh_identity_pub"`
	SignedPrekeyID   uint32  `json:"signed_prekey_id"`
	SignedPrekeyPub  []byte  `json:"signed_prekey_pub"`
	OneTimePrekeyID  *uint32 `json:"one_time_prekey_id,omitempty"`
	OneTimePrekeyPub []byte  `json:"one_time_prekey_pub,omitempty"`
}

type initiateSessionRequest struct {
	LocalDHIdentityPriv []byte          `json:"local_dh_identity_priv"`
	Remote              remoteBundleDTO `json:"remote"`
}

type initiateSessionResponse struct {
	Session *ratchet.Session        `json:"session"`
	Initial *ratchet.InitialMessage `json:"initial"`
}

// doInitiateSession runs X3DH as the initiator against a claimed prekey
// bundle and returns a ready-to-encrypt session plus the InitialMessage
// the responder needs.
func doInitiateSession(req initiateSessionRequest) (any, error) {
	curve := ecdh.X25519()

	localPriv, err := curve.NewPrivateKey(req.LocalDHIdentityPriv)
	if err != nil {
		return nil, fmt.Errorf("local dh identity private key: %w", err)
	}
	dhPub, err := curve.NewPublicKey(req.Remote.DHIdentityPub)
	if err != nil {
		return nil, fmt.Errorf("remote dh identity public key: %w", err)
	}
	spkPub, err := curve.NewPublicKey(req.Remote.SignedPrekeyPub)
	if err != nil {
		return nil, fmt.Errorf("remote signed prekey public key: %w", err)
	}

	remote := ratchet.RemoteBundle{
		DHIdentityPubKey: dhPub,
		SignedPrekeyID:   req.Remote.SignedPrekeyID,
		SignedPrekeyPub:  spkPub,
	}
	if req.Remote.OneTimePrekeyID != nil {
		otpkPub, err := curve.NewPublicKey(req.Remote.OneTimePrekeyPub)
		if err != nil {
			return nil, fmt.Errorf("remote one-time prekey public key: %w", err)
		}
		remote.OneTimePrekeyID = req.Remote.OneTimePrekeyID
		remote.OneTimePrekeyPub = otpkPub
	}

	session, initial, err := ratchet.InitiateSession(localPriv, remote)
	if err != nil {
		return nil, err
	}
	return initiateSessionResponse{Session: session, Initial: initial}, nil
}

type respondToSessionRequest struct {
	LocalDHIdentityPriv []byte                  `json:"local_dh_identity_priv"`
	SignedPrekeyPriv    []byte                  `json:"signed_prekey_priv"`
	OneTimePrekeyPriv   []byte                  `json:"one_time_prekey_priv,omitempty"`
	Initial             *ratchet.InitialMessage `json:"initial"`
}

type respondToSessionResponse struct {
	Session *ratchet.Session `json:"session"`
}

// doRespondToSession runs X3DH as the responder given an initiator's
// InitialMessage.
func doRespondToSession(req respondToSessionRequest) (any, error) {
	curve := ecdh.X25519()

	dhPriv, err := curve.NewPrivateKey(req.LocalDHIdentityPriv)
	if err != nil {
		return nil, fmt.Errorf("local dh identity private key: %w", err)
	}
	spkPriv, err := curve.NewPrivateKey(req.SignedPrekeyPriv)
	if err != nil {
		return nil, fmt.Errorf("signed prekey private key: %w", err)
	}

	var otpkPriv *ecdh.PrivateKey
	if len(req.OneTimePrekeyPriv) > 0 {
		otpkPriv, err = curve.NewPrivateKey(req.OneTimePrekeyPriv)
		if err != nil {
			return nil, fmt.Errorf("one-time prekey private key: %w", err)
		}
	}

	session, err := ratchet.RespondToSession(dhPriv, spkPriv, otpkPriv, req.Initial)
	if err != nil {
		return nil, err
	}
	return respondToSessionResponse{Session: session}, nil
}

// --- Double Ratchet message encryption -------------------------------------

type sessionEncryptRequest struct {
	Session   *ratchet.Session `json:"session"`
	Plaintext []byte           `json:"plaintext"`
}

type sessionEncryptResponse struct {
	Session    *ratchet.Session `json:"session"`
	Header     ratchet.Header   `json:"header"`
	Ciphertext []byte           `json:"ciphertext"`
}

// doSessionEncrypt advances session's sending chain and encrypts
// plaintext. Returns the (mutated) session for the caller to persist.
func doSessionEncrypt(req sessionEncryptRequest) (any, error) {
	if req.Session == nil {
		return nil, errors.New("session is required")
	}
	header, ciphertext, err := req.Session.Encrypt(req.Plaintext)
	if err != nil {
		return nil, err
	}
	return sessionEncryptResponse{Session: req.Session, Header: header, Ciphertext: ciphertext}, nil
}

type sessionDecryptRequest struct {
	Session    *ratchet.Session `json:"session"`
	Header     ratchet.Header   `json:"header"`
	Ciphertext []byte           `json:"ciphertext"`
}

type sessionDecryptResponse struct {
	Session   *ratchet.Session `json:"session"`
	Plaintext []byte           `json:"plaintext"`
}

// doSessionDecrypt authenticates and decrypts ciphertext, performing a DH
// ratchet step first if needed. Returns the (mutated) session for the
// caller to persist.
func doSessionDecrypt(req sessionDecryptRequest) (any, error) {
	if req.Session == nil {
		return nil, errors.New("session is required")
	}
	plaintext, err := req.Session.Decrypt(req.Header, req.Ciphertext)
	if err != nil {
		return nil, err
	}
	return sessionDecryptResponse{Session: req.Session, Plaintext: plaintext}, nil
}

// --- Wire envelope ----------------------------------------------------------

type buildEnvelopeRequest struct {
	Initial    *ratchet.InitialMessage `json:"initial,omitempty"`
	Header     ratchet.Header          `json:"header"`
	Ciphertext []byte                  `json:"ciphertext"`
}

type buildEnvelopeResponse struct {
	Payload json.RawMessage `json:"payload"`
}

// doBuildEnvelope assembles a message's opaque wire payload (§6 of
// docs/PROTOCOL.md): the Double Ratchet header, ciphertext, and (only for
// a session's first message) the X3DH InitialMessage fields.
func doBuildEnvelope(req buildEnvelopeRequest) (any, error) {
	payload, err := wire.NewEnvelope(req.Initial, req.Header, req.Ciphertext).MarshalPayload()
	if err != nil {
		return nil, err
	}
	return buildEnvelopeResponse{Payload: payload}, nil
}

type parseEnvelopeRequest struct {
	Payload json.RawMessage `json:"payload"`
}

type parseEnvelopeResponse struct {
	Initial    *ratchet.InitialMessage `json:"initial,omitempty"`
	Header     ratchet.Header          `json:"header"`
	Ciphertext []byte                  `json:"ciphertext"`
}

// doParseEnvelope decodes a message's opaque wire payload back into its
// header, ciphertext, and (if present) X3DH InitialMessage fields.
func doParseEnvelope(req parseEnvelopeRequest) (any, error) {
	env, err := wire.ParseEnvelope(req.Payload)
	if err != nil {
		return nil, err
	}
	header, err := env.Header.ToHeader()
	if err != nil {
		return nil, err
	}
	ciphertext, err := env.DecodeCiphertext()
	if err != nil {
		return nil, err
	}
	var initial *ratchet.InitialMessage
	if env.Prekey != nil {
		initial, err = env.Prekey.ToInitialMessage()
		if err != nil {
			return nil, err
		}
	}
	return parseEnvelopeResponse{Initial: initial, Header: header, Ciphertext: ciphertext}, nil
}

// --- HTTP request signing --------------------------------------------------

type signHTTPRequestRequest struct {
	Method     string             `json:"method"`
	Path       string             `json:"path"`
	RawQuery   string             `json:"raw_query,omitempty"`
	Body       []byte             `json:"body,omitempty"`
	DeviceID   string             `json:"device_id"`
	DevicePriv ed25519.PrivateKey `json:"device_priv"`
}

type signHTTPRequestResponse struct {
	Headers map[string]string `json:"headers"`
}

// doSignHTTPRequest signs a request per docs/PROTOCOL.md's per-request
// signature scheme (mirrors cmd/devclient's signedRequest), generating a
// fresh timestamp and nonce and returning the four headers the caller must
// attach to the outgoing HTTP request.
func doSignHTTPRequest(req signHTTPRequestRequest) (any, error) {
	nonceRaw := make([]byte, 16)
	if _, err := rand.Read(nonceRaw); err != nil {
		return nil, fmt.Errorf("generating nonce: %w", err)
	}
	nonce := hex.EncodeToString(nonceRaw)

	ts := time.Now()
	sig := httpsig.Sign(req.Method, req.Path, req.RawQuery, req.Body, req.DeviceID, ts, nonce, req.DevicePriv)

	return signHTTPRequestResponse{Headers: map[string]string{
		httpsig.HeaderKeyID:     req.DeviceID,
		httpsig.HeaderTimestamp: httpsig.FormatTimestamp(ts),
		httpsig.HeaderNonce:     nonce,
		httpsig.HeaderSignature: sig,
	}}, nil
}
