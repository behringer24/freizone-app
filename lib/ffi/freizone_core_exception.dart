/// Machine-readable classifications the native core can attach to a failure
/// (`resultEnvelope.code`, see native/logic.go). Only failures a caller is
/// expected to *act* on differently carry one -- today the ratchet's decrypt
/// codes, defined in freizone-server's pkg/ratchet/failure.go, which is the
/// authority for these strings. Anything else arrives with a null code.
class CoreErrorCode {
  const CoreErrorCode._();

  /// This exact envelope was already decrypted. Delivery is at-least-once, so
  /// this is routine, not a fault: drop the envelope, leave the session alone.
  static const duplicateMessage = 'duplicate_message';

  /// The AEAD tag didn't verify. On an established session this is the ratchet
  /// desync symptom -- see [suggestsDesync].
  static const authenticationFailed = 'authentication_failed';

  /// The sender's message number is too far ahead of our receiving chain to
  /// bridge.
  static const tooManySkipped = 'too_many_skipped';

  /// A message for a receiving chain that doesn't exist here yet.
  static const noReceivingChain = 'no_receiving_chain';

  /// The request never reached a working server: refused, timed out, no DNS,
  /// no route. Says nothing about the account or the request -- only that
  /// nothing was learned, so a later attempt may well say something else.
  ///
  /// The one code the core derives rather than being handed (native/logic.go's
  /// errorCode, from pkg/client.IsUnreachable), because any call at all can
  /// fail this way. Acted on in util/errors.dart: a server that is away is the
  /// most common failure there is, it retries itself, and the account is
  /// already dimmed with an offline badge -- so it must not also raise the red
  /// banner that is supposed to mean "look at this".
  static const serverUnreachable = 'server_unreachable';

  /// Whether [code] means the session with this peer is unlikely to ever
  /// decrypt again, so it should be re-established rather than retried
  /// (ratchet.SuggestsDesync). False for a duplicate (nothing is wrong) and
  /// for null (no diagnosis -- never discard a session on a hunch).
  ///
  /// A single occurrence isn't proof: a message can fail once because it raced
  /// a session change. Repetition is what makes it conclusive, since decrypting
  /// the same envelope against the same session is deterministic -- see
  /// AppState.recordDecryptFailure.
  static bool suggestsDesync(String? code) =>
      code == authenticationFailed ||
      code == tooManySkipped ||
      code == noReceivingChain;
}

/// Thrown when a native core call returns `{"ok": false, "error": "..."}`.
class FreizoneCoreException implements Exception {
  FreizoneCoreException(this.message, {this.code});

  final String message;

  /// A [CoreErrorCode] constant when the core classified this failure, null
  /// otherwise. Null is "undiagnosed", never "harmless".
  final String? code;

  /// Shorthand for [CoreErrorCode.suggestsDesync] on this failure's code.
  bool get suggestsDesync => CoreErrorCode.suggestsDesync(code);

  @override
  String toString() =>
      code == null
      ? 'FreizoneCoreException: $message'
      : 'FreizoneCoreException($code): $message';
}
