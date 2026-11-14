// Locations this phone has captured, remembered until the server has them
// (14 Nov 2026, the user: a location once captured sometimes asked to be
// captured again).
//
// A capture is sent or kept in the outbox (services/outbox.dart), and the
// page shows it at once. But the customer and lead lists are what every page
// is opened from, and they come from the server or, with no signal, from the
// copy kept on the phone (services/net_cache.dart, offline_cache.dart). Until
// a queued capture reaches the server - and for as long as the phone answers
// from a copy read before it - those lists still say "Not Captured", so the
// next visit to the page asked for the capture again.
//
// So each capture is noted here and laid over the rows as they are read. While
// it is still in the outbox it always counts: the server cannot have it, and
// other writes to the record (the hourly SAP credit sync rewrites customers)
// say nothing about it. Once it has gone, the server's record wins as soon as
// it is newer than the capture - it then holds ours, or a manager sent the
// location back after it, and the rep is rightly asked again. Which way it
// falls when unsure: captured.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/services/outbox.dart';

class LocalCaptures {
  static const _key = 'localCaptures';

  /// A note older than this is dropped unread: by then the outbox has long
  /// sent it or the rep has captured again.
  static const _keepDays = 30;

  static Map<String, Map<String, dynamic>>? _mem;

  static String _id(String doctype, String name) => '$doctype|$name';

  static Future<Map<String, Map<String, dynamic>>> _load() async {
    final m = _mem;
    if (m != null) return m;
    final out = <String, Map<String, dynamic>>{};
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      final j = raw == null ? null : jsonDecode(raw);
      if (j is Map) {
        for (final e in j.entries) {
          if (e.value is Map) out['${e.key}'] = Map<String, dynamic>.from(e.value as Map);
        }
      }
    } catch (_) {}
    return _mem = out;
  }

  static Future<void> _save() async {
    try {
      await (await SharedPreferences.getInstance())
          .setString(_key, jsonEncode(_mem ?? const {}));
    } catch (_) {}
  }

  /// Notes a capture just made of [name] (a Customer or a Lead), as the page
  /// showed it.
  static Future<void> record({
    required String doctype,
    required String name,
    required String status,
    required double lat,
    required double lng,
    required bool selfVerified,
    required bool recapture,
  }) async {
    final m = await _load();
    m[_id(doctype, name)] = {
      'status': status,
      'lat': lat,
      'lng': lng,
      'self': selfVerified,
      'recapture': recapture,
      'at': nowStamp(),
    };
    await _save();
  }

  static const _captured = {'Pending Verification', 'Verified'};

  static String _stamp(Object? v) {
    final s = '${v ?? ''}'.trim();
    return s.length >= 19 ? s.substring(0, 19) : s;
  }

  /// Lays this phone's captures over [rows] of [doctype], in place, and
  /// returns them. See the file comment for when a note stops applying.
  static Future<List<Map<String, dynamic>>> overlay(
      String doctype, List<Map<String, dynamic>> rows) async {
    final m = await _load();
    if (m.isEmpty) return rows;
    var changed = false;
    final queued = <String>{};
    try {
      for (final i in await Outbox.all()) {
        if (i.kind == 'lead_location') queued.add(_id('Lead', '${i.args['lead']}'));
        if (i.kind == 'customer_location' && i.args['done'] != true) {
          queued.add(_id('Customer', '${i.args['customer']}'));
        }
      }
    } catch (_) {}
    final cutoff = DateTime.now().subtract(const Duration(days: _keepDays));
    m.removeWhere((_, e) {
      final at = DateTime.tryParse('${e['at']}'.replaceFirst(' ', 'T'));
      final old = at == null || at.isBefore(cutoff);
      if (old) changed = true;
      return old;
    });
    for (final row in rows) {
      final id = _id(doctype, '${row['name']}');
      final e = m[id];
      if (e == null) continue;
      final at = '${e['at']}';
      final modified = _stamp(row['modified']);
      final status = '${row['custom_location_status'] ?? ''}';
      final serverNewer = modified.isNotEmpty && modified.compareTo(at) >= 0;
      if (serverNewer && !queued.contains(id)) {
        // The server has written the record since: it has our capture
        // (captured), or a manager sent it back after it (not captured).
        // Either way it is the truth from here on.
        m.remove(id);
        changed = true;
        continue;
      }
      if (_captured.contains(status) && e['recapture'] != true) continue;
      row['custom_location_status'] = e['status'];
      row['custom_latitude'] = e['lat'];
      row['custom_longitude'] = e['lng'];
      if (e['self'] == true) {
        row['custom_verified_latitude'] = e['lat'];
        row['custom_verified_longitude'] = e['lng'];
      } else if (e['recapture'] == true) {
        row['custom_verified_latitude'] = null;
        row['custom_verified_longitude'] = null;
      }
    }
    if (changed) await _save();
    return rows;
  }

  /// For tests: forget everything, in memory and on the phone.
  static Future<void> clearForTest() async {
    _mem = {};
    await _save();
  }
}
