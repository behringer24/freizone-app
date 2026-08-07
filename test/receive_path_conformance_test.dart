// Runs freizone-server's shared receive-path vectors (SRV-23) against this
// app's own implementation, so the two clients are held to one written-down
// standard instead of drifting apart quietly.
//
// The vectors and their reasoning live in freizone-server's pkg/conformance;
// the Go client runs the same files from cmd/devclient/conformance_test.go.
// Expectations there are authored from docs/PROTOCOL.md rather than recorded
// from either implementation, so a failure here is a claim about this app, not
// about the vector.
//
// Needs the native core built for the development host:
//
//     pwsh native/build_desktop.ps1
//
// Without it this file skips rather than fails -- the core is gitignored, so a
// fresh checkout has none. That build is also what makes lib/state/ testable at
// all: every test touching it needs the core, which is why processIncomingMessage
// had no coverage before this.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/ffi/freizone_core.dart';
import 'package:freizone/ffi/freizone_core_exception.dart';
import 'package:freizone/ffi/models.dart';
import 'package:freizone/net/dto.dart';
import 'package:freizone/state/app_session.dart';
import 'package:freizone/state/local_state.dart';

/// freizone-server checked out beside this repo, as CLAUDE.md assumes and
/// native/go.mod's `replace` already requires.
const _vectorDir = '../freizone-server/pkg/conformance/testdata';

String get _corePath {
  final name = Platform.isWindows
      ? 'freizonecore.dll'
      : Platform.isMacOS
      ? 'libfreizonecore.dylib'
      : 'libfreizonecore.so';
  return File('native/$name').absolute.path;
}

void main() {
  final skip = _skipReason();
  if (skip != null) {
    test('receive-path conformance', () {}, skip: skip);
    return;
  }

  final core = FreizoneCore(libraryPath: _corePath);
  final vectors = _loadVectors();

  group('receive-path conformance', () {
    for (final v in vectors) {
      test(v.name, () async {
        final state = _stateFrom(v.receiver);
        for (var i = 0; i < v.steps.length; i++) {
          final step = v.steps[i];
          final problems = await _runStep(state, core, step);
          expect(
            problems,
            isEmpty,
            reason:
                'step ${i + 1} (${step.label}) of ${v.name}\n'
                '${v.description}\n\n${problems.join('\n')}',
          );
        }
      });
    }
  });
}

String? _skipReason() {
  if (!Directory(_vectorDir).existsSync()) {
    return 'conformance vectors not found at $_vectorDir -- is freizone-server '
        'checked out beside this repo?';
  }
  if (!File(_corePath).existsSync()) {
    return 'native core not built for this host -- run native/build_desktop.ps1';
  }
  return null;
}

// --- running one step ------------------------------------------------------

enum _Outcome { decrypted, duplicate, undecryptable }

/// Feeds one envelope through [processIncomingMessage] and reports every way
/// the result missed the vector. Empty means conforming.
Future<List<String>> _runStep(
  AppState state,
  FreizoneCore core,
  _Step step,
) async {
  final peer = step.senderAccountId;
  final roleBefore = _role(state.sessions[peer]);
  // The id-based short-circuit is invisible afterwards -- it leaves no trace by
  // design -- so whether this envelope was already handled has to be read
  // before the call.
  final alreadyProcessed = state.processedMessageIds.contains(step.messageId);

  _Outcome outcome;
  String? failureCode;
  bool? suggestsDesync;

  try {
    final result = await processIncomingMessage(
      state,
      MessageResponse(
        messageId: step.messageId,
        senderAccountId: peer,
        senderDeviceId: 'conformance-device',
        sentAt: DateTime.utc(2026, 1, 1),
        payload: step.payload,
      ),
      core,
    );
    if (result == null) {
      // No session and no X3DH material to start one.
      outcome = _Outcome.undecryptable;
    } else {
      outcome = alreadyProcessed ? _Outcome.duplicate : _Outcome.decrypted;
    }
  } on FreizoneCoreException catch (e) {
    failureCode = e.code;
    suggestsDesync = e.suggestsDesync;
    outcome = e.code == CoreErrorCode.duplicateMessage
        ? _Outcome.duplicate
        : _Outcome.undecryptable;
  }

  final want = step.expect;
  final problems = <String>[];

  if (outcome.name != want.outcome) {
    problems.add('outcome: want "${want.outcome}", got "${outcome.name}"'
        '${failureCode == null ? '' : ' (code $failureCode)'}');
  }

  if (want.text != null) {
    final got = _lastMessageText(state, peer);
    if (got != want.text) {
      problems.add('text: want "${want.text}", got ${got == null ? 'no stored message' : '"$got"'}');
    }
  }

  if (want.failureCode != null && failureCode != want.failureCode) {
    problems.add('failure code: want "${want.failureCode}", got ${failureCode ?? 'none'}');
  }

  if (want.countsAsDesyncEvidence != null) {
    // A step that did not fail cannot be evidence of anything, so "no failure"
    // reads as false rather than as unknown.
    final got = suggestsDesync ?? false;
    if (got != want.countsAsDesyncEvidence) {
      problems.add('desync evidence: want ${want.countsAsDesyncEvidence}, got $got');
    }
  }

  if (want.sessionEffect != null) {
    final got = _sessionEffect(roleBefore, _role(state.sessions[peer]));
    if (got != want.sessionEffect) {
      problems.add('session effect: want "${want.sessionEffect}", got "$got" '
          '(role ${roleBefore ?? 'none'} -> ${_role(state.sessions[peer]) ?? 'none'})');
    }
  }

  if (want.inboundSessionKept != null) {
    final got = state.inboundSessions[peer] != null;
    if (got != want.inboundSessionKept) {
      problems.add('inbound session kept: want ${want.inboundSessionKept}, got $got');
    }
  }

  if (want.oneTimePrekeysRemaining != null) {
    final got = state.oneTimePrekeys.length;
    if (got != want.oneTimePrekeysRemaining) {
      problems.add('one-time prekeys remaining: want ${want.oneTimePrekeysRemaining}, got $got');
    }
  }

  return problems;
}

