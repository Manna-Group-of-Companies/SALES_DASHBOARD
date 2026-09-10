// What SAP says about an order, and what the app does with it.
//
// From 11 September 2026 the manufacturing floor lives in SAP. An approved
// order becomes a SAP Sales Order; SAP links it to a production order and
// moves it through stages; a SAP Delivery Order eventually carries several
// orders out together. Neither app owns any of that any more — they report it.
//
// WHY THE STAGE IS FREE TEXT AND THE STATUS IS NOT
//
// The stage list belongs to the factory and has to change without an app
// release, so `custom_sap_production_stage` is never an enum here. Screens
// print it as SAP wrote it. This file is the only place a stage becomes
// behaviour, mapping it onto the four values `custom_production_status` has
// always carried — so every screen built against those keeps working.
//
// THE ONE THAT ROUNDS IN THE SAFE DIRECTION
//
// A stage nobody has mapped means the floor has started and we do not know how
// far. That is `In Production`, never `Ready`. Calling an unknown stage Ready
// would tell a rep an order is made when it is halfway through a press.
//
// Pinned by `shared/fixtures/sap_order_state.json`; the TypeScript twin is
// `client/src/domain/sapOrderState.ts`.

/// What SAP has told us about one order. All of it optional; none of it ours.
class SapOrderState {
  final String? salesOrder;
  final String? salesOrderStatus;
  final String? productionOrder;
  final String? productionStage;
  final String? deliveryOrder;
  final String? deliveryDate;
  final String? syncedAt;
  final String? syncError;

  const SapOrderState({
    this.salesOrder,
    this.salesOrderStatus,
    this.productionOrder,
    this.productionStage,
    this.deliveryOrder,
    this.deliveryDate,
    this.syncedAt,
    this.syncError,
  });

  /// Straight off a Sales Order document.
  factory SapOrderState.fromOrder(Map<String, dynamic> o) => SapOrderState(
        salesOrder: o['custom_sap_sales_order'] as String?,
        salesOrderStatus: o['custom_sap_sales_order_status'] as String?,
        productionOrder: o['custom_sap_production_order'] as String?,
        productionStage: o['custom_sap_production_stage'] as String?,
        deliveryOrder: o['custom_sap_delivery_order'] as String?,
        deliveryDate: o['custom_sap_delivery_date'] as String?,
        syncedAt: o['custom_sap_synced_at'] as String?,
        syncError: o['custom_sap_sync_error'] as String?,
      );
}

String _clean(String? v) {
  final s = (v ?? '').trim();
  // Frappe reads an unset Link back as the string 'null' when it was written
  // by naive interpolation, and that would print literally.
  return s == 'null' ? '' : s;
}

/// Stages meaning the floor has NOT begun.
///
/// Deliberately short. Everything unrecognised counts as started, because the
/// error that costs money is claiming progress that has not happened.
const Set<String> _notStarted = {'', 'planned', 'open', 'not started', 'pending'};

/// Stages meaning the floor has finished with it.
const Set<String> _finished = {'finished', 'closed', 'completed', 'ready'};

/// The four-value status the screens act on.
///
/// Delivery beats stage: a delivery order is the later fact, and an order can
/// sit at "Curing" in a stale production record and still have shipped.
String productionStatusFromSap(SapOrderState s) {
  if (_clean(s.deliveryOrder).isNotEmpty) return 'Dispatched';
  final stage = _clean(s.productionStage).toLowerCase();
  if (_finished.contains(stage)) return 'Ready';
  if (_notStarted.contains(stage)) return 'Not Started';
  return 'In Production';
}

/// Whether SAP has taken the order at all.
bool reachedSap(SapOrderState s) => _clean(s.salesOrder).isNotEmpty;

/// True when SAP has the order but nothing has reconciled it recently.
bool sapStale(SapOrderState s, DateTime now, {int hours = 24}) {
  if (!reachedSap(s)) return false;
  final at = _clean(s.syncedAt);
  if (at.isEmpty) return true;
  final t = DateTime.tryParse(at);
  if (t == null) return true;
  return now.difference(t).inHours > hours;
}

/// One line a rep can read: where the order is and when it leaves.
///
/// Null when there is nothing worth saying, so a caller renders nothing rather
/// than an empty row.
String? sapSummary(SapOrderState s) {
  final bits = <String>[];
  final stage = _clean(s.productionStage);
  final delivery = _clean(s.deliveryOrder);
  final date = _clean(s.deliveryDate);

  if (delivery.isNotEmpty) {
    bits.add('Delivery $delivery');
    if (date.isNotEmpty) bits.add('due $date');
  } else if (stage.isNotEmpty) {
    bits.add(stage);
  }
  final so = _clean(s.salesOrder);
  if (so.isNotEmpty) bits.add('SAP $so');
  return bits.isEmpty ? null : bits.join(' · ');
}
