package main

// All actual request/response types and logic live here, deliberately
// free of cgo ("C" types) so this file (and its tests) can be built and
// run on the host -- only core.go's thin //export wrappers need cgo and
// the Android NDK toolchain. Go's test tooling doesn't support cgo in
// _test.go files for cross-compiled test binaries, so keeping the cgo
// surface minimal and separate is what makes this package testable at
// all without a connected device.

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/behringer24/freizone-server/pkg/address"
	"github.com/behringer24/freizone-server/pkg/attest"
	"github.com/behringer24/freizone-server/pkg/client"
	"github.com/behringer24/freizone-server/pkg/devicecert"
	"github.com/behringer24/freizone-server/pkg/httpsig"
	"github.com/behringer24/freizone-server/pkg/mnemonic"
	"github.com/behringer24/freizone-server/pkg/ratchet"
	"github.com/behringer24/freizone-server/pkg/wire"
)

// resultEnvelope is the shared JSON shape every exported function returns:
// either {"ok":true,"data":...} or {"ok":false,"error":"...","code":"..."}.
type resultEnvelope struct {
	OK    bool            `json:"ok"`
	Data  json.RawMessage `json:"data,omitempty"`
	Error string          `json:"error,omitempty"`

	// Code is a stable machine-readable classification of Error, present only
	// for failures a caller is expected to *act* on differently rather than
	// just report -- today the ratchet.Failure* decrypt codes, which are how
	// the Dart side tells a harmless redelivery apart from the desync that
	// should trigger session recovery. Absent means "no specific diagnosis",
	// which must never be read as harmless. An error value cannot cross cgo,
	// so this string is the only channel for the distinction.
	Code string `json:"code,omitempty"`
}

// codedError attaches a resultEnvelope.Code to an error. Produced by the
// handlers that have something meaningful to classify (doSessionDecrypt) and
// unwrapped by toCResult (core.go); everything else keeps returning plain
// errors and simply carries no code.
type codedError struct {
	code string
	err  error
}

func (e codedError) Error() string { return e.err.Error() }
func (e codedError) Unwrap() error { return e.err }
func (e codedError) Code() string  { return e.code }

// errorCode extracts the resultEnvelope.Code for err, or "" if it carries
// none. Matched by interface rather than concrete type so a future error type
// can opt in the same way, and via errors.As so a code survives being wrapped
// by a caller adding context. Lives here rather than in core.go's toCResult so
// it stays testable without the cgo toolchain.
func errorCode(err error) string {
	var coded interface{ Code() string }
	if errors.As(err, &coded) {
		return coded.Code()
	}
	// Derived rather than attached: every call in this file can fail because
	// the server is simply not there, so marking each one by hand would mean
	// marking all of them and missing the next. The shell needs to tell that
	// apart from a server that answered and refused -- it keeps quiet for one
	// and interrupts for the other -- and error text is not a contract it can
	// match on.
	if client.IsUnreachable(err) {
		return codeServerUnreachable
	}
	return ""
}

// codeServerUnreachable is the one classification this layer derives itself.
// KEEP IN STEP with CoreErrorCode.serverUnreachable in
// lib/ffi/freizone_core_exception.dart.
const codeServerUnreachable = "server_unreachable"

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
//
// A failure is returned with its ratchet.FailureCode attached (see
// codedError): the Dart receive path has to distinguish a redelivery it should
// silently drop from the authentication failure that means this conversation's
// ratchet has desynced and needs re-establishing, and error text is not a
// contract it can match on.
func doSessionDecrypt(req sessionDecryptRequest) (any, error) {
	if req.Session == nil {
		return nil, errors.New("session is required")
	}
	plaintext, err := req.Session.Decrypt(req.Header, req.Ciphertext)
	if err != nil {
		if code := ratchet.FailureCode(err); code != "" {
			return nil, codedError{code: code, err: err}
		}
		return nil, err
	}
	return sessionDecryptResponse{Session: req.Session, Plaintext: plaintext}, nil
}

// --- Wire envelope ----------------------------------------------------------

type buildEnvelopeRequest struct {
	Initial    *ratchet.InitialMessage `json:"initial,omitempty"`
	Header     ratchet.Header          `json:"header"`
	Ciphertext []byte                  `json:"ciphertext"`

	// Rekey states why a prekey block is attached (SRV-17): true for a
	// deliberate re-key, false for an ordinary establishment, absent to say
	// nothing. Absent is what a caller predating the field sends, and it costs
	// the receiver the content-sniffing fallback -- so a caller that knows
	// should always state it. See wire.PrekeyFields.Rekey.
	Rekey *bool `json:"rekey,omitempty"`
}

type buildEnvelopeResponse struct {
	Payload json.RawMessage `json:"payload"`
}

