// The message stream, run by the shared Go core instead of by Dart (SRV-23).
//
// Replaces sse_client.dart, and deliberately keeps its shape: connect() with
// onMessage/onError/onConnected, and close(). AppSession's use of it is
// unchanged in spirit, which is the point -- the reconnection policy moved
// into freizone-server's pkg/client, not the app's idea of what a stream is.
//
// What the core now owns: opening the stream, the SSE line parsing, the two
// reconnect regimes (quick retry with the backoff reset after a stream that had
// come up and dropped, exponential backoff with jitter for one that never came
// up), bounding a connect attempt so a routed-but-dead host surfaces in
// seconds -- and, since the cut (docs/design/23-shared-client-core.md), the
// receive path itself: decrypting, folding a group envelope, acknowledging,
// receipting. All of that is tested there, in Go, against a real server --
// which is something the Dart version never had.
//
// What is left here: the isolate the blocking poll must run on, and the
// mapping from the core's events back onto the three callbacks. [onMessage]
// gets [PollOutcome] -- what the core decided -- never the envelope itself;
// there is nothing left here to decrypt.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import '../ffi/freizone_core.dart';
import '../ffi/freizone_core_exception.dart';
import '../util/log.dart';

/// What one blocking `CorePoll` returned.
class CorePollResult {
  const CorePollResult({required this.events, required this.streaming});

  factory CorePollResult.fromJson(Map<String, dynamic> j) => CorePollResult(
    events: ((j['events'] as List<dynamic>?) ?? const [])
        .map((e) => CoreStreamEvent.fromJson(e as Map<String, dynamic>))
        .toList(),
    streaming: j['streaming'] as bool? ?? false,
  );

  /// Empty when the poll timed out with nothing to report, which is the
  /// ordinary case for an idle account and must never read as an error.
  final List<CoreStreamEvent> events;

  /// False once the stream has stopped for good, so the poll loop ends instead
  /// of spinning against something that will never speak again.
  final bool streaming;
}

/// One thing that happened on the stream.
class CoreStreamEvent {
  const CoreStreamEvent({
    required this.kind,
    this.outcome,
    this.error,
    this.errorCode,
  });

  factory CoreStreamEvent.fromJson(Map<String, dynamic> j) => CoreStreamEvent(
    kind: j['kind'] as String? ?? 'unknown',
    outcome: j['outcome'] == null
        ? null
        : PollOutcome.fromJson(j['outcome'] as Map<String, dynamic>),
    error: j['error'] as String?,
    errorCode: j['code'] as String?,
  );

  /// "connected", "message", "disconnected" or "failed".
  ///
  /// A string rather than an index, deliberately: a core and an app build that
  /// disagree about the set then fail visibly on a name this build has never
  /// heard of, instead of silently reinterpreting a number as another event.
  final String kind;

  /// Present for "message".
  final PollOutcome? outcome;

  /// Present for "failed", and deliberately absent for "disconnected" even
  /// though the core knows why -- see [CoreStream.connect].
  final String? error;

  /// A [CoreErrorCode] when the core could classify that failure, null when it
  /// could not. What the caller decides with, since [error] is prose.
  final String? errorCode;
}

/// What one handled envelope turned into. The core has already decrypted it
/// (or folded it, if it was a group fact), acknowledged it, and sent back
/// whatever receipt it called for -- this is only what is left for the shell
/// to act on: somewhere to refresh, and sometimes someone to tell.
class PollOutcome {
  const PollOutcome({
    required this.chatId,
    required this.notify,
    required this.invitation,
    required this.isGroup,
    this.attachmentMessageId = '',
    this.failure = '',
    this.senderAccountId = '',
  });

  factory PollOutcome.fromJson(Map<String, dynamic> j) => PollOutcome(
    chatId: j['chat_id'] as String? ?? '',
    notify: j['notify'] as bool? ?? false,
    invitation: j['invitation'] as bool? ?? false,
    isGroup: j['is_group'] as bool? ?? false,
    attachmentMessageId: j['attachment_message_id'] as String? ?? '',
    failure: j['failure'] as String? ?? '',
    senderAccountId: j['sender_account_id'] as String? ?? '',
  );

  /// Which chat changed -- a peer account id or a group id, the one namespace
  /// both share. Empty for a duplicate or a failed attempt: nothing changed,
  /// so there is nothing to refresh.
  final String chatId;

  /// Whether this is worth interrupting the user for. False for the ordinary
  /// "something changed, redraw the chat" case -- a receipt, a non-invite
  /// group fact, a message into the chat already on screen.
  final bool notify;

  /// [notify] is true because this was an invitation into a group new to this
  /// account, not a message. Changes only the wording.
  final bool invitation;

