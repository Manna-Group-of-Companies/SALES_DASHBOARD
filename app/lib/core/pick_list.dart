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
// Lists are not approved (7 Nov 2026): the sync sends each one to SAP as made,
// and a product counts as picked once SAP's delivery for its list is back.

double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

/// How many days before an order's delivery date its pick list opens
/// (13 Nov 2026, the user: picking only in the last two days before delivery,
/// locked on every day before that). Pinned by
/// shared/fixtures/pick_list_window.json; manna_pick_list_submit refuses an
/// early list with the same number.
const int kPickOpensDaysBefore = 2;

/// The day [deliveryDate] (`yyyy-MM-dd…`, as ERPNext sends it) opens for
/// picking: two days before it. Null when there is no readable date - such an
/// order is not held back, because a lock nobody can see the end of would
/// strand it; every order the phone takes carries a delivery date.
DateTime? pickOpensOn(Object? deliveryDate) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch('${deliveryDate ?? ''}'.trim());
  if (m == null) return null;
  final d = DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  return DateTime(d.year, d.month, d.day - kPickOpensDaysBefore);
}

/// Whether an order delivering on [deliveryDate] may be picked on [today].
/// Open from [pickOpensOn] onwards, and after the delivery date too.
bool pickIsOpen(Object? deliveryDate, DateTime today) {
  final opens = pickOpensOn(deliveryDate);
  if (opens == null) return true;
  return !DateTime(today.year, today.month, today.day).isBefore(opens);
}

/// The first `yyyy-MM-dd` in [v], or '' - ERPNext sends dates, datetimes, null
/// and the string 'null'.
String _ymd(Object? v) {
  final m = RegExp(r'^\d{4}-\d{2}-\d{2}').firstMatch('${v ?? ''}'.trim());
  return m == null ? '' : m[0]!;
}

/// Whether an order placed on [orderDate] belongs on the pick list at all
/// (13 Nov 2026, the user: when the app goes live, pick lists start with the
/// new orders; the old ones are never shown). [since] is
/// `Manna App Settings.pick_lists_since`. No date set means every order, as
/// before. An order whose date cannot be read is left off once a date is set:
/// it cannot be shown to be new. manna_pick_list_submit refuses the same
/// orders; shared/fixtures/pick_list_window.json pins both.
bool pickListIncludes(Object? orderDate, Object? since) {
  final s = _ymd(since);
  if (s.isEmpty) return true;
  final d = _ymd(orderDate);
  return d.isNotEmpty && d.compareTo(s) >= 0;
}

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
// kilos on this list, the moment it reaches SAP. Nobody types them (decided
// 5 Nov 2026): rolls become kilos by the weight per roll, as the order did.
//
// The weight per roll is the ORDER's - its kilos over its rolls - not today's
// item master: the order was priced and sent to SAP at that figure, and a list
// over the order line's kilos is refused by SAP ("Released quantity exceeds
// open quantity", TEST, 5 Nov 2026). SAL-ORD-2026-00167 is 2 rolls at 48.4 kg
// while its item says 25 kg a roll; 2 x 25 would be refused. Only a line that
// also carries loose belts, whose kilos are not all rolls, falls back to the
// item's weight per roll. The last rolls of a line take exactly the kilos
// left, so rounding never leaves a crumb open on the order.
//
// A line counted in kilos already (bonding gum) takes its picked qty.

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

/// What one roll on [line] weighs: the order's own figure, else (a line with
/// loose belts) [itemWeightPerRoll], the item's `custom_weight_per_roll`.
/// 0 when neither is known - the list is then refused, never guessed.
double kgPerRoll(Map line, {double itemWeightPerRoll = 0}) {
  final rolls = _int(line['custom_rolls']);
  if (rolls <= 0) return 0;
  final total = _num(line['custom_total_weight']);
  if (_int(line['custom_loose_belts']) == 0 && total > 0) return total / rolls;
  return itemWeightPerRoll > 0 ? itemWeightPerRoll : 0;
}

/// The kilos [picked] puts on the list for [line]: rolls x [kgPerRoll], or
/// the picked qty on a kilo line. The rolls that finish a line without loose
/// belts take exactly what is left of its kilos.
double pickKg(Map line, double picked,
    {double alreadyPicked = 0, double alreadyKg = 0, double itemWeightPerRoll = 0}) {
  if (picked <= 0) return 0;
  if (kgFollowsQty(line)) return _r3(picked);
  final perRoll = kgPerRoll(line, itemWeightPerRoll: itemWeightPerRoll);
  if (perRoll <= 0) return 0;
  final finishes = _int(line['custom_loose_belts']) == 0 &&
      (picked - remainingToPick(line, alreadyPicked)).abs() < 1e-9;
  if (finishes) return remainingKg(line, alreadyKg);
  return _r3(picked * perRoll);
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