// doBuildEnvelope assembles a message's opaque wire payload (§6 of
// docs/PROTOCOL.md): the Double Ratchet header, ciphertext, and (only for
// a session's first message) the X3DH InitialMessage fields.
func doBuildEnvelope(req buildEnvelopeRequest) (any, error) {
	payload, err := wire.NewEnvelopeRekey(req.Initial, req.Header, req.Ciphertext, req.Rekey).MarshalPayload()
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

	// Rekey is what the sender said about their prekey block, passed through
	// verbatim including "said nothing" (absent), which the caller must handle
	// rather than read as false -- see wire.PrekeyFields.Rekey. Absent whenever
	// there is no prekey block at all.
	Rekey *bool `json:"rekey,omitempty"`
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
	var rekey *bool
	if env.Prekey != nil {
		initial, err = env.Prekey.ToInitialMessage()
		if err != nil {
			return nil, err
		}
		rekey = env.Prekey.Rekey
	}
	return parseEnvelopeResponse{
		Initial:    initial,
		Header:     header,
		Ciphertext: ciphertext,
		Rekey:      rekey,
	}, nil
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

// --- Recovery seed phrase (APP-01) -----------------------------------------

type revealRecoveryPhraseRequest struct {
	RootPriv ed25519.PrivateKey `json:"root_priv"`
}

type recoveryPhraseResponse struct {
	Words []string `json:"words"`
}

// doRevealRecoveryPhrase turns the account's Ed25519 root private key into its
// 24-word BIP-39 backup phrase. The phrase encodes only the 32-byte key seed
// (an Ed25519 private key is seed||pub), which is all that is needed to rebuild
// the identity -- account_id == hash(root_pubkey), so the same seed restores
// the same account id and short id.
func doRevealRecoveryPhrase(req revealRecoveryPhraseRequest) (any, error) {
	if len(req.RootPriv) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("root_priv must be %d bytes, got %d", ed25519.PrivateKeySize, len(req.RootPriv))
	}
	words, err := mnemonic.Encode(req.RootPriv.Seed())
	if err != nil {
		return nil, err
	}
	return recoveryPhraseResponse{Words: words}, nil
}

type restoreIdentityFromSeedRequest struct {
	Words []string `json:"words"`
}

// doRestoreIdentityFromSeed rebuilds an identity from a 24-word recovery
// phrase: it restores the exact same root key (and therefore the same account
// id) and mints a *fresh* device keypair, since the phrase carries the root
// key only. Returns the same shape as doGenerateIdentity so the caller's
// registration/recovery path is identical. A malformed phrase (unknown word or
// bad checksum) surfaces as a call error.
func doRestoreIdentityFromSeed(req restoreIdentityFromSeedRequest) (any, error) {
	seed, err := mnemonic.Decode(req.Words)
	if err != nil {
		return nil, err
	}
	rootPriv := ed25519.NewKeyFromSeed(seed)
	rootPub := rootPriv.Public().(ed25519.PublicKey)

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

type recoveryWordlistResponse struct {
	Words []string `json:"words"`
}

// doRecoveryWordlist returns the full BIP-39 English wordlist so the client can
// drive recovery-phrase autocomplete and per-word validation entirely offline.
func doRecoveryWordlist() (*recoveryWordlistResponse, error) {
	return &recoveryWordlistResponse{Words: mnemonic.Wordlist()}, nil
}

// --- Attachment blob encryption (APP-04 / SRV-07) ---------------------------

// Attachments are encrypted with a fresh random key per blob rather than
// with ratchet material: the blob outlives the message on the server, and a
// user who resets a secure session (SRV-03) must still be able to re-download
// pictures they already received. The key travels inside the message's own
// end-to-end encrypted payload, so the server storing the blob never sees it.
//
// AES-256-GCM with a random 96-bit nonce prefixed to the ciphertext. Kept in
// the shared Go core rather than done in Dart so all cryptography stays in
// one audited place.

type encryptBlobRequest struct {
	Plaintext []byte `json:"plaintext"`
}

type encryptBlobResponse struct {
	Key        []byte `json:"key"`
	Ciphertext []byte `json:"ciphertext"`
	// Digest is the hex SHA-256 of Ciphertext, for the upload's Blob-Digest
	// header (see docs/PROTOCOL.md §3's streamed-body variant). Returned
	// here because the core already holds the bytes -- the alternative
	// would be hashing a multi-megabyte buffer a second time in Dart.
	Digest string `json:"digest"`
}

// doEncryptBlob generates a fresh key and encrypts plaintext with it.
func doEncryptBlob(req encryptBlobRequest) (any, error) {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, fmt.Errorf("generating blob key: %w", err)
	}
	ciphertext, err := sealBlob(key, req.Plaintext)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(ciphertext)
	return encryptBlobResponse{
		Key:        key,
		Ciphertext: ciphertext,
		Digest:     hex.EncodeToString(sum[:]),
	}, nil
}