  /// [chatId] names a group rather than a peer -- settled on the Go side
  /// (client.IsGroupID), not re-derived here, so a caller with no live
  /// AppState.groups to check against (the background wake, see
  /// push_manager.dart) still knows which kind of chat this is.
  final bool isGroup;

  /// The line this envelope stored, when it carried a picture -- empty
  /// otherwise. Lets a foreground session start the download as the message
  /// lands instead of when its bubble is first looked at.
  final String attachmentMessageId;

  /// Why this envelope was not handled, or empty when it was. Diagnostic
  /// only -- the core has already decided what to do about it (retry or
  /// acknowledge away) by the time this arrives.
  ///
  /// Worth carrying at all because a message that fails to decrypt is
  /// otherwise completely invisible from the app: no error anywhere, just a
  /// message that never appears. Three separate diagnoses in one afternoon
  /// began by rebuilding the native core with a temporary log statement, for
  /// want of exactly this string.
  final String failure;

  /// Who a failed envelope came from. [chatId] is deliberately empty for one,
  /// and an error text on its own does not say which conversation is broken.
  final String senderAccountId;

  /// Whether this is a failure rather than something that changed a chat.
  bool get failed => failure.isNotEmpty;
}

/// What one queue drain found: the same [PollOutcome]s a streamed envelope
/// produces, plus whatever housekeeping went wrong alongside them.
///
/// One type for both callers of the core's sync entry point -- the push wake
/// (push_manager.dart) and every stream (re)connect (CoreAccount.sync) --
/// because they are the same work on the same path, and a second shape for it
/// is how the two drifted apart before the cut.
class SyncReport {
  const SyncReport({this.outcomes = const [], this.problems = const []});

  factory SyncReport.fromJson(Map<String, dynamic> j) => SyncReport(
    outcomes: ((j['outcomes'] as List<dynamic>?) ?? const [])
        .map((o) => PollOutcome.fromJson(o as Map<String, dynamic>))
        .toList(),
    problems: ((j['problems'] as List<dynamic>?) ?? const []).cast<String>(),
  );

  /// Everything the drain handled. Empty is the ordinary case for a queue
  /// that had nothing in it, and must never read as a failure.
  final List<PollOutcome> outcomes;

  /// Best-effort housekeeping that did not work (see MaintenanceReport):
  /// reported rather than thrown, since one part failing must not stop the
  /// envelopes that were already fetched from being handled.
  final List<String> problems;
}

/// How long one poll waits before coming back empty-handed. Long, because an
/// idle account is the normal case and every return is an isolate spawn; short
/// enough that [close] is not left waiting on it for long.
const _pollTimeout = Duration(seconds: 20);

class CoreStream {
  /// [handle] is an already-open core handle -- its identity already set, its
  /// lifetime owned by whoever opened it (AppSession's own [CoreAccount]), not
  /// by this stream. That is deliberate: the same handle also serves sends and
  /// reads, so a stream that closed it from underneath them on every
  /// disconnect would be a much worse defect than the one this class fixes.
  CoreStream({required this.core, required this.handle});

  final FreizoneCore core;
  final int handle;

  bool _closed = false;

  /// Opens the stream and calls [onMessage] for every message, [onConnected]
  /// once per successful (re)connect, and [onError] for a connect attempt that
  /// never came up. Runs until [close].
  ///
  /// Note what does *not* reach [onError]: a stream that came up and then ended.
  /// That is a resume from background or a brief blip, the core is already
  /// reconnecting, and sse_client.dart did not report it either -- only a failed
  /// attempt did. Passing it on would light up the offline badge every time the
  /// app came back to the foreground.
  Future<void> connect({
    required void Function(PollOutcome outcome) onMessage,
    void Function(Object error)? onError,
    void Function()? onConnected,
  }) async {
    _closed = false;

    // Captured before the loop because the isolate cannot be handed `core`
    // itself -- it holds native pointers -- so it has to open the library the
    // same way this instance did. Null means "let the platform decide", which
    // is what production does.
    final libraryPath = core.libraryPath;

    try {
      core.coreStreamStart(handle);
      while (!_closed) {
        // The poll blocks, so it has to happen off the UI thread. One
        // short-lived isolate per poll rather than a long-lived one with a
        // SendPort: with a 20s timeout that is one spawn per idle period, and
        // under load each poll returns a whole batch, so the spawn count stays
        // low either way. It also leaves nothing to leak if this loop dies.
        final Map<String, dynamic> raw;
        try {
          raw = await Isolate.run(() => _pollInIsolate(handle, libraryPath));
        } catch (e) {
          // A poll that throws must not take the stream down silently. Report
          // it and stop, so the caller sees the account as unreachable rather
          // than as connected-but-eternally-quiet.
          if (!_closed) onError?.call(e);
          break;
        }
        if (_closed) break;

        final result = CorePollResult.fromJson(raw);
        for (final event in result.events) {
          if (_closed) break;
          switch (event.kind) {
            case 'connected':
              onConnected?.call();
            case 'message':
              if (event.outcome != null) onMessage(event.outcome!);
            case 'failed':
              // Not an ApiException: that type means a server answered and
              // said no, which is precisely what did not happen here, and
              // dressing a failed connect as one is what stopped the caller
              // recognising an unreachable server as ordinary.
              onError?.call(
                FreizoneCoreException(
                  event.error ?? 'stream attempt failed',
                  code: event.errorCode,
                ),
              );
            case 'disconnected':
              break; // the core is already reconnecting -- see above
          }
        }
        if (!result.streaming) break;
      }
    } finally {
      // Stops the stream, never the handle: [handle] outlives this call, so
      // whatever ended the loop above -- a clean [close], a poll that threw,
      // the core giving up -- only has to release the subscriber slot, not
      // tear down sends and reads that may still be using the same handle.
      //
      // Unless the handle is already gone, which is not a failure: this loop
      // keeps running after [close] returns, so a teardown that closes the
      // handle straight afterwards (AppSession.dispose does, and cannot await
      // this) races it here -- and by then the handle being closed has already
      // released the slot this call exists to release. Swallowed rather than
      // left to surface as an unhandled async error nobody can act on.
      try {
        core.coreStreamStop(handle);
      } on FreizoneCoreException {
        // Nothing to stop.
      }
    }
  }

