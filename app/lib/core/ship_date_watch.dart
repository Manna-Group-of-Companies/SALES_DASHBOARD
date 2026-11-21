// What a rep or manager is told when Hi-Tech moves an item's delivery date.
//
// Same reasoning as `stage_watch.dart` (no Notification Log write access for
// a rep's or manager's login, no Server Script push): the device remembers
// the date it last showed for each line and reports the difference the next
// time the order is opened. Kept separate from `stage_watch.dart` rather than
// folded into it — that file's `StagePart` is specifically production's two
// stages, and the dashboard's TypeScript twin reads it the same way; a third,
// unrelated axis would change what both already mean.
//
// `custom_sap_ship_date` (`manna_sap_status.py`, 13 Nov 2026) is Hi-Tech's own
// promised date for the line (RDR1.ShipDate), sent only while the line is
// still Open in SAP. So a blank is itself news, not "nothing to report": it
// means the line has closed and nothing in SAP can move it again. Three
// things are reported, never collapsed into one "changed":
//   - a date appearing where there was none - the line became plannable, or
//     this is the first look that catches Hi-Tech having moved it;
//   - a date changing to another date - Hi-Tech moved it again;
//   - a date disappearing - the line closed, read as `ShipDateChange.closed`.
//
// This is NOT the order's own `delivery_date` (what the rep promised the
// customer) or `custom_original_delivery_date` (the header's own "it moved"
// marker, in `order_detail_screen.dart` as `_deliveryMoved` - unwired to
// anything that writes it today, see the note where it is read). Rolling
// Hi-Tech's per-item date up into that header field would need a rule for
// which of several lines' dates wins, and `delivery_date` already drives
// pick-list timing - a decision for the user, not inferred here.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const String kShipDateField = 'custom_sap_ship_date';

class ShipDateChange {
  final String lineId;
  final String itemName;
  final String from;
  final String to;

  const ShipDateChange({
    required this.lineId,
    required this.itemName,
    required this.from,
    required this.to,
  });

  /// True once the line has closed in SAP and nothing can move it again.
  bool get closed => to.isEmpty;
}

/// Line id -> the date this device last showed, '' for none.
typedef ShipDateSnapshot = Map<String, String>;

/// Frappe returns an unset Date field as null, '' or the string 'null'.
String _date(dynamic v) {
  final s = (v == null ? '' : '$v').trim();
  if (s == 'null' || s == 'undefined' || s.isEmpty) return '';
  // A Date field can come back with a time portion; only the date is ever
  // shown or compared.
  return s.length >= 10 ? s.substring(0, 10) : s;
}

String _key(Map<String, dynamic> row) => '${row['name'] ?? ''}';

/// What this device is showing now, to be remembered until the next look.
ShipDateSnapshot shipDateSnapshotOf(List<Map<String, dynamic>> lines) {
  final out = <String, String>{};
  for (final l in lines) {
    final id = _key(l);
    if (id.isEmpty) continue;
    out[id] = _date(l[kShipDateField]);
  }
  return out;
}

/// What moved since the snapshot was taken.
///
/// A `previous` of null — an order this device has never opened — reports
/// nothing, the same reasoning as `stage_watch.dart`'s `changesSince`: the
/// first look establishes the baseline, it does not generate the news.
/// Lines added or removed since are not reported either.
List<ShipDateChange> shipDateChangesSince(
  ShipDateSnapshot? previous,
  List<Map<String, dynamic>> lines,
) {
  if (previous == null) return const [];
  final out = <ShipDateChange>[];
  for (final l in lines) {
    final id = _key(l);
    final before = previous[id];
    if (id.isEmpty || before == null) continue;
    final now = _date(l[kShipDateField]);
    if (now == before) continue;
    out.add(ShipDateChange(
      lineId: id,
      itemName: '${l['item_name'] ?? l['item_code'] ?? id}',
      from: before,
      to: now,
    ));
  }
  return out;
}

/// "174 MLG 105 (PLATINUM): still editable in SAP, now 2026-11-20" /
/// "...: SAP moved the delivery date to 2026-11-18 (was 2026-11-20)" /
/// "...: closed in SAP — the delivery date cannot move again"
String describeShipDateChange(ShipDateChange c) {
  if (c.closed) {
    return '${c.itemName}: closed in SAP — the delivery date cannot move '
        'again';
  }
  if (c.from.isEmpty) {
    return '${c.itemName}: still editable in SAP, now ${c.to}';
  }
  return '${c.itemName}: SAP moved the delivery date to ${c.to} '
      '(was ${c.from})';
}

/// Per device, per order — deliberately not synced, for the same reason as
/// `StageSeen`: it is a record of what *this* reader has been shown.
class ShipDateSeen {
  static const _prefix = 'shipDateSeen1:';

  static Future<ShipDateSnapshot?> load(String orderName) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('$_prefix$orderName');
      if (raw == null) return null;
      return (json.decode(raw) as Map).map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      // A corrupt or unreadable entry must not take the order screen down.
      // The worst case is the change shows once more.
      return null;
    }
  }

  static Future<void> save(String orderName, ShipDateSnapshot snapshot) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('$_prefix$orderName', json.encode(snapshot));
    } catch (_) {
      /* nothing to do */
    }
  }
}
