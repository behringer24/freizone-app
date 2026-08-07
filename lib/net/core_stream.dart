// The message stream, run by the shared Go core instead of by Dart (SRV-23).
//
// Replaces sse_client.dart, and deliberately keeps its shape: connect() with
// onMessage/onError/onConnected, and close(). AppSession's use of it is
// unchanged, which is the point -- the reconnection policy moved into
// freizone-server's pkg/client, not the app's idea of what a stream is.
//
// What the core now owns: opening the stream, the SSE line parsing, the two
// reconnect regimes (quick retry with the backoff reset after a stream that had
// come up and dropped, exponential backoff with jitter for one that never came
// up), and bounding a connect attempt so a routed-but-dead host surfaces in
// seconds. All of that is tested there, in Go, against a real server -- which is
// something the Dart version never had.
//
// What is left here: the isolate the blocking poll must run on, and the mapping
// from the core's events back onto the three callbacks.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import '../ffi/freizone_core.dart';
import '../state/local_state.dart';
import 'api_client.dart';
import 'dto.dart';

/// What one blocking `CorePoll` returned.
///
/// Typed here rather than in lib/ffi/models.dart because it carries a
/// [MessageResponse], and models.dart is deliberately the leaf of the
/// dependency order that lib/net/ builds on top of.
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
  const CoreStreamEvent({required this.kind, this.message, this.error});

  factory CoreStreamEvent.fromJson(Map<String, dynamic> j) => CoreStreamEvent(
    kind: j['kind'] as String? ?? 'unknown',
    message: j['message'] == null
        ? null
        : MessageResponse.fromJson(j['message'] as Map<String, dynamic>),
    error: j['error'] as String?,
  );

  /// "connected", "message", "disconnected" or "failed".
  ///
  /// A string rather than an index, deliberately: a core and an app build that
  /// disagree about the set then fail visibly on a name this build has never
  /// heard of, instead of silently reinterpreting a number as another event.
  final String kind;

  /// Present for "message".
  final MessageResponse? message;

  /// Present for "failed", and deliberately absent for "disconnected" even
  /// though the core knows why -- see [CoreStream.connect].
  final String? error;
}

/// How long one poll waits before coming back empty-handed. Long, because an
/// idle account is the normal case and every return is an isolate spawn; short
/// enough that [close] is not left waiting on it for long.
const _pollTimeout = Duration(seconds: 20);

class CoreStream {
  CoreStream({required this.core, required this.state, this.databasePath});

  final FreizoneCore core;
  final AppState state;

  /// Where to put the core's database, given an account id. Null uses
  /// [coreDatabasePath], which resolves through path_provider -- correct in the
  /// app and unavailable in a plain `flutter test`, which is why this is here.
  final Future<String> Function(String accountId)? databasePath;

  bool _closed = false;
  int? _handle;

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
    required void Function(MessageResponse message) onMessage,
    void Function(Object error)? onError,
    void Function()? onConnected,
  }) async {
    _closed = false;

    final int handle;
    try {
      handle = await _openCore();
    } catch (e) {
      if (!_closed) onError?.call(e);
      return;
    }
    if (_closed) {
      core.coreClose(handle);
      return;
    }
    _handle = handle;

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
              if (event.message != null) onMessage(event.message!);
            case 'failed':
              onError?.call(
                ApiException(0, null, event.error ?? 'stream attempt failed'),
              );
            case 'disconnected':
              break; // the core is already reconnecting -- see above
          }
        }
        if (!result.streaming) break;
      }
    } finally {
      _teardown();
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
    final handle = _handle;
    if (handle != null) core.coreStreamStop(handle);
  }

  void _teardown() {
    final handle = _handle;
    _handle = null;
    if (handle != null) core.coreClose(handle);
  }

  /// Opens the core's own database for this account and hands it the identity.
  ///
  /// The handle lives exactly as long as the stream, which is a deliberately
  /// temporary arrangement: while local_state.dart still owns the app's state,
  /// the core needs nothing but the identity, and tying the handle to the stream
  /// avoids threading a second lifecycle through AppSession for no gain. When
  /// the state migrates, the handle moves up to AppSession and this goes away.
  Future<int> _openCore() async {
    final resolve = databasePath ?? coreDatabasePath;
    final handle = core.coreOpen(await resolve(state.accountId));
    try {
      core.coreSetIdentity(
        handle: handle,
        accountId: state.accountId,
        server: state.server,
        rootPub: state.rootPub,
        rootPriv: state.rootPriv,
        deviceId: state.deviceId,
        devicePub: state.devicePub,
        devicePriv: state.devicePriv,
      );
    } catch (_) {
      core.coreClose(handle);
      rethrow;
    }
    return handle;
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

/// Where the core keeps this account's database -- beside the profile file
/// local_state.dart writes, so both live and die with the app's data. Same
/// directory the settings, contact and group stores use.
Future<String> coreDatabasePath(String accountId) async {
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}${Platform.pathSeparator}core-$accountId.db';
}
