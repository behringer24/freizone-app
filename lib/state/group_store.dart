// Where a group's signed fact set lives on disk (APP-16).
//
// Deliberately NOT in the account profile, which is rewritten in full on every
// single message. A group's facts have the opposite write profile: tens of
// kilobytes that change rarely, against a transcript that changes constantly.
// This is the same reasoning that keeps image bytes out of the profile.
//
// One file per group, per account:
//
//     <documents>/groups/<account id>/<group id>.json
//
// The content is the opaque blob the native core produces -- nothing here
// parses it. Losing a file costs at most a re-sync, since the fact set is
// grow-only and any member can hand back a full snapshot; there is no
// bookkeeping to repair and nothing that can be half-applied.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

class GroupStateStore {
  static Future<Directory> _accountDir(String accountId) async {
    final root = await getApplicationDocumentsDirectory();
    return Directory(
      [root.path, 'groups', accountId].join(Platform.pathSeparator),
    );
  }

  static Future<File> _file(String accountId, String groupId) async {
    final dir = await _accountDir(accountId);
    return File('${dir.path}${Platform.pathSeparator}$groupId.json');
  }

  /// Loads one group's fact set, or null if this device has never heard of it.
  ///
  /// A file that fails to parse is treated as absent rather than fatal: the
  /// blob is re-obtainable from any member, and refusing to start an account
  /// because one group's file is damaged would be far worse than re-syncing
  /// it.
  static Future<Map<String, dynamic>?> load(
    String accountId,
    String groupId,
  ) async {
    try {
      final file = await _file(accountId, groupId);
      if (!file.existsSync()) return null;
      return json.decode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Loads every group this account knows about, keyed by group id.
  static Future<Map<String, Map<String, dynamic>>> loadAll(
    String accountId,
  ) async {
    final out = <String, Map<String, dynamic>>{};
    final dir = await _accountDir(accountId);
    if (!dir.existsSync()) return out;

    for (final entity in dir.listSync()) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (entity is! File || !name.endsWith('.json')) continue;
      final groupId = name.substring(0, name.length - '.json'.length);
      final blob = await load(accountId, groupId);
      if (blob != null) out[groupId] = blob;
    }
    return out;
  }

  /// Writes via a uniquely-named temp file and an atomic rename, the same
  /// contract [LocalStateStore.saveProfile] uses -- so a reader can never
  /// observe a half-written file, and two writers resolve cleanly as
  /// whichever rename lands last rather than corrupting each other.
  static Future<void> save(
    String accountId,
    String groupId,
    Map<String, dynamic> blob,
  ) async {
    final file = await _file(accountId, groupId);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.${Random().nextInt(1 << 32)}.tmp');
    await tmp.writeAsString(json.encode(blob));
    await tmp.rename(file.path);
  }

  // delete/deleteAll were removed on 2026-08-15 along with the rest of the
  // pre-cut cleanup: this store has had no writer on any live path since the
  // core took over a group's facts, so an install made since the cut has no
  // directory here to remove and the deletions were permanent code for an
  // artefact that only exists on a device that upgraded through the cut.
  //
  // What is left of this file is on the same footing -- see AppSession's
  // _groupStates, which its own doc comment already calls dead. Removing it
  // properly means tracing those paths rather than assuming, which is its own
  // pass and not this one.
}
