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
// EVERYTHING ELSE TOO (the user, 13 Nov 2026: "When the net is gone they
// must still be able to do everything in the app.") Approvals, new leads and
// customers, trips, pick lists and the rest come here as well, through
// `Api.writeOrQueue`. What the 11 Nov list kept out, and how each is now safe:
//   - Approvals: the sender is the same function that decides online, so it
//     reads the order as it is NOW and re-checks it. If someone else decided
//     it meanwhile, the item is refused with the reason, not written over.
//   - New leads, customers, trips: the phone hands back a [kLocalPrefix] name
//     at once, so the rep carries on with it. Anything queued behind that
//     carries the local name and is sent with the real one ([resolve]).
//   - Duplicate checks run when the item is sent; a failure refuses it.
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
import 'package:manna_field_sales/core/local_overlay.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';

/// What a screen says when it kept a write here. The same as being sent, on
/// purpose (13 Nov 2026): the user asked that nothing in the app say the
/// network has gone. Where it waits shows only on Waiting to Send.
const String kSavedOffline = 'Saved ✓';

/// The prefix of a name the phone gave something it made with no signal — a
/// lead, a trip, a visit — before the server has given it a real one.
const String kLocalPrefix = 'LOCAL-';

bool isLocalName(String? s) => s != null && s.startsWith(kLocalPrefix);

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

  /// What it will change once sent, laid over what screens read meanwhile
  /// (`core/local_overlay.dart`).
  final List<LocalEffect> effects;

  /// The [kLocalPrefix] name it handed back for a document it creates, which
  /// later writes may carry until the server gives the real one.
  final String? localName;

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
    this.effects = const [],
    this.localName,
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
        effects: effects,
        localName: localName,
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
        if (effects.isNotEmpty)
          'effects': effects.map((e) => e.toJson()).toList(),
        if (localName != null) 'local_name': localName,
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
      effects: [
        if (j['effects'] is List)
          for (final e in j['effects'] as List)
            if (LocalEffect.fromJson(e) case final x?) x
      ],
      localName: j['local_name'] as String?,
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
  static const _namesKey = 'outbox_names';

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

  /// What the items still to be sent will change, oldest first. A refused
  /// item changes nothing until the rep sends it again, so it is left out:
  /// showing its change would claim something the server said no to.
  static Future<List<LocalEffect>> effects() async => [
        for (final i in await all())
          if (!i.refused) ...i.effects
      ];

  /// A fresh [kLocalPrefix] name.
  static String newLocalName() =>
      '$kLocalPrefix${serverNow().microsecondsSinceEpoch}-${_seq++}';

  /// Local names the server has since given real ones to.
  static Future<Map<String, String>> names() async {
    try {
      final s = (await _prefs).getString(_namesKey);
      if (s == null || s.isEmpty) return {};
      final m = jsonDecode(s);
      return m is Map ? {for (final e in m.entries) '${e.key}': '${e.value}'} : {};
    } catch (_) {
      return {};
    }
  }

  /// Records that [local] is [real] on the server. Called by the sender of a
  /// create, the moment the server answers, so a write behind it in the queue
  /// goes with the real name.
  static Future<void> recordName(String local, String real) async {
    final m = await names();
    m[local] = real;
    await (await _prefs).setString(_namesKey, jsonEncode(m));
  }

  /// [value] with every local name the server has answered for replaced by
  /// the real one, at any depth. A local name with no answer yet is refused
  /// with the reason — the write it belongs to cannot go before the thing it
  /// points at exists.
  static Future<T> resolve<T>(T value) async {
    final m = await names();
    String? missing;
    dynamic walk(dynamic v) {
      if (v is String) {
        if (!isLocalName(v)) return v;
        final real = m[v];
        if (real == null) missing ??= v;
        return real ?? v;
      }
      if (v is Map) {
        return <String, dynamic>{
          for (final e in v.entries) '${e.key}': walk(e.value)
        };
      }
      if (v is List) return <dynamic>[for (final x in v) walk(x)];
      return v;
    }

    final out = walk(value);
    if (missing != null) {
      final maker = (await _raw()).where((i) => i.localName == missing);
      throw OutboxRefused(maker.isEmpty
          ? 'What this points at was never sent, so this cannot be sent.'
          : 'Waiting for "${maker.first.label}" to be sent first.');
    }
    return out as T;
  }

  /// [s] with a local name the server has answered for replaced; anything
  /// else as it is. For paths, where a refusal is the server's to give.
  static Future<String> realName(String s) async {
    if (!s.contains(kLocalPrefix)) return s;
    var out = s;
    for (final e in (await names()).entries) {
      out = out.replaceAll(e.key, e.value);
    }
    return out;
  }

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
    List<LocalEffect> effects = const [],
    String? localName,
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
      effects: effects,
      localName: localName,
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
      await (await _prefs).remove(_namesKey);
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
        // Local names first: a write about a lead made in the same dead zone
        // goes with the name the server gave that lead a moment ago.
        final resolved = await resolve(Map<String, dynamic>.from(item.args));
        item.args
          ..clear()
          ..addAll(resolved);
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