  /// Closes the stream and releases this device's subscriber slot on the server,
  /// so a message arriving while the app is backgrounded triggers a push wake
  /// instead of being delivered into a stream nobody is reading.
  ///
  /// Marks itself closed first, so the loop exits without reporting an error and
  /// reachability is left untouched -- the same clean-disconnect contract
  /// sse_client.dart had. Safe when no stream is open.
  ///
  /// Prompt, in both halves: stopping cancels the core's context, which drops
  /// the HTTP connection and with it the server-side slot, and it closes the
  /// event channel the poll in flight is waiting on -- so the loop returns
  /// straight away rather than sitting out the rest of [_pollTimeout].
  void close() {
    _closed = true;
    core.coreStreamStop(handle);
  }
}

/// Runs one blocking poll. Top-level and taking only plain values, because an
/// isolate entry point cannot capture a [FreizoneCore] -- it holds native
/// pointers. The handle is just a number and the library is already loaded in
/// this process, so opening bindings again inside the isolate is cheap.
///
/// [libraryPath] has to be passed through: null lets the platform decide, which
/// is right in the app, but a host test loaded the library from a path and the
/// isolate cannot find it by name.
Map<String, dynamic> _pollInIsolate(int handle, String? libraryPath) =>
    FreizoneCore(
      libraryPath: libraryPath,
    ).corePoll(handle: handle, timeoutMs: _pollTimeout.inMilliseconds);

/// Where the core keeps this account's state -- beside the profile file
/// local_state.dart writes, so both live and die with the app's data. Same
/// directory the settings, contact and group stores use.
///
/// A directory, not a file: the core stores plain files rather than a database.
/// The name deliberately carries no `.db` suffix, which it did while this was
/// SQLite -- besides being a lie now, that name is already taken on any install
/// from that period, and creating a directory where a file sits fails.
Future<String> coreStatePath(String accountId) async {
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}${Platform.pathSeparator}core-$accountId';
}

/// Deletes everything the core holds for one account, for account removal.
///
/// Here rather than in account_manager.dart because it belongs beside
/// [coreStatePath]: a second place that spells out this layout is how the app
/// spent five days cleaning a directory nothing had written to since the
/// SRV-23 cut, while the real one grew beside it.
///
/// **What this removes is not only storage.** The directory holds the account's
/// transcripts and pictures, both ratchet sessions per peer, the cached peer
/// devices, every group's fact set -- and the identity private keys. Leaving it
/// behind makes `AccountManager.deleteAccount`'s "there is no path back to this
/// identity afterward" untrue on the one device where it matters most.
///
/// The caller must have closed this account's core handle first (AppSession's
/// dispose does, via coreClose) and deleted its profile, so a background push
/// wake arriving mid-removal finds no profile, returns, and cannot recreate
/// what was just deleted.
///
/// Reports rather than throws: the account is already gone from the app by the
/// time this runs, so failing the removal over it would leave a worse state
/// than the leftover it is complaining about. A failure is worth reading in a
/// log, which is why it is not swallowed silently either.
Future<void> deleteCoreState(String accountId) async {
  try {
    final dir = Directory(await coreStatePath(accountId));
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (e) {
    logDiagnostic('could not delete core state for $accountId: $e');
  }
}
