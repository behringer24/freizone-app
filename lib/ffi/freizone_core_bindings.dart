// Low-level dart:ffi bindings for native/'s cgo-exported functions. Every
// request/response-shaped function follows the same C signature (a JSON
// C string in, a JSON C string out); FreizoneCore (freizone_core.dart)
// wraps these in an idiomatic, typed Dart API and owns the JSON envelope
// and memory-freeing contract.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _NoArgNative = Pointer<Utf8> Function();
typedef NoArgFn = Pointer<Utf8> Function();

typedef _WithReqNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef WithReqFn = Pointer<Utf8> Function(Pointer<Utf8>);

typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef FreeFn = void Function(Pointer<Utf8>);

/// Loads libfreizonecore.so and exposes its exported functions as plain
/// Dart function values.
class FreizoneCoreBindings {
  FreizoneCoreBindings._(DynamicLibrary lib)
    : free = _lookupFree(lib, 'FreizoneFree'),
      version = _lookupNoArg(lib, 'FreizoneVersion'),
      generateIdentity = _lookupNoArg(lib, 'GenerateIdentity'),
      verifyAddressId = _lookupWithReq(lib, 'VerifyAddressID'),
      signDeviceCertificate = _lookupWithReq(lib, 'SignDeviceCertificate'),
      verifyDeviceCertificate = _lookupWithReq(lib, 'VerifyDeviceCertificate'),
      generateX25519KeyPair = _lookupNoArg(lib, 'GenerateX25519KeyPair'),
      signDHIdentityCertificate = _lookupWithReq(
        lib,
        'SignDHIdentityCertificate',
      ),
      verifyDHIdentityCertificate = _lookupWithReq(
        lib,
        'VerifyDHIdentityCertificate',
      ),
      signSignedPrekeyCertificate = _lookupWithReq(
        lib,
        'SignSignedPrekeyCertificate',
      ),
      verifySignedPrekeyCertificate = _lookupWithReq(
        lib,
        'VerifySignedPrekeyCertificate',
      ),
      initiateSession = _lookupWithReq(lib, 'InitiateSession'),
      respondToSession = _lookupWithReq(lib, 'RespondToSession'),
      sessionEncrypt = _lookupWithReq(lib, 'SessionEncrypt'),
      sessionDecrypt = _lookupWithReq(lib, 'SessionDecrypt'),
      buildEnvelope = _lookupWithReq(lib, 'BuildEnvelope'),
      parseEnvelope = _lookupWithReq(lib, 'ParseEnvelope'),
      signHTTPRequest = _lookupWithReq(lib, 'SignHTTPRequest'),
      revealRecoveryPhrase = _lookupWithReq(lib, 'RevealRecoveryPhrase'),
      restoreIdentityFromSeed = _lookupWithReq(lib, 'RestoreIdentityFromSeed'),
      recoveryWordlist = _lookupNoArg(lib, 'RecoveryWordlist'),
      encryptBlob = _lookupWithReq(lib, 'EncryptBlob'),
      decryptBlob = _lookupWithReq(lib, 'DecryptBlob'),
      verifyAttestation = _lookupWithReq(lib, 'VerifyAttestation'),
      groupCreate = _lookupWithReq(lib, 'GroupCreate'),
      groupSignEvent = _lookupWithReq(lib, 'GroupSignEvent'),
      groupApplyEvents = _lookupWithReq(lib, 'GroupApplyEvents'),
      groupResolveState = _lookupWithReq(lib, 'GroupResolveState'),
      coreOpen = _lookupWithReq(lib, 'CoreOpen'),
      coreClose = _lookupWithReq(lib, 'CoreClose'),
      coreSetIdentity = _lookupWithReq(lib, 'CoreSetIdentity'),
      coreStreamStart = _lookupWithReq(lib, 'CoreStreamStart'),
      coreStreamStop = _lookupWithReq(lib, 'CoreStreamStop'),
      corePoll = _lookupWithReq(lib, 'CorePoll'),
      coreChats = _lookupWithReq(lib, 'CoreChats'),
      coreMessages = _lookupWithReq(lib, 'CoreMessages'),
      coreSend = _lookupWithReq(lib, 'CoreSend'),
      coreRetryMessage = _lookupWithReq(lib, 'CoreRetryMessage'),
      coreSetOpenChat = _lookupWithReq(lib, 'CoreSetOpenChat'),
      coreMarkRead = _lookupWithReq(lib, 'CoreMarkRead'),
      coreStartConversation = _lookupWithReq(lib, 'CoreStartConversation'),
      coreBlockPeer = _lookupWithReq(lib, 'CoreBlockPeer'),
      coreUnblockPeer = _lookupWithReq(lib, 'CoreUnblockPeer'),
      coreAcceptRequest = _lookupWithReq(lib, 'CoreAcceptRequest'),
      coreClearChat = _lookupWithReq(lib, 'CoreClearChat'),
      coreDeleteChat = _lookupWithReq(lib, 'CoreDeleteChat'),
      coreDeleteMessage = _lookupWithReq(lib, 'CoreDeleteMessage'),
      corePinMessage = _lookupWithReq(lib, 'CorePinMessage'),
      coreUnpinMessage = _lookupWithReq(lib, 'CoreUnpinMessage'),
      coreAttachmentPath = _lookupWithReq(lib, 'CoreAttachmentPath'),
      coreGroupCreate = _lookupWithReq(lib, 'CoreGroupCreate'),
      coreGroupInvite = _lookupWithReq(lib, 'CoreGroupInvite'),
      coreGroupAccept = _lookupWithReq(lib, 'CoreGroupAccept'),
      coreGroupSetRole = _lookupWithReq(lib, 'CoreGroupSetRole'),
      coreGroupRemove = _lookupWithReq(lib, 'CoreGroupRemove'),
      coreGroupLeave = _lookupWithReq(lib, 'CoreGroupLeave'),
      coreGroupSetMeta = _lookupWithReq(lib, 'CoreGroupSetMeta'),
      coreGroupSyncRequest = _lookupWithReq(lib, 'CoreGroupSyncRequest'),
      coreForgetPeer = _lookupWithReq(lib, 'CoreForgetPeer'),
      coreSetReceiptsEnabled = _lookupWithReq(lib, 'CoreSetReceiptsEnabled'),
      coreGroupDissolve = _lookupWithReq(lib, 'CoreGroupDissolve'),
      coreGroupInfo = _lookupWithReq(lib, 'CoreGroupInfo'),
      coreMaintain = _lookupWithReq(lib, 'CoreMaintain'),
      coreResetSession = _lookupWithReq(lib, 'CoreResetSession'),
      coreSync = _lookupWithReq(lib, 'CoreSync');