String? _role(RatchetSessionJson? session) => session?['role'] as String?;

/// Mirrors pkg/conformance's SessionEffect: whether the session used for
/// sending was *replaced*, read off its X3DH role. See that file for where the
/// role stops being able to tell.
String _sessionEffect(String? before, String? after) {
  if (before == null && after != null) return 'established';
  if (before != after) return 'adopted_peer';
  return 'unchanged';
}

String? _lastMessageText(AppState state, String peer) {
  final messages = state.conversations[peer]?.messages;
  if (messages == null || messages.isEmpty) return null;
  return messages.last.text;
}

// --- priming state from a vector -------------------------------------------

AppState _stateFrom(_Receiver r) {
  final empty = Uint8List(0);
  return AppState(
    server: 'https://conformance.invalid',
    accountId: r.accountId,
    // The receive path never reaches for root or device keys -- those sign HTTP
    // requests, and a vector makes no requests.
    rootPub: empty,
    rootPriv: empty,
    deviceId: 'conformance-device',
    devicePub: empty,
    devicePriv: empty,
    dhIdentityPriv: r.dhIdentityPriv,
    signedPrekeyId: 1,
    signedPrekeyPriv: r.signedPrekeyPriv,
    oneTimePrekeys: {
      for (final e in r.oneTimePrekeys.entries)
        e.key: OneTimePrekeyState(pub: Uint8List(0), priv: e.value),
    },
    sessions: Map<String, RatchetSessionJson>.from(r.sessions),
    inboundSessions: Map<String, RatchetSessionJson>.from(r.inboundSessions),
    processedMessageIds: r.processedMessageIds.toSet(),
  );
}

// --- vector model ----------------------------------------------------------

class _Vector {
  _Vector(this.name, this.description, this.receiver, this.steps);
  final String name;
  final String description;
  final _Receiver receiver;
  final List<_Step> steps;
}

class _Receiver {
  _Receiver({
    required this.accountId,
    required this.dhIdentityPriv,
    required this.signedPrekeyPriv,
    required this.oneTimePrekeys,
    required this.sessions,
    required this.inboundSessions,
    required this.processedMessageIds,
  });
  final String accountId;
  final Uint8List dhIdentityPriv;
  final Uint8List signedPrekeyPriv;
  final Map<int, Uint8List> oneTimePrekeys;
  final Map<String, Map<String, dynamic>> sessions;
  final Map<String, Map<String, dynamic>> inboundSessions;
  final List<String> processedMessageIds;
}

class _Step {
  _Step({
    required this.label,
    required this.messageId,
    required this.senderAccountId,
    required this.payload,
    required this.expect,
  });
  final String label;
  final String messageId;
  final String senderAccountId;
  final Map<String, dynamic> payload;
  final _Expect expect;
}

class _Expect {
  _Expect(Map<String, dynamic> j)
    : outcome = j['outcome'] as String,
      text = j['text'] as String?,
      failureCode = j['failure_code'] as String?,
      countsAsDesyncEvidence = j['counts_as_desync_evidence'] as bool?,
      sessionEffect = j['session_effect'] as String?,
      inboundSessionKept = j['inbound_session_kept'] as bool?,
      oneTimePrekeysRemaining = j['one_time_prekeys_remaining'] as int?;
  final String outcome;
  final String? text;
  final String? failureCode;
  final bool? countsAsDesyncEvidence;
  final String? sessionEffect;
  final bool? inboundSessionKept;
  final int? oneTimePrekeysRemaining;
}

List<_Vector> _loadVectors() {
  final files =
      Directory(_vectorDir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  return [
    for (final f in files)
      _parseVector(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>),
  ];
}

_Vector _parseVector(Map<String, dynamic> j) {
  final r = j['receiver'] as Map<String, dynamic>;
  return _Vector(
    j['name'] as String,
    j['description'] as String,
    _Receiver(
      accountId: r['account_id'] as String,
      dhIdentityPriv: decodeB64(r['dh_identity_priv'] as String),
      signedPrekeyPriv: decodeB64(r['signed_prekey_priv'] as String),
      // Go marshals a map[uint32][]byte with stringified integer keys.
      oneTimePrekeys: {
        for (final e in (r['one_time_prekeys'] as Map<String, dynamic>? ?? {})
            .entries)
          int.parse(e.key): decodeB64(e.value as String),
      },
      sessions: _sessionMap(r['sessions']),
      inboundSessions: _sessionMap(r['inbound_sessions']),
      processedMessageIds:
          (r['processed_message_ids'] as List<dynamic>? ?? const [])
              .cast<String>(),
    ),
    [
      for (final s in j['steps'] as List<dynamic>)
        _Step(
          label: (s as Map<String, dynamic>)['label'] as String,
          messageId: s['message_id'] as String,
          senderAccountId: s['sender_account_id'] as String,
          payload: s['payload'] as Map<String, dynamic>,
          expect: _Expect(s['expect'] as Map<String, dynamic>),
        ),
    ],
  );
}

Map<String, Map<String, dynamic>> _sessionMap(Object? raw) => {
  for (final e in (raw as Map<String, dynamic>? ?? {}).entries)
    e.key: e.value as Map<String, dynamic>,
};
