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
		env = resultEnvelope{OK: false, Error: err.Error(), Code: errorCode(err)}
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

//export RevealRecoveryPhrase
func RevealRecoveryPhrase(cReq *C.char) *C.char {
	return jsonCall(cReq, doRevealRecoveryPhrase)
}

//export RestoreIdentityFromSeed
func RestoreIdentityFromSeed(cReq *C.char) *C.char {
	return jsonCall(cReq, doRestoreIdentityFromSeed)
}

//export RecoveryWordlist
func RecoveryWordlist() *C.char {
	resp, err := doRecoveryWordlist()
	return toCResult(resp, err)
}

//export EncryptBlob
func EncryptBlob(cReq *C.char) *C.char {
	return jsonCall(cReq, doEncryptBlob)
}

//export DecryptBlob
func DecryptBlob(cReq *C.char) *C.char {
	return jsonCall(cReq, doDecryptBlob)
}

//export VerifyAttestation
func VerifyAttestation(cReq *C.char) *C.char {
	return jsonCall(cReq, doVerifyAttestation)
}

// Shared client core (SRV-23). Unlike everything above, these are stateful:
// CoreOpen returns a handle standing in for an open account database, and the
// rest operate on it until CoreClose. The state and the decisions live in
// freizone-server's pkg/client; client.go here is only the adapter that turns
// its channels and contexts into something that can cross cgo.

//export CoreOpen
func CoreOpen(cReq *C.char) *C.char {
	return jsonCall(cReq, doCoreOpen)
}

//export CoreClose
func CoreClose(cReq *C.char) *C.char {
	return jsonCall(cReq, doCoreClose)
}

//export CoreSetIdentity
func CoreSetIdentity(cReq *C.char) *C.char {
	return jsonCall(cReq, doCoreSetIdentity)
}

//export CoreStreamStart
func CoreStreamStart(cReq *C.char) *C.char {
	return jsonCall(cReq, doCoreStreamStart)
}

//export CoreStreamStop
func CoreStreamStop(cReq *C.char) *C.char {
	return jsonCall(cReq, doCoreStreamStop)
}

// CorePoll blocks for up to the requested timeout. Dart must call it from an
// isolate -- on the UI thread it would freeze the app for the whole wait.
//
//export CorePoll
func CorePoll(cReq *C.char) *C.char {
	return jsonCall(cReq, doCorePoll)
}

// Groups (SRV-01 / APP-16). The state blob these pass back and forth is
// opaque to the caller -- see group.go for why that matters.

//export GroupCreate
func GroupCreate(cReq *C.char) *C.char {
	return jsonCall(cReq, doGroupCreate)
}

//export GroupSignEvent
func GroupSignEvent(cReq *C.char) *C.char {
	return jsonCall(cReq, doGroupSignEvent)
}

//export GroupApplyEvents
func GroupApplyEvents(cReq *C.char) *C.char {
	return jsonCall(cReq, doGroupApplyEvents)
}

//export GroupResolveState
func GroupResolveState(cReq *C.char) *C.char {
	return jsonCall(cReq, doGroupResolveState)
}

func main() {}

// The account API (SRV-23 stage 6). Everything a screen asks for, in the shape
// it asks for it -- see api.go for why this is coarser than the library it
// wraps, and why attachment bytes travel as paths rather than through here.

//export CoreChats
func CoreChats(cReq *C.char) *C.char { return jsonCall(cReq, doCoreChats) }

//export CoreMessages
func CoreMessages(cReq *C.char) *C.char { return jsonCall(cReq, doCoreMessages) }

// CoreSend touches the network. Dart must call it from an isolate.
//
//export CoreSend
func CoreSend(cReq *C.char) *C.char { return jsonCall(cReq, doCoreSend) }

//export CoreRetryMessage
func CoreRetryMessage(cReq *C.char) *C.char { return jsonCall(cReq, doCoreRetry) }

//export CoreSetOpenChat
func CoreSetOpenChat(cReq *C.char) *C.char { return jsonCall(cReq, doCoreSetOpenChat) }

//export CoreMarkRead
func CoreMarkRead(cReq *C.char) *C.char { return jsonCall(cReq, doCoreMarkRead) }

//export CoreStartConversation
func CoreStartConversation(cReq *C.char) *C.char { return jsonCall(cReq, doCoreStartConversation) }

//export CoreBlockPeer
func CoreBlockPeer(cReq *C.char) *C.char { return jsonCall(cReq, doCoreBlockPeer) }

//export CoreUnblockPeer
func CoreUnblockPeer(cReq *C.char) *C.char { return jsonCall(cReq, doCoreUnblockPeer) }

//export CoreAcceptRequest
func CoreAcceptRequest(cReq *C.char) *C.char { return jsonCall(cReq, doCoreAcceptRequest) }

//export CoreDeleteChat
func CoreDeleteChat(cReq *C.char) *C.char { return jsonCall(cReq, doCoreDeleteChat) }

// CoreAttachmentPath downloads on demand, so it blocks and belongs in an
// isolate. It returns where the file is, never the bytes.
//
//export CoreAttachmentPath
func CoreAttachmentPath(cReq *C.char) *C.char { return jsonCall(cReq, doCoreAttachmentPath) }

//export CoreGroupCreate
func CoreGroupCreate(cReq *C.char) *C.char { return jsonCall(cReq, doCoreGroupCreate) }

//export CoreGroupInvite
func CoreGroupInvite(cReq *C.char) *C.char { return jsonCall(cReq, doCoreGroupInvite) }

//export CoreGroupAccept
func CoreGroupAccept(cReq *C.char) *C.char { return jsonCall(cReq, doCoreGroupAccept) }

//export CoreGroupSetRole
func CoreGroupSetRole(cReq *C.char) *C.char { return jsonCall(cReq, doCoreGroupSetRole) }

//export CoreGroupRemove
func CoreGroupRemove(cReq *C.char) *C.char { return jsonCall(cReq, doCoreGroupRemove) }

//export CoreGroupLeave
func CoreGroupLeave(cReq *C.char) *C.char { return jsonCall(cReq, doCoreGroupLeave) }

//export CoreGroupSetMeta
func CoreGroupSetMeta(cReq *C.char) *C.char { return jsonCall(cReq, doCoreGroupSetMeta) }

//export CoreGroupSyncRequest
func CoreGroupSyncRequest(cReq *C.char) *C.char { return jsonCall(cReq, doCoreGroupSyncRequest) }

//export CoreForgetPeer
func CoreForgetPeer(cReq *C.char) *C.char { return jsonCall(cReq, doCoreForgetPeer) }

//export CoreGroupDissolve
func CoreGroupDissolve(cReq *C.char) *C.char { return jsonCall(cReq, doCoreGroupDissolve) }

//export CoreGroupInfo
func CoreGroupInfo(cReq *C.char) *C.char { return jsonCall(cReq, doCoreGroupInfo) }

// CoreMaintain is the housekeeping a fresh connection should do: top up the
// prekey pool, settle group facts owed, re-establish broken sessions. Blocking.
//
//export CoreMaintain
func CoreMaintain(cReq *C.char) *C.char { return jsonCall(cReq, doCoreMaintain) }

//export CoreResetSession
func CoreResetSession(cReq *C.char) *C.char { return jsonCall(cReq, doCoreResetSession) }

// CoreSync drains this device's queued messages the same way the live poll
// loop handles a stream message, for a caller with no stream open at all --
// the background push wake (see push_manager.dart). Blocking.
//
//export CoreSync
func CoreSync(cReq *C.char) *C.char { return jsonCall(cReq, doCoreSync) }