  /// [path] is a host-test escape hatch and nothing else: a `flutter test`
  /// process has no core linked into it, so [DynamicLibrary.process] finds
  /// nothing and any test touching lib/state/ would fail to load. A host test
  /// points this at what `native/build_desktop.ps1` produced.
  ///
  /// Production callers pass nothing and the platform decides: Android opens
  /// the .so packaged into jniLibs, Apple platforms link the core into the app
  /// binary itself, so its symbols are already in the process.
  factory FreizoneCoreBindings.open({String? path}) {
    if (path != null) {
      return FreizoneCoreBindings._(DynamicLibrary.open(path));
    }
    final lib = Platform.isAndroid
        ? DynamicLibrary.open('libfreizonecore.so')
        : DynamicLibrary.process();
    return FreizoneCoreBindings._(lib);
  }

  static FreeFn _lookupFree(DynamicLibrary lib, String name) =>
      lib.lookup<NativeFunction<_FreeNative>>(name).asFunction();
  static NoArgFn _lookupNoArg(DynamicLibrary lib, String name) =>
      lib.lookup<NativeFunction<_NoArgNative>>(name).asFunction();
  static WithReqFn _lookupWithReq(DynamicLibrary lib, String name) =>
      lib.lookup<NativeFunction<_WithReqNative>>(name).asFunction();

