// Which failures are worth interrupting somebody for.
//
// The predicate behind that decision was written when this app made its own
// requests, so it matches dart:io's exceptions. Every request is the core's
// now, and a failure arrives as a FreizoneCoreException carrying a code --
// which the predicate did not know, so the most ordinary failure there is
// stopped being recognised as ordinary. On a device that showed as a
// full-width red banner reciting a socket error every few seconds, next to
// the offline badge that was already saying the same thing calmly.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/ffi/freizone_core_exception.dart';
import 'package:freizone/util/errors.dart';

void main() {
  group('a server that is not there', () {
    test('is recognised however it is reported', () {
      expect(
        isServerUnreachable(const SocketException('refused')),
        isTrue,
        reason: 'dart:io, for the requests this app still makes itself',
      );
      expect(
        isServerUnreachable(TimeoutException('gave up')),
        isTrue,
      );
      expect(
        isServerUnreachable(
          FreizoneCoreException(
            'client: message stream did not open',
            code: CoreErrorCode.serverUnreachable,
          ),
        ),
        isTrue,
        reason: 'the core makes the requests now, and says so with a code',
      );
    });

    test('is not confused with a server that answered and refused', () {
      expect(
        isServerUnreachable(
          FreizoneCoreException('their server refused it', code: null),
        ),
        isFalse,
        reason: 'no code is undiagnosed, never "harmless"',
      );
      expect(
        isServerUnreachable(
          FreizoneCoreException(
            'that envelope was already decrypted',
            code: CoreErrorCode.duplicateMessage,
          ),
        ),
        isFalse,
      );
    });
  });

  group('what a failure reads as', () {
    test('a core message is shown without the wrapper name', () {
      expect(
        describeError(FreizoneCoreException('Their server is full right now.')),
        'Their server is full right now.',
        reason: '"FreizoneCoreException: ..." reads as a crash, not a reason',
      );
    });

    test('the core package prefix does not reach the reader', () {
      expect(
        describeError(
          FreizoneCoreException(
            "client: this contact's account no longer exists, so nothing can "
            'be sent to them',
          ),
        ),
        "This contact's account no longer exists, so nothing can be sent to "
        'them',
        reason:
            'every pkg/client error carries "client: ", so it classifies '
            'nothing for the reader -- it is a Go package name in front of a '
            'sentence written for them',
      );
    });

    test('the word client is only stripped as the leading prefix', () {
      expect(
        describeError(
          FreizoneCoreException('the client: something else entirely'),
        ),
        'the client: something else entirely',
      );
    });

    test('an unreachable server gets the one sentence that helps', () {
      expect(
        describeError(
          FreizoneCoreException(
            'client: dial tcp 192.168.178.89:18081: connect: connection refused',
            code: CoreErrorCode.serverUnreachable,
          ),
        ),
        startsWith('Server not reachable.'),
      );
    });
  });
}
