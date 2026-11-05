// Pick lists: which products of an approved order go from Hi-Tech's stock now.
//
// Asked for on 3 Nov 2026. An order of ten products with five in Hi-Tech's
// stock is picked five now and the rest later, on another list; the sales
// manager sees every list for their team. Only manager-approved orders, only
// products on that order.
//
// This file holds the quantity rule; shared/fixtures/pick_list.json pins it.
// The `manna_pick_list_submit` Server Script (app/server/pick_list_submit.py)
// applies the same ordered/remaining rule again and refuses any product that
// is not on the order, so a phone cannot talk its way round it.

double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

/// What was ordered on [line], in the unit Hi-Tech's stock is shown in:
/// whole rolls for tread rubber, else the line's qty (kg, cans). Loose belts
/// ride on qty as part of a roll and are not picked, so a belts-only line is 0.
double orderedForPick(Map line) {
  final rolls = _int(line['custom_rolls']);
  if (rolls > 0) return rolls.toDouble();
  if (_int(line['custom_loose_belts']) > 0) return 0;
  return _num(line['qty']);
}

/// The unit [orderedForPick] counts in. Tread rubber's `stock_uom` is `Kg`
/// while its qty is rolls, so the unit cannot be read off the line's UOM.
String pickUnit(Map line) {
  if (_int(line['custom_rolls']) > 0) return 'rolls';
  final u = '${line['stock_uom'] ?? line['uom'] ?? ''}'.trim();
  return u == 'null' ? '' : u;
}

/// Ordered less what earlier Submitted lists already took. Never below zero.
double remainingToPick(Map line, double alreadyPicked) {
  final r = orderedForPick(line) - alreadyPicked;
  return r > 0 ? r : 0;
}

/// The most that may go on this list: the smaller of what is left on the
/// order and what Hi-Tech has.
double maxPick(Map line, {required double alreadyPicked, required double available}) {
  final r = remainingToPick(line, alreadyPicked);
  final a = available > 0 ? available : 0.0;
  return r < a ? r : a;
}

// ---- Kilos (5 Nov 2026) ----
//
// SAP counts every line in kilos: Hi-Tech's pick list, its invoice to Manna
// Treads, Manna Treads' goods receipt and its delivery are all made from the
// kilos on this list, the moment it reaches SAP. A roll is weighed, so the rep
// types the kilos; a line counted in kilos already (bonding gum) uses its qty.
// No more than the order has left: SAP refuses a pick list line released for
// more than its sales order line still has open ("Released quantity exceeds
// open quantity", TEST, 5 Nov 2026), so a roll weighed heavier than the
// order's estimate cannot go over it - the order's kilos must be right first.

/// How far over the order's remaining kilos a list may go: not at all, above.
const double kKgTolerance = 0;

double _r3(double v) => (v * 1000).roundToDouble() / 1000;

/// Whether the line's picked quantity already is its kilos.
bool kgFollowsQty(Map line) {
  if (_int(line['custom_rolls']) > 0) return false;
  final u = pickUnit(line).toLowerCase();
  return u == 'kg' || u == 'kgs';
}

/// The kilos ordered on [line]: its total weight, else its qty when that is kg.
double orderedKg(Map line) {
  final w = _num(line['custom_total_weight']);
  if (w > 0) return w;
  return kgFollowsQty(line) ? _num(line['qty']) : 0;
}

/// Ordered kilos less what earlier Submitted lists took. Never below zero.
double remainingKg(Map line, double alreadyKg) {
  final r = orderedKg(line) - alreadyKg;
  return r > 0 ? _r3(r) : 0;
}

/// The most kilos this list may carry for [line].
double maxPickKg(Map line, {required double alreadyKg}) =>
    _r3(remainingKg(line, alreadyKg) * (1 + kKgTolerance));

/// One product on a pick list.
class PickListItem {
  final String salesOrderItem;
  final String itemCode;
  final String itemName;
  final String unit;
  final double orderedQty;
  final double availableQty;
  final double pickedQty;
  final double pickedKg;

  const PickListItem({
    required this.salesOrderItem,
    required this.itemCode,
    required this.itemName,
    required this.unit,
    required this.orderedQty,
    required this.availableQty,
    required this.pickedQty,
    this.pickedKg = 0,
  });

  factory PickListItem.fromJson(Map m) => PickListItem(
        salesOrderItem: '${m['sales_order_item'] ?? ''}',
        itemCode: '${m['item_code'] ?? ''}',
        itemName: '${m['item_name'] ?? ''}',
        unit: '${m['unit'] ?? ''}',
        orderedQty: _num(m['ordered_qty']),
        availableQty: _num(m['available_qty']),
        pickedQty: _num(m['picked_qty']),
        pickedKg: _num(m['picked_kg']),
      );
}

/// A submitted pick list, as `manna_pick_lists` returns it.
class PickList {
  final String name;
  final String salesOrder;
  final String customerName;
  final String salesPerson;
  final String status;
  final String pickedOn;
  final List<PickListItem> items;

  /// SAP's side (5 Nov 2026), empty until the sync and B1if have made it.
  final String sapPickList;
  final String hitechInvoice;
  final String mtGoodsReceipt;
  final String mtDelivery;
  final String sapError;

  const PickList({
    required this.name,
    required this.salesOrder,
    required this.customerName,
    required this.salesPerson,
    required this.status,
    required this.pickedOn,
    required this.items,
    this.sapPickList = '',
    this.hitechInvoice = '',
    this.mtGoodsReceipt = '',
    this.mtDelivery = '',
    this.sapError = '',
  });

  factory PickList.fromJson(Map m) => PickList(
        name: '${m['name'] ?? ''}',
        salesOrder: '${m['sales_order'] ?? ''}',
        customerName: '${m['customer_name'] ?? m['customer'] ?? ''}',
        salesPerson: '${m['sales_person'] ?? ''}',
        status: '${m['status'] ?? 'Submitted'}',
        pickedOn: '${m['picked_on'] ?? ''}',
        items: ((m['items'] as List?) ?? const [])
            .whereType<Map>()
            .map(PickListItem.fromJson)
            .toList(),
        sapPickList: '${m['sap_pick_list'] ?? ''}',
        hitechInvoice: '${m['hitech_invoice'] ?? ''}',
        mtGoodsReceipt: '${m['mt_goods_receipt'] ?? ''}',
        mtDelivery: '${m['mt_delivery'] ?? ''}',
        sapError: '${m['sap_sync_error'] ?? ''}',
      );

  bool get isSubmitted => status == 'Submitted';
}

/// What Submitted lists already took, per `Sales Order Item` name.
Map<String, double> pickedSoFar(Iterable<PickList> lists) {
  final out = <String, double>{};
  for (final l in lists) {
    if (!l.isSubmitted) continue;
    for (final i in l.items) {
      out[i.salesOrderItem] = (out[i.salesOrderItem] ?? 0) + i.pickedQty;
    }
  }
  return out;
}

/// The kilos Submitted lists already took, per `Sales Order Item` name.
Map<String, double> pickedKgSoFar(Iterable<PickList> lists) {
  final out = <String, double>{};
  for (final l in lists) {
    if (!l.isSubmitted) continue;
    for (final i in l.items) {
      out[i.salesOrderItem] = (out[i.salesOrderItem] ?? 0) + i.pickedKg;
    }
  }
  return out;
}
