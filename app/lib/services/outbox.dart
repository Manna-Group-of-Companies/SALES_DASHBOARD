// A rep's field work kept on the phone when there is no signal, and sent by
// itself when there is (the user, 11 Nov 2026: "when the network connection is
// unavailable the app should continue working normally and all data is queued;
// when it is restored the application should send all queued data to ERP").
//
// Punches (`pending_punches.dart`), route points (`trip_points.dart`) and
// orders (`pending_orders.dart`) have queues of their own, each with rules the
// rest do not need. This one holds everything else a rep writes in the field:
// collections, expenses, complaints, leave and regularization requests, item
// requests, answers to the GM's conditions, a customer's location and banner
// photo, a customer's site, and edits to a customer or a lead.
//
// Each item is a kind and its arguments, not a recorded HTTP call: the sender
// (`Api.sendOutboxItem`) calls the very function the screen would have called,
// so a queued write and one sent at once cannot drift apart. A write that
// stamps "today" or "now" is given the moment it was saved instead, so a
// collection sent tomorrow is still dated today.
//
// NOT HERE, ON PURPOSE (the user, 11 Nov 2026)
//   - Approvals by managers, the GM and HR: a decision taken on what the phone
//     last saw, landing later, can contradict what has happened since.
//   - The Sync buttons and signing in: there is nothing to do without a server.
//   - New leads, new customers and trips: what is done on them offline has to
//     be linked to the record once it exists. Next, after the 14 Nov release.
//   - A lead's location: its duplicate check needs the server and refuses
//     without one, so that a shop is not put on the map twice.
//
// THE SAME RULES AS THE PUNCH QUEUE
//   - Sent oldest first, one run at a time (the home screen's one-minute retry
//     and the rep's Send button must not send one item twice).
//   - The signal going stops a run; everything not yet sent stays as it was.
//   - A refusal does not stop it: that item keeps its reason, is marked
//     refused and is not sent again by itself, and the next one goes.
//   - Items belong to the rep who made them and go on sign-out, after the
//     home screen has said so.
//   - A photo is copied into the app's own folder when the item is saved: the
//     camera's copy lives in a cache Android may empty before the signal comes.
//
// A write whose answer was lost can have reached the server, and is sent
// again: a collection or a complaint can then appear twice. The same is true
// of the order queue, and of a rep pressing Save twice on one bar of signal.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';

/// What every screen says when it kept a write here.
const String kSavedOffline =
    'No signal — saved on the phone. It is sent by itself when the signal is back.';

/// An item the app will not send as it stands, with the sentence to show.
class OutboxRefused implements Exception {
  final String message;
  const OutboxRefused(this.message);
  @override
  String toString() => message;
}

class OutboxItem {
  final String id;

  /// What it is — `collection`, `expense`, ... — which picks the sender.
  final String kind;

  /// What to call it in the rep's list: "Collection ₹5,000 — Drona Tyres".
  final String label;

  /// The arguments of the write, JSON-safe. Mutable on purpose: a two-step
  /// write records its first step here (`created`), so a resend after the
  /// signal went half-way does not do it twice.
  final Map<String, dynamic> args;

  /// Files to upload with it, by role (`photo`), as paths on the phone.
  final Map<String, String> files;

  final String salesPerson;
  final DateTime savedAt;
  final String? lastError;
  final bool refused;

  OutboxItem({
    required this.id,
    required this.kind,
    required this.label,
    required this.args,
    this.files = const {},
    required this.salesPerson,
    required this.savedAt,
    this.lastError,
    this.refused = false,
  });

  OutboxItem withError(String? error, {bool refused = false}) => OutboxItem(
        id: id,
        kind: kind,
        label: label,
        args: args,
        files: files,
        salesPerson: salesPerson,
        savedAt: savedAt,
        lastError: error,
        refused: refused,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'label': label,
        'args': args,
        if (files.isNotEmpty) 'files': files,
        'sales_person': salesPerson,
        'saved_at': savedAt.toIso8601String(),
        if (lastError != null) 'last_error': lastError,
        if (refused) 'refused': true,
      };

  /// Null for anything that cannot be sent: no id or no kind.
  static OutboxItem? fromJson(dynamic j) {
    if (j is! Map) return null;
    final id = '${j['id'] ?? ''}';
    final kind = '${j['kind'] ?? ''}';
    if (id.isEmpty || kind.isEmpty) return null;
    return OutboxItem(
      id: id,
      kind: kind,
      label: '${j['label'] ?? kind}',
      args: j['args'] is Map ? Map<String, dynamic>.from(j['args'] as Map) : {},
      files: {
        if (j['files'] is Map)
          for (final e in (j['files'] as Map).entries) '${e.key}': '${e.value}',
      },
      salesPerson: '${j['sales_person'] ?? ''}',
      savedAt: DateTime.tryParse('${j['saved_at'] ?? ''}') ?? serverNow(),
      lastError: j['last_error'] as String?,
      refused: j['refused'] == true,
    );
  }
}

/// What came of one attempt to send the queue.
class OutboxResult {
  final int sent;
  final List<OutboxItem> failed;

