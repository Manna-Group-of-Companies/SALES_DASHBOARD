// Rules for `Manna Production Order` — the two flows in
// `shared/PRODUCTION_FLOWS.md`.
//
// Paired with `client/src/domain/productionOrders.ts`. Both read
// `shared/fixtures/production_order.json` in their tests. See
// `shared/README.md`.

import 'package:manna_field_sales/core/constants.dart';

/// Frappe returns an unset Data field as null, '' or the string 'null'.
String _clean(dynamic v) {
  final s = '${v ?? ''}'.trim();
  return (s.isEmpty || s == 'null' || s == 'undefined') ? '' : s;
}

/// Whether an order line's production needs diverting to company stock — the
/// one join between the two flows. Cancelling a Sales Order after its goods
/// were made leaves rubber nobody is waiting for; this decides which lines
/// that is true for.
///
/// All three have to hold:
///   - the order is actually cancelled (`docstatus == 2`), separate from
///     `custom_sales_status` — a rejected-before-approval order was never
///     produced and is not this;
///   - the line was being made for THIS customer (`custom_fulfilment_mode` is
///     `New Production`) — a line served from the shelf or claimed off a
///     replenishment run belongs to a pool already, and cancelling the order
///     just releases the claim rather than diverting anything;
///   - work had actually started (`custom_production_stage` is set) — a line
///     still unstarted when the order was cancelled was never produced, and
///     diverting it would put a batch of goods nobody made onto the shelf.
bool needsStockDiversion(Map<String, dynamic> line) {
  final docstatus = line['docstatus'] is num
      ? (line['docstatus'] as num).toInt()
      : int.tryParse('${line['docstatus'] ?? ''}') ?? 0;
  final mode = _clean(line['custom_fulfilment_mode']);
  final started = _clean(line['custom_production_stage']).isNotEmpty;
  return docstatus == 2 && mode == kFulfilNewProduction && started;
}

/// One production order, reduced to what [alreadyDiverted] needs to check.
class DivertLookup {
  final String? salesOrderId;
  final String itemCode;
  final String purpose;

  DivertLookup({this.salesOrderId, required this.itemCode, required this.purpose});
}

/// Already diverted — a `Manna Production Order` already exists for this
/// order/item pair. Diverting is a one-time act; without this check, opening
/// the same cancelled order twice would raise a second production order and a
/// second batch for goods that only exist once.
bool alreadyDiverted(
  String salesOrderId,
  String itemCode,
  List<DivertLookup> productionOrders,
) {
  return productionOrders.any((o) =>
      o.purpose == 'order' &&
      o.salesOrderId == salesOrderId &&
      o.itemCode == itemCode);
}
