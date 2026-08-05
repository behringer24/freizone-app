// The evidence behind "remove permanently" (APP-19). This is the only deletion
// that drops a ratchet session, so a wrong verdict here is a lost message --
// specifically, the first messages of a peer who turned out not to be gone.
//
// The property being tested throughout: **only a definite absence may report
// that nothing can be lost.** Everything else, including a peer who is plainly
// still there, keeps couldStillLoseMessages true.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/net/api_client.dart';
import 'package:freizone/net/dto.dart';
import 'package:freizone/state/peer_absence.dart';

class _FakeApi implements ApiClient {
  _FakeApi({this.answer, this.throws});

  final AccountResponse? answer;
  final Object? throws;

  @override
  Future<AccountResponse> getAccount(String accountId) async {
    if (throws != null) throw throws!;
    return answer!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('only getAccount is used');
}

AccountResponse account({required List<String> deviceStatuses}) =>
    AccountResponse.fromJson({
      'id': 'qclara00000000000000a',
      'root_pubkey': '',
      'devices': [
        for (var i = 0; i < deviceStatuses.length; i++)
          {
            'device_id': 'device$i',
            'device_pubkey': '',
            'issued_at': '2026-08-01T00:00:00.000Z',
            'signature': '',
            'status': deviceStatuses[i],
          },
      ],
    });

void main() {
  Future<PeerAbsenceVerdict> check(_FakeApi api) => checkPeerAbsence(
    accountId: 'qclara00000000000000a',
    server: 'https://a.example.org',
    clientFor: (_) => api,
  );

  group('definite absence -- nothing can be lost', () {
    test('404 means the account is gone', () async {
      final verdict = await check(
        _FakeApi(throws: ApiException(404, 'not_found', 'gone')),
      );
      expect(verdict.absence, PeerAbsence.gone);
      expect(verdict.couldStillLoseMessages, isFalse);
    });

    test('no active device means nobody can send from it', () async {
      // It exists, and is messageable by nobody: without an active device no
      // session can be established and nothing can be sent.
      final verdict = await check(
        _FakeApi(answer: account(deviceStatuses: ['revoked', 'revoked'])),
      );
      expect(verdict.absence, PeerAbsence.noActiveDevice);
      expect(verdict.couldStillLoseMessages, isFalse);
    });

    test('an account with no devices at all counts the same', () async {
      final verdict = await check(
        _FakeApi(answer: account(deviceStatuses: [])),
      );
      expect(verdict.absence, PeerAbsence.noActiveDevice);
      expect(verdict.couldStillLoseMessages, isFalse);
    });

    test('a host that stopped being a Freizone server', () async {
      final verdict = await check(
        _FakeApi(throws: NotFreizoneServerException(200, 'a.example.org')),
      );
      expect(verdict.absence, PeerAbsence.notAFreizoneServer);
      expect(verdict.couldStillLoseMessages, isFalse);
    });
  });

  group('not absence -- a message could still be lost', () {
    test('an active device means they are simply still there', () async {
      final verdict = await check(
        _FakeApi(answer: account(deviceStatuses: ['revoked', 'active'])),
      );
      expect(verdict.absence, PeerAbsence.present);
      expect(verdict.couldStillLoseMessages, isTrue);
    });

    test('unreachable is NOT gone, however much it looks like it', () async {
      // The whole reason this file exists: a temporary condition wearing the
      // same clothes. Treating it as an answer is how a working chat loses its
      // messages.
      final verdict = await check(
        _FakeApi(throws: const SocketException('no route to host')),
      );
      expect(verdict.absence, PeerAbsence.unknown);
      expect(verdict.couldStillLoseMessages, isTrue);
      expect(verdict.detail, contains('not the same as gone'));
    });

    test('a server error is unknown, not a denial of the account', () async {
      final verdict = await check(_FakeApi(throws: ApiException(500, null, 'boom')));
      expect(verdict.absence, PeerAbsence.unknown);
      expect(verdict.couldStillLoseMessages, isTrue);
    });

    test('every verdict says what was established, for the dialog', () async {
      // The confirmation is worded from this, so an empty one would leave the
      // user agreeing to a consequence nobody stated.
      for (final api in [
        _FakeApi(throws: ApiException(404, 'not_found', 'gone')),
        _FakeApi(answer: account(deviceStatuses: [])),
        _FakeApi(answer: account(deviceStatuses: ['active'])),
        _FakeApi(throws: const SocketException('down')),
      ]) {
        final verdict = await check(api);
        expect(verdict.detail, isNotEmpty);
      }
    });
  });
}
