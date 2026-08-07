// Recognizing a dead cached device id -- docs/PROTOCOL.md §4's stale-device
// rule, decision half. The *reaction* (forget the id, re-resolve the peer's
// device list, retry once) lives in AppSession, next to the cache it heals;
// what lives here is the classification of a server's answer, because getting
// it wrong in either direction has a real cost:
//
// - Too narrow, and a peer who re-created their account keeps a group member
//   (or a whole one-to-one chat) undeliverable forever -- every send claims a
//   prekey bundle for a device id their server has long forgotten, 404s, and
//   nothing ever heals. That is the live failure this file exists because of.
// - Too wide, and a 404 that says nothing about the device -- a peer server
//   with federation switched off -- would cost a perfectly good cached device
//   and its ratchet session, forcing a needless re-key when the switch comes
//   back on.
import '../net/api_client.dart';

/// Whether [e] is a server telling us the device id we sent it is dead.
///
/// On servers carrying the distinct codes that is `unknown_device` or
/// `no_prekey_bundle` (bundle claim) or `unknown_recipient` (message
/// delivery); servers from before the rule answer all of those with the
/// catch-all `not_found`, so any other 404 counts too. The one explicit
/// exception is `federation_disabled`, which is about the *server*, never
/// about the device.
bool isStaleDeviceError(Object e) =>
    e is ApiException &&
    e.statusCode == 404 &&
    e.code != 'federation_disabled';

/// The batch form of the same discovery: whether one copy's per-item status
/// (docs/PROTOCOL.md §7) says its recipient device is gone. Only
/// `unknown_recipient` does -- the other failure statuses (`queue_full`,
/// `invalid`, `internal_error`) describe conditions a retry against the same
/// device can legitimately outlive.
bool isStaleRecipientStatus(String? status) => status == 'unknown_recipient';
