// Reading the shelf. There is nothing here that writes.
//
// WHAT USED TO BE HERE
//
// Until 17 September 2026 this file carried the booking protocol: a
// compare-and-swap against `Manna Minimum Stock Item.modified` that let two
// reps race for the last three rolls and resolved to exactly one winner,
// written in the client because the site's plan could not run server scripts.
// It was careful work and it is all gone, because the thing it protected no
// longer exists.
//
// **SAP books the stock now.** A sales order in SAP commits its lines the
// moment it is placed, and `Sync-HitechStockToTreads.ps1` writes back
// *available to promise* — on hand, less everything SAP has committed —
// whenever somebody presses Sync (no timer from 24 Sep 2026). So the number a
// rep sees has already had every other rep's orders taken out of it, including
// orders placed in SAP by people who have never opened this app. An ERPNext reservation on top of that subtracted the
// same roll a second time.
//
// That also settles the race the compare-and-swap existed to win. It is
// decided in SAP, against SAP's own committed quantities, by the sync — not in
// the client, and not by whichever handset had signal first.
//
// WHAT IS WEAKER THAN IT WAS
//
// The window. SAP is authoritative but the app sees it on a five-minute delay,
// so two reps *can* both be shown the same eight rolls inside one sync cycle.
// Nothing here closes that; the order is accepted, pushed to SAP, and SAP
// refuses or short-ships it if the stock has gone. That is a worse experience
// than the old local refusal and a better answer, because the old one was
// confidently wrong about stock it could not see.

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/stock_from_kg.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/services/offline_cache.dart';

const String kStockBinsKey = 'minstock:bins';
const String kStockWeightsKey = 'minstock:weights';

/// Where the SAP finished-goods stock lands. One warehouse, one company.
const String kFgWarehouse = 'Finished Goods - MT';

String _res(String doctype) =>
    '/api/resource/${Uri.encodeComponent(doctype)}';

class StockService {
  // ------------------------------------------------------------- reading ---

  /// What every item has available to promise, keyed by item code.
  ///
  /// Two reads: the warehouse, and the weights that turn its kilograms into
  /// rolls and belts.
  static Future<Map<String, MinStock>> load() async {
    final results = await Future.wait([
      // The warehouse.
      //
      // `Bin.actual_qty` is authoritative and is in KILOS. Do not sum Stock
      // Ledger Entry instead: a Stock Reconciliation writes an ABSOLUTE
      // quantity, so its ledger rows carry actual_qty = 0 and the real number
      // sits in qty_after_transaction.
      //
      // Unfiltered by quantity. An item SAP has run out of has to come back as
      // a zero rather than as an absent row, or a rep is shown nothing at all
      // where they should be shown "none left".
      _cached(
          kStockBinsKey,
          () => _list('Bin',
              fields: '["item_code","actual_qty"]',
              filters: '[["warehouse","=","$kFgWarehouse"]]')),
      // The weights. Every stocked item, including the ones with no weights
      // set — those are reported as nothing available, and that cannot be
      // decided about an item this read never returned.
      _cached(
          kStockWeightsKey,
          () => _list('Item',
              fields: '["name","custom_weight_per_roll","custom_belts_per_roll",'
                  '"custom_avg_weight_per_roll","stock_uom"]',
              filters: '[["is_stock_item","=",1],["disabled","=",0]]')),
    ]);

    final bins = results[0];
    final weights = {for (final i in results[1]) '${i['name']}': i};

    final out = <String, MinStock>{};
    for (final b in bins) {
      final code = '${b['item_code']}';
      final w = weights[code];
      if (w == null) continue;

      final beltsPerRoll = _int(w['custom_belts_per_roll']);
      final conv = stockFromKg(
        kg: _num(b['actual_qty']),
        weightPerRoll: _num(w['custom_weight_per_roll']),
        beltsPerRoll: beltsPerRoll,
        storedWeightPerBelt: _num(w['custom_avg_weight_per_roll']),
        isWeighed: '${w['stock_uom']}' == 'Kg',
      );

      // An item with kilos but no weights reports nothing available, on
      // instruction: the weights are being loaded for the rest of the
      // catalogue, and until they are, nobody can say how many rolls a
      // kilogram is. It appears the moment they arrive.
      out[code] = MinStock.fromJson({
        'item_code': code,
        'available_qty': conv.rolls,
        'available_loose_belts': conv.looseBelts,
        'belts_per_roll': beltsPerRoll,
        'weights_known': conv.known,
      });
    }
    return out;
  }

  /// Drop the cached reads so the next [load] goes to the server.
  static Future<void> invalidate() => OfflineCache.clear();

  /// A read that falls back to the last sync when the network is down.
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