  /// True when sending stopped because the signal went.
  final bool stoppedOffline;
  const OutboxResult(this.sent, this.failed, this.stoppedOffline);
  static const nothing = OutboxResult(0, [], false);
}

class Outbox {
  static const _key = 'outbox';

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  static int _seq = 0;

  /// This rep's items, oldest first.
  static Future<List<OutboxItem>> all() async {
    final me = Session.I.salesPerson;
    return (await _raw()).where((i) => me == null || i.salesPerson == me).toList()
      ..sort((a, b) => a.savedAt.compareTo(b.savedAt));
  }

  static Future<int> count() async => (await all()).length;

  /// Items the home screen would send by itself: not refused.
  static Future<int> autoCount() async =>
      (await all()).where((i) => !i.refused).length;

  /// Keeps [kind] with [args] for later. [files] are copied into the app's own
  /// folder first; a copy that fails keeps the original path, which still
  /// works unless Android has emptied its cache by then.
  static Future<OutboxItem> add({
    required String kind,
    required String label,
    required Map<String, dynamic> args,
    Map<String, String> files = const {},
  }) async {
    final existing = await _raw();
    final now = serverNow();
    String id;
    do {
      id = 'out-${now.microsecondsSinceEpoch}-${_seq++}';
    } while (existing.any((i) => i.id == id));

    final kept = <String, String>{};
    for (final e in files.entries) {
      kept[e.key] = await _keepFile(id, e.key, e.value);
    }
    final item = OutboxItem(
      id: id,
      kind: kind,
      label: label,
      args: args,
      files: kept,
      salesPerson: Session.I.salesPerson ?? '',
      savedAt: now,
    );
    await _replaceAll([...existing, item]);
    return item;
  }

  /// Throws one item away, and its kept files.
  static Future<void> discard(String id) async {
    final all = await _raw();
    for (final i in all.where((i) => i.id == id)) {
      await _dropFiles(i);
    }
    await _replaceAll(all.where((i) => i.id != id).toList());
  }

  /// Wipes every item on the handset, not just this rep's. Sign-out only,
  /// after the rep has been told.
  static Future<void> clear() async {
    try {
      for (final i in await _raw()) {
        await _dropFiles(i);
      }
      await (await _prefs).remove(_key);
    } catch (_) {}
  }

  static Future<OutboxResult>? _inFlight;

  /// Sends this rep's items, oldest first, through [send]. See the header for
  /// the rules; [auto] is the home screen sending by itself, which leaves
  /// refused items for the rep.
  static Future<OutboxResult> flush(
    Future<void> Function(OutboxItem item) send, {
    String Function(Object error)? describe,
    bool auto = false,
  }) {
    return _inFlight ??=
        _flush(send, describe, auto).whenComplete(() => _inFlight = null);
  }

  static Future<OutboxResult> _flush(
    Future<void> Function(OutboxItem item) send,
    String Function(Object error)? describe,
    bool auto,
  ) async {
    final queue = await all();
    if (queue.isEmpty) return OutboxResult.nothing;
    final failed = <OutboxItem>[];
    var sent = 0;
    for (var i = 0; i < queue.length; i++) {
      final item = queue[i];
      if (auto && item.refused) {
        failed.add(item);
        continue;
      }
      try {
        await send(item);
        await _dropFiles(item);
        await _replaceAll((await _raw()).where((o) => o.id != item.id).toList());
        sent++;
      } catch (e) {
        final why = describe != null ? describe(e) : '$e';
        final offline = isNetworkFailure(e);
        // Saved with its args, which a two-step write may have added to.
        final kept = item.withError(why, refused: !offline);
        await _update(kept);
        failed.add(kept);
        if (offline) {
          failed.addAll(queue.skip(i + 1));
          return OutboxResult(sent, failed, true);
        }
      }
    }
    return OutboxResult(sent, failed, false);
  }

  // -- storage ---------------------------------------------------------------

  static Future<List<OutboxItem>> _raw() async {
    try {
      final s = (await _prefs).getString(_key);
      if (s == null || s.isEmpty) return [];
      final list = jsonDecode(s);
      if (list is! List) return [];
      return list.map(OutboxItem.fromJson).whereType<OutboxItem>().toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _update(OutboxItem item) async => _replaceAll(
      (await _raw()).map((o) => o.id == item.id ? item : o).toList());

  static Future<void> _replaceAll(List<OutboxItem> list) async {
    await (await _prefs)
        .setString(_key, jsonEncode(list.map((i) => i.toJson()).toList()));
  }

  static Future<String> _keepFile(String id, String role, String path) async {
    try {
      final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/outbox');
      await dir.create(recursive: true);
      final dot = path.lastIndexOf('.');
      final ext = dot > path.lastIndexOf('/') && dot >= 0 ? path.substring(dot) : '';
      final dest = '${dir.path}/$id-$role$ext';
      await File(path).copy(dest);
      return dest;
    } catch (_) {
      return path;
    }
  }

  /// Deletes the copies this queue made; never a file it did not make.
  static Future<void> _dropFiles(OutboxItem item) async {
    for (final p in item.files.values) {
      if (!p.contains('/outbox/${item.id}-')) continue;
      try {
        await File(p).delete();
      } catch (_) {}
    }
  }
}