type decryptBlobRequest struct {
	Key        []byte `json:"key"`
	Ciphertext []byte `json:"ciphertext"`
}

type decryptBlobResponse struct {
	Plaintext []byte `json:"plaintext"`
}

// doDecryptBlob reverses doEncryptBlob. A wrong key, a truncated blob or any
// tampering surfaces as an authentication failure rather than garbage bytes.
func doDecryptBlob(req decryptBlobRequest) (any, error) {
	plaintext, err := openBlob(req.Key, req.Ciphertext)
	if err != nil {
		return nil, err
	}
	return decryptBlobResponse{Plaintext: plaintext}, nil
}

func sealBlob(key, plaintext []byte) ([]byte, error) {
	gcm, err := blobAEAD(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("generating blob nonce: %w", err)
	}
	// Nonce prefixed to the ciphertext: it isn't secret, and carrying it
	// inline keeps a blob a single self-contained byte string.
	return gcm.Seal(nonce, nonce, plaintext, nil), nil
}

func openBlob(key, ciphertext []byte) ([]byte, error) {
	gcm, err := blobAEAD(key)
	if err != nil {
		return nil, err
	}
	if len(ciphertext) < gcm.NonceSize() {
		return nil, fmt.Errorf("blob: ciphertext too short")
	}
	nonce, sealed := ciphertext[:gcm.NonceSize()], ciphertext[gcm.NonceSize():]
	plaintext, err := gcm.Open(nil, nonce, sealed, nil)
	if err != nil {
		return nil, fmt.Errorf("blob: decryption failed: %w", err)
	}
	return plaintext, nil
}

func blobAEAD(key []byte) (cipher.AEAD, error) {
	if len(key) != 32 {
		return nil, fmt.Errorf("blob: key must be 32 bytes, got %d", len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("blob: creating cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("blob: creating gcm: %w", err)
	}
	return gcm, nil
}

// --- Server attestation verification (SRV-19 / APP-22) ---------------------
//
// Verification lives here, in the shared core, rather than in Dart, for the
// same reason everything else touching a signature does: this client's
// notion of "genuine" must never drift from the server's own. See
// freizone-server's cmd/server checkAttestation, which runs the identical
// three steps -- Decode, Verify against attest.TrustedIssuers, Valid against
// a domain -- against the identical trusted-issuer set, since native/go.mod
// vendors that repo directly rather than reimplementing the format. See
// docs/design/22-verified-badge.md for where the result is shown.

type verifyAttestationRequest struct {
	// Token is the opaque string GET /v1/server-status returned verbatim
	// (ServerStatus.attestation in Dart) -- never interpreted there.
	Token string `json:"token"`
	// Domain is the server this token is being checked against: the peer's
	// home server for a federated contact, or this account's own. Checking
	// only the signature (attest.Verify) without this would let an
	// attestation genuinely issued for one server be replayed as if it were
	// about another.
	Domain string `json:"domain"`
}

type attestationResult struct {
	// Valid is false for anything that does not hold up: a malformed token,
	// an issuer key outside the trusted set, the wrong domain, or a lapsed
	// validity window. Callers branch on this alone -- the fields below are
	// meaningless when it is false, and a caller must never render them.
	Valid   bool   `json:"valid"`
	Tier    string `json:"tier,omitempty"`
	Subject string `json:"subject,omitempty"`
	// ExpiresAt is Unix seconds (UTC). Carried as a number rather than a
	// formatted string so Dart parses it with a plain int, not a second
	// date-format contract across the FFI boundary.
	ExpiresAt int64 `json:"expires_at,omitempty"`
}

// doVerifyAttestation decodes req.Token, checks its signature against
// attest.TrustedIssuers, then checks it actually applies to req.Domain right
// now. Every failure folds into Valid: false rather than a call error --
// exactly like verifyResult elsewhere in this file -- so the caller never
// has to tell "malformed" apart from "expired" apart from "wrong server";
// see docs/design/22-verified-badge.md on why absence must never be shown as
// a warning regardless of which of these it was.
func doVerifyAttestation(req verifyAttestationRequest) (any, error) {
	a, err := attest.Decode(req.Token)
	if err != nil {
		return attestationResult{Valid: false}, nil
	}
	if err := a.Verify(attest.TrustedIssuers); err != nil {
		return attestationResult{Valid: false}, nil
	}
	if err := a.Valid(req.Domain, time.Now()); err != nil {
		return attestationResult{Valid: false}, nil
	}
	return attestationResult{
		Valid:     true,
		Tier:      a.Tier,
		Subject:   a.Subject,
		ExpiresAt: a.ExpiresAt.Unix(),
	}, nil
}
