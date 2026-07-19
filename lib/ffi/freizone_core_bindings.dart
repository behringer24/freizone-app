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
      signHTTPRequest = _lookupWithReq(lib, 'SignHTTPRequest');

  factory FreizoneCoreBindings.open() {
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
}
