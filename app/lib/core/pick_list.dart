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
//
// Since 5 Nov 2026 a production manager approves each list on the dashboard
// (the `manna_pick_list_approve` Server Script); the phone only shows it.

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

/// One product on a pick list.
class PickListItem {
  final String salesOrderItem;
  final String itemCode;
  final String itemName;
  final String unit;
  final double orderedQty;
  final double availableQty;
  final double pickedQty;

  const PickListItem({
    required this.salesOrderItem,
    required this.itemCode,
    required this.itemName,
    required this.unit,
    required this.orderedQty,
    required this.availableQty,
    required this.pickedQty,
  });

  factory PickListItem.fromJson(Map m) => PickListItem(
        salesOrderItem: '${m['sales_order_item'] ?? ''}',
        itemCode: '${m['item_code'] ?? ''}',
        itemName: '${m['item_name'] ?? ''}',
        unit: '${m['unit'] ?? ''}',
        orderedQty: _num(m['ordered_qty']),
        availableQty: _num(m['available_qty']),
        pickedQty: _num(m['picked_qty']),
      );
}

/// A submitted pick list, as `manna_pick_lists` returns it.
class PickList {
  final String name;
  final String salesOrder;

  /// SAP's order number, once the sync has written it back. Shown instead of
  /// the ERPNext name.
  final String sapSalesOrder;
  final String customerName;
  final String salesPerson;
  final String status;
  final String pickedOn;

  /// `Pending` or `Approved`. A list made before approval existed is Pending.
  final String approvalStatus;
  final String approvedByName;
  final String approvedOn;
  final List<PickListItem> items;

  /// SAP's side: the Hi-Tech pick list the sync sent, and what B1if made from
  /// it. Blank until the sync has done each step.
  final String sapPickList;
  final String hitechInvoice;
  final String mtGoodsReceipt;
  final String mtDelivery;
  final String sapError;

  const PickList({
    required this.name,
    required this.salesOrder,
    this.sapSalesOrder = '',
    required this.customerName,
    required this.salesPerson,
    required this.status,
    required this.pickedOn,
    this.approvalStatus = 'Pending',
    this.approvedByName = '',
    this.approvedOn = '',
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
        sapSalesOrder: '${m['sap_sales_order'] ?? ''}' == 'null'
            ? ''
            : '${m['sap_sales_order'] ?? ''}',
        customerName: '${m['customer_name'] ?? m['customer'] ?? ''}',
        salesPerson: '${m['sales_person'] ?? ''}',
        status: '${m['status'] ?? 'Submitted'}',
        pickedOn: '${m['picked_on'] ?? ''}',
        approvalStatus:
            '${m['approval_status'] ?? ''}' == 'Approved' ? 'Approved' : 'Pending',
        approvedByName:
            '${m['approved_by_name'] ?? m['approved_by'] ?? ''}',
        approvedOn: '${m['approved_on'] ?? ''}',
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

  /// Approved by production. A cancelled list never counts as approved.
  bool get isApproved => isSubmitted && approvalStatus == 'Approved';

  /// SAP has delivered it to the customer: the products on it are picked.
  bool get isDelivered => isSubmitted && mtDelivery.trim().isNotEmpty && mtDelivery != 'null';
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
