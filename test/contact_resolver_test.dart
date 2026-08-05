// Resolving a hand-typed address before a contact is made from it (APP-19).
//
// The rule under test is the one that keeps a broken contact from existing at
// all: a definite "no" and "I could not ask" must not be the same outcome. The
// first means the address is wrong; the second means nothing was learned, and
// creating a contact from it would produce a record that fails later, when
// nobody remembers typing it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/net/api_client.dart';
import 'package:freizone/net/dto.dart';
import 'package:freizone/state/contact_resolver.dart';

/// A stand-in for the public directory lookup. Only [getAccount] is reached, so
/// nothing here needs a real core or a socket.
class _FakeApi implements ApiClient {
  _FakeApi({this.answer, this.throws});

  final AccountResponse? answer;
  final Object? throws;
  String? askedFor;

  @override
  Future<AccountResponse> getAccount(String accountId) async {
    askedFor = accountId;
    if (throws != null) throw throws!;
    return answer!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('only getAccount is used');
}

AccountResponse account(String id) =>
    AccountResponse.fromJson({'id': id, 'root_pubkey': '', 'devices': []});

const canonical = 'qclara00000000000000a';

void main() {
  Future<ResolvedContactAddress> resolve(
    String input,
    _FakeApi api, {
    String fallback = 'https://a.example.org',
  }) => resolveContactAddress(
    input,
    fallbackServer: fallback,
    clientFor: (_) => api,
  );

  test('a prefix resolves to the canonical id the server reports', () async {
    // The whole point: every certificate in that account's chain is signed over
    // the canonical form, so a contact keyed by the five characters typed here
    // would be unusable.
    final api = _FakeApi(answer: account(canonical));
    final resolved = await resolve('qclar', api);

    expect(api.askedFor, 'qclar');
    expect(resolved.accountId, canonical);
    expect(resolved.server, 'https://a.example.org');
  });

  test('a dash-grouped id is normalized before it is asked about', () async {
    final api = _FakeApi(answer: account(canonical));
    await resolve('qclar-a0000-00000-00000-a', api);
    expect(api.askedFor, canonical);
  });

  test('an explicit *server wins over the fallback', () async {
    final api = _FakeApi(answer: account(canonical));
    final resolved = await resolve('$canonical*b.example.org', api);
    expect(resolved.server, contains('b.example.org'));
  });

  test('a malformed address never reaches the network', () async {
    final api = _FakeApi(answer: account(canonical));
    await expectLater(
      resolve('  ', api),
      throwsA(
        isA<ContactResolutionException>().having(
          (e) => e.problem,
          'problem',
          ContactResolutionProblem.malformedAddress,
        ),
      ),
    );
    expect(api.askedFor, isNull);
  });

  test('404 is a definite no, and not worth retrying', () async {
    final api = _FakeApi(throws: ApiException(404, 'not_found', 'no such account'));
    try {
      await resolve('qclar', api);
      fail('should not resolve');
    } on ContactResolutionException catch (e) {
      expect(e.problem, ContactResolutionProblem.noSuchAccount);
      expect(e.worthRetrying, isFalse);
    }
  });

  test('a host that is not a Freizone server is its own answer', () async {
    final api = _FakeApi(throws: NotFreizoneServerException(200, 'example.org'));
    try {
      await resolve('qclar', api);
      fail('should not resolve');
    } on ContactResolutionException catch (e) {
      expect(e.problem, ContactResolutionProblem.notAFreizoneServer);
      expect(e.worthRetrying, isFalse);
    }
  });

  group('learning nothing is not learning "no"', () {
    test('an unreachable server is retryable, not a missing account', () async {
      final api = _FakeApi(throws: const SocketException('no route to host'));
      try {
        await resolve('qclar', api);
        fail('should not resolve');
      } on ContactResolutionException catch (e) {
        expect(e.problem, ContactResolutionProblem.couldNotAsk);
        expect(e.worthRetrying, isTrue);
      }
    });

    test('a 500 is retryable too -- the server did not deny the account', () async {
      final api = _FakeApi(throws: ApiException(500, null, 'boom'));
      try {
        await resolve('qclar', api);
        fail('should not resolve');
      } on ContactResolutionException catch (e) {
        expect(e.problem, ContactResolutionProblem.couldNotAsk);
        expect(e.worthRetrying, isTrue);
      }
    });
  });
}