  final FreeFn free;
  final NoArgFn version;
  final NoArgFn generateIdentity;
  final WithReqFn verifyAddressId;
  final WithReqFn signDeviceCertificate;
  final WithReqFn verifyDeviceCertificate;
  final NoArgFn generateX25519KeyPair;
  final WithReqFn signDHIdentityCertificate;
  final WithReqFn verifyDHIdentityCertificate;
  final WithReqFn signSignedPrekeyCertificate;
  final WithReqFn verifySignedPrekeyCertificate;
  final WithReqFn initiateSession;
  final WithReqFn respondToSession;
  final WithReqFn sessionEncrypt;
  final WithReqFn sessionDecrypt;
  final WithReqFn buildEnvelope;
  final WithReqFn parseEnvelope;
  final WithReqFn signHTTPRequest;
  final WithReqFn revealRecoveryPhrase;
  final WithReqFn restoreIdentityFromSeed;
  final NoArgFn recoveryWordlist;
  final WithReqFn encryptBlob;
  final WithReqFn decryptBlob;
  final WithReqFn verifyAttestation;
  final WithReqFn groupCreate;
  final WithReqFn groupSignEvent;
  final WithReqFn groupApplyEvents;
  final WithReqFn groupResolveState;

  /// The shared client core (SRV-23). Unlike everything above these are
  /// stateful: [coreOpen] returns a handle standing in for an open account
  /// database and the rest operate on it until [coreClose].
  final WithReqFn coreOpen;
  final WithReqFn coreClose;
  final WithReqFn coreSetIdentity;
  final WithReqFn coreStreamStart;
  final WithReqFn coreStreamStop;

  /// Blocks until the stream has something to report or the timeout expires.
  /// **Must be called from an isolate** -- on the UI thread it freezes the app
  /// for the whole wait.
  final WithReqFn corePoll;

  /// The account API (SRV-23 stage 6).
  ///
  /// Split by what each one costs, because the split decides where Dart may
  /// call it from. A read is local file work and answers immediately; anything
  /// that touches the network blocks for as long as the network takes, and on
  /// the UI thread that is a frozen app.

  /// Local. Safe to call while drawing.
  final WithReqFn coreChats;
  final WithReqFn coreMessages;
  final WithReqFn coreSetOpenChat;
  final WithReqFn coreBlockPeer;
  final WithReqFn coreUnblockPeer;
  final WithReqFn coreAcceptRequest;
  final WithReqFn coreClearChat;
  final WithReqFn coreDeleteChat;
  final WithReqFn coreDeleteMessage;
  final WithReqFn corePinMessage;
  final WithReqFn coreUnpinMessage;
  final WithReqFn coreGroupInfo;

  /// Network. Isolate only.
  final WithReqFn coreSend;
  final WithReqFn coreRetryMessage;
  final WithReqFn coreMarkRead;
  final WithReqFn coreStartConversation;
  final WithReqFn coreAttachmentPath;
  final WithReqFn coreMaintain;
  final WithReqFn coreResetSession;

  /// Drains this device's queued messages the same way the live poll loop
  /// handles a stream message -- for a caller with no stream open at all, the
  /// background push wake. Isolate only.
  final WithReqFn coreSync;

  /// Group actions. Every one of these tells the other members, so every one
  /// of them sends: isolate only, without exception.
  final WithReqFn coreGroupCreate;
  final WithReqFn coreGroupInvite;
  final WithReqFn coreGroupAccept;
  final WithReqFn coreGroupSetRole;
  final WithReqFn coreGroupRemove;
  final WithReqFn coreGroupLeave;
  final WithReqFn coreGroupSetMeta;
  final WithReqFn coreGroupSyncRequest;
  final WithReqFn coreForgetPeer;
  final WithReqFn coreSetReceiptsEnabled;
  final WithReqFn coreGroupDissolve;
}
