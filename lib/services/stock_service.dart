// Booking minimum stock from the app, with no server script to lean on.
//
// WHAT WE LOST, AND WHAT REPLACES IT
//
// The safe way to do this is a row lock inside a Server Script: read the pool,
// count what is booked, write the booking, all inside one locked transaction.
// The site's plan no longer allows server scripts, so that is not available.
//
// The naive replacement — read availability, then write a booking — has a real
// race in it. Two reps both read "3 rolls left" and both write a booking for 3.
// Nothing rejects either one, and the warehouse is short.
//
// What closes that race without a script is Frappe's own optimistic
// concurrency. Every document carries a `modified` timestamp, and a save that
// sends a stale one is refused by the framework with a timestamp mismatch — the
// same check that produces "Document has been modified after you have opened
// it" in Desk. So the booked total is kept as a running counter *on the pool
// document*, and every booking is a compare-and-swap:
//
//   1. read the pool, keeping the `modified` we saw
//   2. refuse locally if there is not enough headroom
//   3. write the new total back, sending that same `modified`
//   4. if the server refuses it, someone else got in first — re-read and retry
//
// Two reps racing for the last three rolls now resolve to exactly one winner:
// the loser's write is refused, it re-reads, sees no headroom, and fails
// cleanly. That is the property that actually matters, and it holds.
//
// WHAT IS WEAKER THAN THE SCRIPT WAS
//
// The rule now lives in the client, so it binds the app and nothing else.
// Somebody editing `custom_reserved_qty` by hand in Desk, or a future
// integration writing reservations directly, is not checked by anything. With
// the server script it was impossible to bypass; now it is merely impossible to
// get wrong by accident. Worth knowing before someone edits the pool in Desk
// while reps are out selling.

import 'package:dio/dio.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/services/offline_cache.dart';

const String kPoolDoctype = 'Manna Minimum Stock Item';
const String kBatchDoctype = 'Manna Minimum Stock Batch';
const String kReservationDoctype = 'Manna Stock Reservation';

// Cache keys for the three reads behind [StockService.load].
//
// Only reads are cached, and only for display. Booking still goes to the
// server every time — the compare-and-swap is what protects the pool, and a
// cached headroom figure could not be allowed to authorise anything. A rep
// offline can see what the minimum stock was at the last sync; they cannot
// take any of it until they have signal.
const String kStockPoolsKey = 'minstock:pools';
const String kStockBatchesKey = 'minstock:batches';
const String kStockBookingsKey = 'minstock:bookings';

String _res(String doctype) =>
    '/api/resource/${Uri.encodeComponent(doctype)}';

/// Raised when the pool genuinely cannot cover what was asked for — as opposed
/// to a transient collision, which is retried rather than surfaced.
class StockUnavailable implements Exception {
  final String message;
  StockUnavailable(this.message);
  @override
  String toString() => message;
}

class StockService {
  /// How many times a booking will re-read and retry after losing a race.
  /// Collisions are rare and resolve in one attempt; the cap only exists so a
  /// pathological case cannot spin forever.
  static const int _maxAttempts = 4;

  // ------------------------------------------------------------- reading ---

