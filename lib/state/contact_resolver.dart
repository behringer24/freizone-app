// Resolving a hand-typed address into something a contact can be keyed by
// (APP-19).
//
// Why this exists at all: a contact **is** a canonical account id. A typed
// address may be a five-character prefix, dash-grouped, or carry an explicit
// `*server`, and a contact holding any of those is a contact that fails the
// moment somebody finally uses it -- the phantom-member lesson from APP-16, one
// layer up. So the address is resolved when the contact is made, and only the
// canonical form is stored.
//
// It needs no account of ours: `GET /v1/accounts/{id}` is a public, unauthenticated
// key directory, which is what lets an account-independent store do its own
// resolving. It does need a *host to ask*, though -- see [fallbackServer].
import '../ffi/freizone_core.dart';
import '../net/api_client.dart';
import '../util/errors.dart';
import '../util/freizone_address.dart';

/// A typed address, resolved.
class ResolvedContactAddress {
  const ResolvedContactAddress({required this.accountId, required this.server});

  /// The canonical, full account id as the server reported it -- never what was
  /// typed, which may have been a prefix.
  final String accountId;

  /// The server that answered for it.
  final String server;
}

/// Why a resolution did not produce an address.
///
/// The distinction that matters is the last one: everything above it is a
/// definite answer, and [couldNotAsk] is *not an answer at all*. A contact must
/// never be created from it -- a half-made contact would only be discovered
/// later, when it fails -- but the user should be offered a retry rather than
/// told the account does not exist.
enum ContactResolutionProblem {
  malformedAddress,
  noSuchAccount,
  notAFreizoneServer,
  couldNotAsk,
}

class ContactResolutionException implements Exception {
  ContactResolutionException(this.problem, this.message);

  final ContactResolutionProblem problem;
  final String message;

  /// True when nothing was learned, so a retry is the right offer.
  bool get worthRetrying => problem == ContactResolutionProblem.couldNotAsk;

  @override
  String toString() => message;
}

/// Resolves [input] against the server it names, or [fallbackServer] when it
/// names none.
///
/// [fallbackServer] is the one account-shaped input here, and deliberately only
/// that: a bare id has to be asked *somewhere*, and "the server of the account
/// you are using" is the same convention the new-chat sheet already applies to a
/// bare id. Nothing about the lookup is authenticated, and no account of ours
/// appears in it.
Future<ResolvedContactAddress> resolveContactAddress(
  String input, {
  required String fallbackServer,
  ApiClient Function(String baseUrl)? clientFor,
}) async {
  final parsed = parseFreizoneAddress(input);
  if (parsed == null) {
    throw ContactResolutionException(
      ContactResolutionProblem.malformedAddress,
      'That is not a Freizone address.',
    );
  }
  final server = parsed.server ?? fallbackServer;
  final api = (clientFor ?? _defaultClient)(server);

  try {
    final account = await api.getAccount(parsed.idOrPrefix);
    // The server's own spelling, not the input's: every certificate in this
    // account's chain is signed over exactly this form.
    return ResolvedContactAddress(accountId: account.id, server: server);
  } on ApiException catch (e) {
    if (e.statusCode == 404) {
      throw ContactResolutionException(
        ContactResolutionProblem.noSuchAccount,
        'No account with that address exists on $server.',
      );
    }
    throw ContactResolutionException(
      ContactResolutionProblem.couldNotAsk,
      '$server could not answer: ${e.message}',
    );
  } on NotFreizoneServerException {
    throw ContactResolutionException(
      ContactResolutionProblem.notAFreizoneServer,
      "$server doesn't look like a Freizone server.",
    );
  } catch (e) {
    if (isServerUnreachable(e)) {
      throw ContactResolutionException(
        ContactResolutionProblem.couldNotAsk,
        "Couldn't reach $server, so the address could not be checked.",
      );
    }
    rethrow;
  }
}

/// A client of its own per lookup, with a fresh core: this runs outside any
/// session, so there is no existing client for a server we may never have
/// spoken to.
ApiClient _defaultClient(String baseUrl) =>
    ApiClient(baseUrl: baseUrl, core: FreizoneCore());
