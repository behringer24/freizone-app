// Command native (built with -buildmode=c-shared, never run directly) is
// Freizone's shared crypto/protocol core: a thin cgo-exported wrapper
// around github.com/behringer24/freizone-server's pkg/{ratchet,devicecert,
// address,wire}, so the mobile app doesn't re-implement X3DH/Double Ratchet
// in Dart. Every function below takes/returns JSON-encoded C strings --
// see resultEnvelope (logic.go) for the shared response shape, and
// docs/PROTOCOL.md (in freizone-server) for the underlying wire formats.
// The actual request/response types and logic live in logic.go, kept free
// of cgo so it (and its tests) can build and run on the host -- this file
// is deliberately just the marshaling glue.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"unsafe"
)

// toCResult marshals data (or err) into a resultEnvelope and returns it as
// a newly-allocated C string. The caller must pass the result to
// FreizoneFree once done with it.
func toCResult(data any, err error) *C.char {
	var env resultEnvelope
	if err != nil {
		env = resultEnvelope{OK: false, Error: err.Error()}
	} else {
		raw, mErr := json.Marshal(data)
		if mErr != nil {
			env = resultEnvelope{OK: false, Error: fmt.Sprintf("marshaling response: %v", mErr)}
		} else {
			env = resultEnvelope{OK: true, Data: raw}
		}
	}
	out, err := json.Marshal(env)
	if err != nil {
		// json-marshaling resultEnvelope itself cannot realistically fail
		// (it's all strings/RawMessage), but never return a nil/invalid
		// C string no matter what.
		return C.CString(`{"ok":false,"error":"internal: marshaling result envelope failed"}`)
	}
	return C.CString(string(out))
}

// jsonCall decodes cReq's JSON into a Req, runs fn, and encodes the result
// via toCResult. Shared boilerplate for every request/response function
// below.
func jsonCall[Req any](cReq *C.char, fn func(Req) (any, error)) *C.char {
	var req Req
	if err := json.Unmarshal([]byte(C.GoString(cReq)), &req); err != nil {
		return toCResult(nil, fmt.Errorf("decoding request: %w", err))
	}
	data, err := fn(req)
	return toCResult(data, err)
}

// FreizoneVersion returns a static version string. Also useful later as a
// trivial "is the core loaded correctly" check (e.g. an about screen).
//
//export FreizoneVersion
func FreizoneVersion() *C.char {
	return C.CString("freizone-core v0.1.0")
}

// FreizoneFree releases a *C.char previously returned by this library.
// Every string-returning exported function's result must be passed here
// once the caller is done with it. (Request strings passed *into* the
// library are owned and freed by the caller, not by Go.)
//
//export FreizoneFree
func FreizoneFree(ptr *C.char) {
	C.free(unsafe.Pointer(ptr))
}

//export GenerateIdentity
func GenerateIdentity() *C.char {
	resp, err := doGenerateIdentity()
	return toCResult(resp, err)
}

//export VerifyAddressID
func VerifyAddressID(cReq *C.char) *C.char {
	return jsonCall(cReq, doVerifyAddressID)
}

//export SignDeviceCertificate
func SignDeviceCertificate(cReq *C.char) *C.char {
	return jsonCall(cReq, doSignDeviceCertificate)
}

//export VerifyDeviceCertificate
func VerifyDeviceCertificate(cReq *C.char) *C.char {
	return jsonCall(cReq, doVerifyDeviceCertificate)
}

//export GenerateX25519KeyPair
func GenerateX25519KeyPair() *C.char {
	resp, err := doGenerateX25519KeyPair()
	return toCResult(resp, err)
}

//export SignDHIdentityCertificate
func SignDHIdentityCertificate(cReq *C.char) *C.char {
	return jsonCall(cReq, doSignDHIdentityCertificate)
}

//export VerifyDHIdentityCertificate
func VerifyDHIdentityCertificate(cReq *C.char) *C.char {
	return jsonCall(cReq, doVerifyDHIdentityCertificate)
}

//export SignSignedPrekeyCertificate
func SignSignedPrekeyCertificate(cReq *C.char) *C.char {
	return jsonCall(cReq, doSignSignedPrekeyCertificate)
}

//export VerifySignedPrekeyCertificate
func VerifySignedPrekeyCertificate(cReq *C.char) *C.char {
	return jsonCall(cReq, doVerifySignedPrekeyCertificate)
}

//export InitiateSession
func InitiateSession(cReq *C.char) *C.char {
	return jsonCall(cReq, doInitiateSession)
}

//export RespondToSession
func RespondToSession(cReq *C.char) *C.char {
	return jsonCall(cReq, doRespondToSession)
}

//export SessionEncrypt
func SessionEncrypt(cReq *C.char) *C.char {
	return jsonCall(cReq, doSessionEncrypt)
}

//export SessionDecrypt
func SessionDecrypt(cReq *C.char) *C.char {
	return jsonCall(cReq, doSessionDecrypt)
}

//export BuildEnvelope
func BuildEnvelope(cReq *C.char) *C.char {
	return jsonCall(cReq, doBuildEnvelope)
}

//export ParseEnvelope
func ParseEnvelope(cReq *C.char) *C.char {
	return jsonCall(cReq, doParseEnvelope)
}

//export SignHTTPRequest
func SignHTTPRequest(cReq *C.char) *C.char {
	return jsonCall(cReq, doSignHTTPRequest)
}

func main() {}
