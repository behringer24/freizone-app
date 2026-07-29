package main

import (
	"bytes"
	"testing"
)

func encryptForTest(t *testing.T, plaintext []byte) encryptBlobResponse {
	t.Helper()
	resp, err := doEncryptBlob(encryptBlobRequest{Plaintext: plaintext})
	if err != nil {
		t.Fatalf("doEncryptBlob() error = %v", err)
	}
	out, ok := resp.(encryptBlobResponse)
	if !ok {
		t.Fatalf("doEncryptBlob() returned %T, want encryptBlobResponse", resp)
	}
	return out
}

func TestBlobEncryptDecryptRoundTrip(t *testing.T) {
	plaintext := bytes.Repeat([]byte("pretend this is a JPEG "), 500)
	enc := encryptForTest(t, plaintext)

	if len(enc.Key) != 32 {
		t.Errorf("key length = %d, want 32", len(enc.Key))
	}
	if bytes.Contains(enc.Ciphertext, plaintext) {
		t.Error("ciphertext contains the plaintext verbatim")
	}

	dec, err := doDecryptBlob(decryptBlobRequest{Key: enc.Key, Ciphertext: enc.Ciphertext})
	if err != nil {
		t.Fatalf("doDecryptBlob() error = %v", err)
	}
	got := dec.(decryptBlobResponse).Plaintext
	if !bytes.Equal(got, plaintext) {
		t.Error("round-tripped plaintext differs from the original")
	}
}

func TestBlobKeyIsFreshEveryTime(t *testing.T) {
	// A per-blob key is what lets a recipient re-download an attachment
	// after a secure-session reset -- it must not be derived from anything
	// shared or reused between blobs.
	plaintext := []byte("same bytes")
	first := encryptForTest(t, plaintext)
	second := encryptForTest(t, plaintext)

	if bytes.Equal(first.Key, second.Key) {
		t.Error("two encryptions produced the same key")
	}
	if bytes.Equal(first.Ciphertext, second.Ciphertext) {
		t.Error("identical plaintext produced identical ciphertext -- nonce is not fresh")
	}
}

func TestBlobDecryptRejectsWrongKey(t *testing.T) {
	enc := encryptForTest(t, []byte("secret picture"))
	other := encryptForTest(t, []byte("unrelated"))

	if _, err := doDecryptBlob(decryptBlobRequest{Key: other.Key, Ciphertext: enc.Ciphertext}); err == nil {
		t.Error("expected decryption with the wrong key to fail")
	}
}

func TestBlobDecryptRejectsTamperedCiphertext(t *testing.T) {
	enc := encryptForTest(t, []byte("secret picture"))
	tampered := make([]byte, len(enc.Ciphertext))
	copy(tampered, enc.Ciphertext)
	tampered[len(tampered)-1] ^= 0xff

	// Authenticated encryption: a modified blob must be rejected outright,
	// not silently decrypted into corrupt image bytes.
	if _, err := doDecryptBlob(decryptBlobRequest{Key: enc.Key, Ciphertext: tampered}); err == nil {
		t.Error("expected decryption of tampered ciphertext to fail")
	}
}

func TestBlobDecryptRejectsTruncatedAndMalformedInput(t *testing.T) {
	enc := encryptForTest(t, []byte("secret picture"))

	for name, ciphertext := range map[string][]byte{
		"empty":           {},
		"shorter than nonce": enc.Ciphertext[:5],
		"nonce only":      enc.Ciphertext[:12],
	} {
		if _, err := doDecryptBlob(decryptBlobRequest{Key: enc.Key, Ciphertext: ciphertext}); err == nil {
			t.Errorf("expected %s ciphertext to be rejected", name)
		}
	}
}

func TestBlobDecryptRejectsWrongKeyLength(t *testing.T) {
	enc := encryptForTest(t, []byte("x"))
	for _, n := range []int{0, 16, 31, 33} {
		if _, err := doDecryptBlob(decryptBlobRequest{Key: make([]byte, n), Ciphertext: enc.Ciphertext}); err == nil {
			t.Errorf("expected a %d-byte key to be rejected", n)
		}
	}
}

func TestBlobHandlesEmptyPlaintext(t *testing.T) {
	enc := encryptForTest(t, []byte{})
	dec, err := doDecryptBlob(decryptBlobRequest{Key: enc.Key, Ciphertext: enc.Ciphertext})
	if err != nil {
		t.Fatalf("doDecryptBlob() error = %v", err)
	}
	if len(dec.(decryptBlobResponse).Plaintext) != 0 {
		t.Error("expected empty plaintext back")
	}
}