  /// Everything the order screen needs: pool sizes, what is booked, and the
  /// dated batches behind each one.
  ///
  /// `my_reserved` is answered from this rep's own Active reservations, so a
  /// rep editing their own order is not shown their own booking as somebody
  /// else's competition.
  static Future<Map<String, MinStock>> load() async {
    final results = await Future.wait([
      _cached(
          kStockPoolsKey,
          () => _list(kPoolDoctype,
              fields: '["item_code","qty","loose_belts","custom_reserved_qty",'
                  '"custom_reserved_loose_belts","custom_last_sold_on"]',
              filters: '[["disabled","=",0]]')),
      _cached(
          kStockBatchesKey,
          () => _list(kBatchDoctype,
              fields:
                  '["name","item_code","batch_date","qty","loose_belts","original_qty"]',
              orderBy: 'batch_date asc')),
      // Every live booking, not just this rep's. "4 booked" tells a rep
      // nothing useful; knowing it is Amjad holding three of them tells them
      // who to ring.
      _cached(
          kStockBookingsKey,
          () => _list(kReservationDoctype,
              fields:
                  '["item_code","qty","loose_belts","sales_person","sales_order"]',
              filters: '[["status","=","Active"]]',
              orderBy: 'creation asc')),
    ]);

    final pools = results[0];
    final batches = results[1];
    final active = results[2];

    final me = Session.I.salesPerson;
    final myQty = <String, double>{};
    final myBelts = <String, int>{};
    final bookings = <String, List<Map<String, dynamic>>>{};
    for (final r in active) {
      final code = '${r['item_code']}';
      (bookings[code] ??= []).add(r);
      if (me != null && '${r['sales_person']}' == me) {
        myQty[code] = (myQty[code] ?? 0) + _num(r['qty']);
        myBelts[code] = (myBelts[code] ?? 0) + _int(r['loose_belts']);
      }
    }

    final byItem = <String, List<Map<String, dynamic>>>{};
    for (final b in batches) {
      if (_num(b['qty']) <= 0 && _int(b['loose_belts']) <= 0) continue;
      final code = '${b['item_code']}';
      // Aged against the server's clock, not the phone's, so a wrong date on a
      // handset cannot make stock look older than it is.
      b['age_days'] = daysSince(b['batch_date']);
      (byItem[code] ??= []).add(b);
    }

    final out = <String, MinStock>{};
    for (final p in pools) {
      final code = '${p['item_code']}';
      out[code] = MinStock.fromJson({
        'item_code': code,
        'minimum_qty': p['qty'],
        'minimum_loose_belts': p['loose_belts'],
        'reserved_qty': p['custom_reserved_qty'],
        'reserved_loose_belts': p['custom_reserved_loose_belts'],
        'my_reserved_qty': myQty[code] ?? 0,
        'my_reserved_loose_belts': myBelts[code] ?? 0,
        'last_sold_on': p['custom_last_sold_on'],
        'bookings': bookings[code] ?? const [],
        'batches': byItem[code] ?? const [],
      });
    }
    return out;
  }

  // ------------------------------------------------------------- booking ---

  /// Books [qty] and [belts] of an item against an order.
  ///
  /// Throws [StockUnavailable] when the pool cannot cover it. Returns the name
  /// of the audit record so the caller can undo it if a later step fails.
  static Future<String> book({
    required String itemCode,
    required double qty,
    required int belts,
    required String salesOrder,
    String? batch,
  }) async {
    if (qty <= 0 && belts <= 0) {
      throw StockUnavailable('A booking needs a quantity.');
    }

    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      final pool = await _pool(itemCode);
      if (pool == null) {
        throw StockUnavailable(
            '$itemCode is not on the minimum stock list, so it cannot be booked.');
      }

      final headroomQty = _num(pool['qty']) - _num(pool['custom_reserved_qty']);
      final headroomBelts =
          _int(pool['loose_belts']) - _int(pool['custom_reserved_loose_belts']);

      if (qty > headroomQty + 0.0001) {
        throw StockUnavailable(
            'Only ${trimQty(headroomQty < 0 ? 0 : headroomQty)} left of '
            '$itemCode — another rep booked the rest.');
      }
      if (belts > headroomBelts) {
        throw StockUnavailable(
            'Only ${headroomBelts < 0 ? 0 : headroomBelts} loose belts left of '
            '$itemCode.');
      }

      final won = await _commit(pool, {
        'custom_reserved_qty': _num(pool['custom_reserved_qty']) + qty,
        'custom_reserved_loose_belts':
            _int(pool['custom_reserved_loose_belts']) + belts,
        'custom_last_sold_on': today(),
      });

      if (won) {
        await _drawDownBatches(itemCode, qty, belts, batch);
        return _audit(
            itemCode: itemCode,
            qty: qty,
            belts: belts,
            salesOrder: salesOrder,
            batch: batch);
      }
      // Lost the race. The loop re-reads, and the headroom check above is what
      // turns a genuine shortage into a clean refusal rather than a retry.
    }

