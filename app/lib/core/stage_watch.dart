// What a rep or sales manager is told when production moves an item.
//
// Paired with `client/src/domain/stageWatch.ts`. Both read
// `shared/fixtures/stage_watch.json` in their tests. See `shared/README.md`.
//
// Why a stored diff rather than a push. Two things rule out anything else on
// this site today:
//
//   - there are no Server Scripts, so nothing can fire when production saves a
//     stage;
//   - `Notification Log` — Frappe's own per-user notification store, which is
//     otherwise exactly right — grants role `All` read but NOT create. A rep's
//     or production manager's login cannot write one over the API. (The web
//     dashboard has been writing to a `Sales Notification` doctype that does
//     not exist on this site, fire-and-forget, so every notification it has
//     ever raised has silently gone nowhere.)
//
// So each device remembers the stages it last showed for an order, and the
// difference is the news. It is honest — it can only ever report a real change
// between two things the reader saw — and it needs no schema, no permission
// change and no server support. What it cannot do is buzz a phone that never
// opens the order; see `shared/DIVERGENCES.md` item 7 for what that would take.
//
// A split line has two stages that finish separately, so each is watched on its
// own axis. Reporting "this line moved" would hide that the other half has not.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const String kStageFieldMade = 'custom_production_stage';
const String kStageFieldShelf = 'custom_stock_stage';

/// Which half of a line moved.
enum StagePart { made, shelf }

/// Line id -> `"<made>|<shelf>"`. Flat so it stores as one string.
typedef StageSnapshot = Map<String, String>;

class StageChange {
  final String lineId;
  final String itemName;
  final StagePart part;
  final String from;
  final String to;

  const StageChange({
    required this.lineId,
    required this.itemName,
    required this.part,
    required this.from,
    required this.to,
  });
}

/// Frappe returns an unset Data field as null, '' or the string 'null'.
String _stage(dynamic v) {
  final s = (v == null ? '' : '$v').trim();
  return (s == 'null' || s == 'undefined') ? '' : s;
}

String _key(Map<String, dynamic> row) => '${row['name'] ?? ''}';

/// What this device is showing now, to be remembered until the next look.
StageSnapshot snapshotOf(List<Map<String, dynamic>> lines) {
  final out = <String, String>{};
  for (final l in lines) {
    final id = _key(l);
    if (id.isEmpty) continue;
    out[id] = '${_stage(l[kStageFieldMade])}|${_stage(l[kStageFieldShelf])}';
  }
  return out;
}

/// What moved since the snapshot was taken.
///
/// A `previous` of null — an order this device has never opened — reports
/// nothing. A rep opening a month-old order must not be shown fifty changes
/// they have known about for weeks; the first look establishes the baseline,
/// it does not generate the news.
///
/// Lines added or removed since are not stage changes and are not reported. A
/// stage going backwards is, and deliberately: production correcting itself is
/// the change a rep most needs, because they may already have promised a date.
List<StageChange> changesSince(
  StageSnapshot? previous,
  List<Map<String, dynamic>> lines,
) {
  if (previous == null) return const [];
  final out = <StageChange>[];

  for (final l in lines) {
    final id = _key(l);
    final before = previous[id];
    // Not seen last time: a new line, not a change to an old one.
    if (id.isEmpty || before == null) continue;

    final parts = before.split('|');
    final madeBefore = parts.isNotEmpty ? parts[0] : '';
    final shelfBefore = parts.length > 1 ? parts[1] : '';
    final madeNow = _stage(l[kStageFieldMade]);
    final shelfNow = _stage(l[kStageFieldShelf]);
    final itemName = '${l['item_name'] ?? l['item_code'] ?? id}';

    if (madeNow != madeBefore) {
      out.add(StageChange(
          lineId: id,
          itemName: itemName,
          part: StagePart.made,
          from: madeBefore,
          to: madeNow));
    }
    if (shelfNow != shelfBefore) {
      out.add(StageChange(
          lineId: id,
          itemName: itemName,
          part: StagePart.shelf,
          from: shelfBefore,
          to: shelfNow));
    }
  }
  return out;
}

/// Which line ids moved, for highlighting the rows that did.
Set<String> changedLineIds(List<StageChange> changes) =>
    changes.map((c) => c.lineId).toSet();

/// "the part being made" / "the part off the shelf" — never just "the line".
String partLabel(StagePart part) =>
    part == StagePart.made ? 'being made' : 'from stock';

/// "Not started" reads better than a blank for a stage nobody has set.
String stageText(String s) => s.trim().isEmpty ? 'Not started' : s;

/// "160 SR 99 (being made): Cutting -> Curing"
String describeChange(StageChange c) =>
    '${c.itemName} (${partLabel(c.part)}): '
    '${stageText(c.from)} → ${stageText(c.to)}';

// ------------------------------------------------------------- storage ---

/// Per device, per order. Deliberately not synced: it is a record of what
/// *this* reader has been shown, and sharing it would mean a manager's laptop
/// silently marking a rep's phone as caught up.
///
/// Uses SharedPreferences directly rather than OfflineCache, which expires
/// after seven days — a baseline that expires would replay every stage as news
/// on any order a rep has not opened in a week.
class StageSeen {
  static const _prefix = 'stageSeen:';

  static Future<StageSnapshot?> load(String orderName) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('$_prefix$orderName');
      if (raw == null) return null;
      return (json.decode(raw) as Map).map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      // A corrupt or unreadable entry must not take the order screen down.
      // The worst case is the changes show once more.
      return null;
    }
  }

  static Future<void> save(String orderName, StageSnapshot snapshot) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('$_prefix$orderName', json.encode(snapshot));
    } catch (_) {
      /* nothing to do */
    }
  }
}
