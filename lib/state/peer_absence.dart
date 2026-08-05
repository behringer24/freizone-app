// Asking the public account directory whether a peer is actually gone (APP-19).
//
// This exists so that "remove permanently" -- the one deletion that also drops
// the ratchet session -- is **evidence-based rather than a guess**. Dropping a
// session is what makes a peer's next message undecryptable, so it is only safe
// where there can be no next message. `GET /v1/accounts/{id}` answers that
// without authentication and without any federation switch.
//
// The distinction the whole file exists for: "unreachable" is not "gone". It is
// a temporary condition wearing the same clothes, and treating it as an answer
// is how a working chat loses its messages.
import '../ffi/freizone_core.dart';
import '../net/api_client.dart';
import '../util/errors.dart';

/// What the directory said about a peer.
enum PeerAbsence {
  /// `404` -- the account no longer exists, so nothing can ever arrive from it.
  gone,

  /// It exists, but has no `active` device: reachable in principle, messageable
  /// by nobody. No device means no session can be established and nothing can be
  /// sent.
  noActiveDevice,

  /// That host stopped being a Freizone server, so this address cannot resolve
  /// from here at all.
  notAFreizoneServer,

  /// Nothing was learned. **Not** evidence of absence.
  unknown,

  /// The account is there and has an active device -- the peer is not gone.
  present,
}

class PeerAbsenceVerdict {
  const PeerAbsenceVerdict(this.absence, this.detail);

  final PeerAbsence absence;

  /// One sentence for the confirmation dialog, naming what was actually
  /// established rather than what is being assumed.
  final String detail;

  /// Whether dropping the ratchet session can lose a message.
  ///
  /// False for the three definite answers: with no account, no active device or
  /// no Freizone server on the far end, there is no sender left to lose one
  /// from. True for [unknown] *and* for [present] -- a peer who is merely
  /// unreachable right now is the case this check exists to refuse to guess at.
  bool get couldStillLoseMessages =>
      absence == PeerAbsence.unknown || absence == PeerAbsence.present;
}

/// Asks [server] about [accountId].
///
/// Unauthenticated and account-independent, like the contact resolver -- the
/// directory is public, which is what lets this be asked about a peer whose chat
/// is the only thing left of them.
Future<PeerAbsenceVerdict> checkPeerAbsence({
  required String accountId,
  required String server,
  ApiClient Function(String baseUrl)? clientFor,
}) async {
  final api = (clientFor ?? _defaultClient)(server);
  try {
    final account = await api.getAccount(accountId);
    final active = account.devices.where((d) => d.status == 'active');
    if (active.isEmpty) {
      return const PeerAbsenceVerdict(
        PeerAbsence.noActiveDevice,
        'This account still exists but has no active device, so nobody can '
            'send from it.',
      );
    }
    return const PeerAbsenceVerdict(
      PeerAbsence.present,
      'This account is still active, so they can still write to you.',
    );
  } on ApiException catch (e) {
    if (e.statusCode == 404) {
      return PeerAbsenceVerdict(
        PeerAbsence.gone,
        '$server no longer has this account, so nothing can arrive from it '
            'again.',
      );
    }
    return PeerAbsenceVerdict(
      PeerAbsence.unknown,
      '$server could not answer (${e.message}), so whether they are gone is '
          'unknown.',
    );
  } on NotFreizoneServerException {
    return PeerAbsenceVerdict(
      PeerAbsence.notAFreizoneServer,
      "$server doesn't look like a Freizone server any more, so this address "
          'cannot be reached from here.',
    );
  } catch (e) {
    if (isServerUnreachable(e)) {
      return PeerAbsenceVerdict(
        PeerAbsence.unknown,
        "$server could not be reached, so whether they are gone is unknown -- "
            'this is not the same as gone.',
      );
    }
    rethrow;
  }
}

ApiClient _defaultClient(String baseUrl) =>
    ApiClient(baseUrl: baseUrl, core: FreizoneCore());