    throw StockUnavailable(
        'Could not book $itemCode — too many reps are ordering it at once. '
        'Try again in a moment.');
  }

  /// Moves an order's bookings to match a new line-up.
  ///
  /// Deliberately not "release everything, then book it again". Releasing first
  /// puts the stock back on offer, and on a busy item another rep can take it
  /// in the gap — a rep who only wanted to change one line would lose the rest
  /// of an order they already had. So each item moves by its difference: book
  /// only what was added, release only what was dropped, and leave the
  /// unchanged majority untouched.
  ///
  /// Increases go first. If one is refused there is nothing to undo yet, and
  /// the order keeps exactly the stock it already held.
  static Future<void> rebook(
      String salesOrder, List<Map<String, dynamic>> wanted) async {
    final held = await _list(kReservationDoctype,
        fields: '["name","item_code","qty","loose_belts","batch"]',
        filters: '[["sales_order","=","$salesOrder"],["status","=","Active"]]');

    final heldQty = <String, double>{};
    final heldBelts = <String, int>{};
    for (final h in held) {
      final code = '${h['item_code']}';
      heldQty[code] = (heldQty[code] ?? 0) + _num(h['qty']);
      heldBelts[code] = (heldBelts[code] ?? 0) + _int(h['loose_belts']);
    }

    final wantQty = <String, double>{};
    final wantBelts = <String, int>{};
    final wantBatch = <String, String?>{};
    for (final w in wanted) {
      final code = '${w['item_code']}';
      wantQty[code] = (wantQty[code] ?? 0) + _num(w['qty']);
      wantBelts[code] = (wantBelts[code] ?? 0) + _int(w['loose_belts']);
      wantBatch[code] = w['batch'] as String?;
    }

    final codes = {...heldQty.keys, ...wantQty.keys};

    for (final code in codes) {
      final dq = (wantQty[code] ?? 0) - (heldQty[code] ?? 0);
      final db = (wantBelts[code] ?? 0) - (heldBelts[code] ?? 0);
      if (dq > 0.0001 || db > 0) {
        await book(
          itemCode: code,
          qty: dq > 0 ? dq : 0,
          belts: db > 0 ? db : 0,
          salesOrder: salesOrder,
          batch: wantBatch[code],
        );
      }
    }

    for (final code in codes) {
      final dq = (heldQty[code] ?? 0) - (wantQty[code] ?? 0);
      final db = (heldBelts[code] ?? 0) - (wantBelts[code] ?? 0);
      if (dq > 0.0001 || db > 0) {
        await _giveBack(
            code, dq > 0 ? dq : 0, db > 0 ? db : 0, salesOrder);
      }
    }
  }

  /// Returns part of what an order is holding without touching the rest of it.
  static Future<void> _giveBack(
      String itemCode, double qty, int belts, String salesOrder) async {
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      final pool = await _pool(itemCode);
      if (pool == null) return;
      var back = _num(pool['custom_reserved_qty']) - qty;
      var backBelts = _int(pool['custom_reserved_loose_belts']) - belts;
      if (back < 0) back = 0;
      if (backBelts < 0) backBelts = 0;
      final won = await _commit(pool, {
        'custom_reserved_qty': back,
        'custom_reserved_loose_belts': backBelts,
      });
      if (won) break;
    }

    await _restoreBatch(itemCode, qty, belts, null);

    // Shrink the audit rows for this item so they still add up to what is
    // actually held. Oldest first, so the batch a rep deliberately chose on the
    // most recent booking is the last thing to be given back.
    var remaining = qty;
    var remainingBelts = belts;
    final rows = await _list(kReservationDoctype,
        fields: '["name","qty","loose_belts"]',
        filters:
            '[["sales_order","=","$salesOrder"],["item_code","=","$itemCode"],'
            '["status","=","Active"]]',
        orderBy: 'creation asc');

    for (final r in rows) {
      if (remaining <= 0.0001 && remainingBelts <= 0) break;
      final haveQty = _num(r['qty']);
      final haveBelts = _int(r['loose_belts']);
      final takeQty = remaining > haveQty ? haveQty : remaining;
      final takeBelts = remainingBelts > haveBelts ? haveBelts : remainingBelts;
      final leftQty = haveQty - takeQty;
      final leftBelts = haveBelts - takeBelts;
      try {
        if (leftQty <= 0.0001 && leftBelts <= 0) {
          await Session.I.dio.put('${_res(kReservationDoctype)}/${r['name']}',
              data: {'status': 'Released', 'qty': 0, 'loose_belts': 0});
        } else {
          await Session.I.dio.put('${_res(kReservationDoctype)}/${r['name']}',
              data: {'qty': leftQty, 'loose_belts': leftBelts});
        }
      } catch (_) {}
      remaining -= takeQty;
      remainingBelts -= takeBelts;
    }
  }

  /// Hands an order's bookings back to the pool.
  ///
  /// Stock held against an order that died is stock nobody can sell, and
  /// nothing in the field will notice it is stranded — the rep who booked it
  /// has moved on to the next shop. So this is deliberately forgiving: it
  /// releases what it can and never throws.
  static Future<int> release(String salesOrder) async {
    List<Map<String, dynamic>> held;
    try {
      held = await _list(kReservationDoctype,
          fields: '["name","item_code","qty","loose_belts","batch"]',
          filters:
              '[["sales_order","=","$salesOrder"],["status","=","Active"]]');
    } catch (_) {
      return 0;
    }

    var released = 0;
    for (final r in held) {
      final code = '${r['item_code']}';
      final qty = _num(r['qty']);
      final belts = _int(r['loose_belts']);

      for (var attempt = 0; attempt < _maxAttempts; attempt++) {
        final pool = await _pool(code);
        if (pool == null) break;
        var back = _num(pool['custom_reserved_qty']) - qty;
        var backBelts = _int(pool['custom_reserved_loose_belts']) - belts;
        if (back < 0) back = 0;
        if (backBelts < 0) backBelts = 0;
        final won = await _commit(pool, {
          'custom_reserved_qty': back,
          'custom_reserved_loose_belts': backBelts,
        });
        if (won) break;
      }

      await _restoreBatch(code, qty, belts, r['batch'] as String?);
      // Released rather than deleted, so a stranded booking leaves a trail.
      try {
        await Session.I.dio.put('${_res(kReservationDoctype)}/${r['name']}',
            data: {'status': 'Released'});
        released++;
      } catch (_) {}
    }
    return released;
  }

  // ----------------------------------------------------------- internals ---

  static Future<Map<String, dynamic>?> _pool(String itemCode) async {
    try {
      final r = await Session.I.dio
          .get('${_res(kPoolDoctype)}/${Uri.encodeComponent(itemCode)}');
      final d = (r.data is Map) ? r.data['data'] : null;
      if (d is Map<String, dynamic> && (d['disabled'] ?? 0) != 1) return d;
    } catch (_) {}
    return null;
  }

  /// The compare-and-swap itself. Sending the `modified` we read is what makes
  /// this conditional — without it the write would clobber whatever landed in
  /// between. Returns false when the server refused because the document moved.
  static Future<bool> _commit(
      Map<String, dynamic> pool, Map<String, dynamic> changes) async {
    try {
      final r = await Session.I.dio.put(
        '${_res(kPoolDoctype)}/${Uri.encodeComponent('${pool['name']}')}',
        data: {'modified': pool['modified'], ...changes},
      );
      final sc = r.statusCode ?? 0;
      if (sc >= 200 && sc < 300) return true;
      if (_isConflict(sc, r.data)) return false;
      throw StockUnavailable(_errorText(r.data));
    } on DioException catch (e) {
      if (_isConflict(e.response?.statusCode ?? 0, e.response?.data)) {
        return false;
      }
      rethrow;
    }
  }

  /// Frappe raises a timestamp mismatch as a validation error, which surfaces
  /// as 409 or 417 depending on version. The message is checked too, because
  /// either status can also mean something unrelated.
  static bool _isConflict(int status, dynamic body) {
    if (status == 409) return true;
    final text = '$body'.toLowerCase();
    return text.contains('timestampmismatch') ||
        text.contains('please refresh') ||
        text.contains('has been modified');
  }

  static String _errorText(dynamic body) {
    final m = (body is Map) ? body['exception'] ?? body['message'] : null;
    return (m ?? 'Could not update minimum stock.').toString();
  }

  static Future<String> _audit({
    required String itemCode,
    required double qty,
    required int belts,
    required String salesOrder,
    String? batch,
  }) async {
    final r = await Session.I.dio.post(_res(kReservationDoctype), data: {
      'item_code': itemCode,
      'qty': qty,
      'loose_belts': belts,
      'sales_order': salesOrder,
      'sales_person': Session.I.salesPerson,
      'status': 'Active',
      'reserved_on': nowStamp(),
      if (batch != null) 'batch': batch,
    });
    final d = (r.data is Map) ? r.data['data'] : null;
    return (d is Map && d['name'] is String) ? d['name'] as String : '';
  }

  /// Oldest batch first, so the stock that has been sitting longest is the
  /// stock that leaves. Best-effort by design: the pool counter is what
  /// guarantees the customer gets served, and a batch list that has drifted is
  /// a reporting problem, not a reason to refuse an order at the counter.
  static Future<void> _drawDownBatches(
      String itemCode, double qty, int belts, String? preferred) async {
    try {
      final batches = await _list(kBatchDoctype,
          fields: '["name","qty","loose_belts"]',
          filters: '[["item_code","=","$itemCode"]]',
          orderBy: 'batch_date asc');
      if (preferred != null) {
        batches.sort((a, b) => a['name'] == preferred
            ? -1
            : (b['name'] == preferred ? 1 : 0));
      }
      var remainingQty = qty;
      var remainingBelts = belts;
      for (final b in batches) {
        if (remainingQty <= 0.0001 && remainingBelts <= 0) break;
        final haveQty = _num(b['qty']);
        final haveBelts = _int(b['loose_belts']);
        final takeQty = remainingQty > haveQty ? haveQty : remainingQty;
        final takeBelts = remainingBelts > haveBelts ? haveBelts : remainingBelts;
        if (takeQty <= 0 && takeBelts <= 0) continue;
        await Session.I.dio.put('${_res(kBatchDoctype)}/${b['name']}', data: {
          'qty': haveQty - takeQty,
          'loose_belts': haveBelts - takeBelts,
        });
        remainingQty -= takeQty;
        remainingBelts -= takeBelts;
      }
    } catch (_) {}
  }

  /// Puts a released quantity back where it came from when we know, and onto
  /// the oldest open batch when we do not — which keeps the aging order intact
  /// instead of quietly making returned stock look new.
  static Future<void> _restoreBatch(
      String itemCode, double qty, int belts, String? batch) async {
    try {
      var target = batch;
      if (target == null) {
        final oldest = await _list(kBatchDoctype,
            fields: '["name"]',
            filters: '[["item_code","=","$itemCode"]]',
            orderBy: 'batch_date asc',
            limit: 1);
        if (oldest.isEmpty) return;
        target = '${oldest.first['name']}';
      }
      final r = await Session.I.dio.get('${_res(kBatchDoctype)}/$target');
      final d = (r.data is Map) ? r.data['data'] : null;
      if (d is! Map) return;
      await Session.I.dio.put('${_res(kBatchDoctype)}/$target', data: {
        'qty': _num(d['qty']) + qty,
        'loose_belts': _int(d['loose_belts']) + belts,
      });
    } catch (_) {}
  }

  /// A read that falls back to the last sync when the network is down.
  ///
  /// Used only by [load]. The booking path deliberately does not go through
  /// here: `book` re-reads the pool live every attempt, because a stale
  /// `modified` is exactly what the compare-and-swap exists to reject.
  static Future<List<Map<String, dynamic>>> _cached(
          String key, Future<List<Map<String, dynamic>>> Function() fetch) =>
      OfflineCache.read<List<Map<String, dynamic>>>(key, fetch,
              decode: decodeRows)
          .then((c) => c.value);

  static Future<List<Map<String, dynamic>>> _list(String doctype,
      {required String fields,
      String? filters,
      String orderBy = 'modified desc',
      int limit = 0}) async {
    final qp = <String, dynamic>{
      'fields': fields,
      'order_by': orderBy,
      'limit_page_length': limit,
    };
    if (filters != null) qp['filters'] = filters;
    final r = await Session.I.dio.get(_res(doctype), queryParameters: qp);
    final data = (r.data is Map) ? r.data['data'] : null;
    if (data is List) return data.cast<Map<String, dynamic>>();
    return [];
  }
}

double _num(dynamic v) =>
    v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

int _int(dynamic v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);
