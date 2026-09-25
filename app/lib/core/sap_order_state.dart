// What SAP says about an order, and what the app does with it.
//
// An approved order becomes a SAP Sales Order, and an A/R invoice raised
// against it is what says it has gone. The app reports those two facts and
// nothing in between:
//
//     Not Started  ->  Pushed to SAP  ->  Dispatched
//     (no SAP no.)     (SAP has it)       (invoiced)
//
// WHY THERE IS NO PRODUCTION STAGE
//
// Decided 24 September 2026 for the initial release. Under MRP one production
// order pools the demand of many sales orders, and SAP does not record which
// order a pooled production order is for — MRP-created orders carry no
// sales-order link at all, and the link table has no quantity column. Any
// per-order stage would be an allocation guess dressed up as a fact, so the
// release reports only what SAP records. `custom_sap_production_order` and
// `custom_sap_production_stage` still exist in ERPNext and may hold old
// values; nothing here reads them.
//
// WHY A DELIVERY IS NOT DISPATCH
//
// The floor posts a delivery before it invoices. Dispatch is the invoice, so a
// delivered-but-uninvoiced order still reads Pushed to SAP. Also decided
// 24 September 2026.
//
// The function names are older than this rule — `productionStatusFromSap`
// predates the removal of stages — and are kept so the screens calling them
// did not have to change.
//
// Pinned by `shared/fixtures/sap_order_state.json`; the TypeScript twin is
// `client/src/domain/sapOrderState.ts`.
import 'package:manna_field_sales/core/order_rules.dart';

const String kSapNotStarted = 'Not Started';
const String kSapPushed = 'Pushed to SAP';
const String kSapDispatched = 'Dispatched';

/// What SAP has told us about one order. All of it optional; none of it ours.
class SapOrderState {
  final String? salesOrder;
  final String? salesOrderStatus;

  /// The invoice that completed the order. The sync writes it only once every
  /// line has been invoiced, so a partly-invoiced order leaves it blank.
  final String? invoice;
  final String? invoiceDate;
  final String? syncedAt;
  final String? syncError;

  const SapOrderState({
    this.salesOrder,
    this.salesOrderStatus,
    this.invoice,
    this.invoiceDate,
    this.syncedAt,
    this.syncError,
  });

  /// Straight off a Sales Order document.
  factory SapOrderState.fromOrder(Map<String, dynamic> o) => SapOrderState(
        salesOrder: o['custom_sap_sales_order'] as String?,
        salesOrderStatus: o['custom_sap_sales_order_status'] as String?,
        invoice: o['custom_sap_invoice'] as String?,
        invoiceDate: o['custom_sap_invoice_date'] as String?,
        syncedAt: o['custom_sap_synced_at'] as String?,
        syncError: o['custom_sap_sync_error'] as String?,
      );
}

/// What SAP has told us about one LINE of an order.
class SapLineState {
  /// The invoice that carried THIS line. Blank means this line has not gone.
  final String? invoice;
  final String? invoiceDate;

  const SapLineState({this.invoice, this.invoiceDate});

  /// Straight off a row of the order's `items` table.
  factory SapLineState.fromLine(Map<String, dynamic> l) => SapLineState(
        invoice: l['custom_sap_invoice'] as String?,
        invoiceDate: l['custom_sap_invoice_date'] as String?,
      );

  /// Whether SAP has said anything about this line of its own — which, with
  /// no production stages, means whether it has been invoiced.
  bool get hasSap => _clean(invoice).isNotEmpty;
}

String _clean(String? v) {
  final s = (v ?? '').trim();
  // Frappe reads an unset Link back as the string 'null' when it was written
  // by naive interpolation, and that would print literally.
  return s == 'null' ? '' : s;
}

/// Whether SAP has taken the order at all.
bool reachedSap(SapOrderState s) => _clean(s.salesOrder).isNotEmpty;

/// The order's status from its own fields.
///
/// The invoice is checked first because it is the later fact: an order with an
/// invoice has gone, whatever else is or is not filled in.
String productionStatusFromSap(SapOrderState s) {
  if (_clean(s.invoice).isNotEmpty) return kSapDispatched;
  if (reachedSap(s)) return kSapPushed;
  return kSapNotStarted;
}

/// What an order LIST shows as the order's progress.
///
/// SAP's status once SAP has the order (or an invoice exists); before that the
/// stored in-app `custom_production_status`, which is what every order placed
/// before the floor moved to SAP carries. Never a mix: an in-app Dispatched on
/// an order SAP has not invoiced is not dispatch. An order is complete exactly
/// when this reads [kSapDispatched].
///
/// Fixture: `order_progress`. The TypeScript twin is `orderProgress`.
String orderProgress(SapOrderState s, dynamic storedProductionStatus) {
  if (reachedSap(s) || _clean(s.invoice).isNotEmpty) {
    return productionStatusFromSap(s);
  }
  final stored = _clean(
      storedProductionStatus == null ? null : '$storedProductionStatus');
  return stored.isEmpty ? kSapNotStarted : stored;
}

/// One line's status.
///
/// THE INVOICE IS THE LINE'S OWN, NOT THE ORDER'S
///
/// An order can be invoiced in parts, so a line is Dispatched only when THAT
/// line was invoiced. A line has no SAP number of its own, though: it is Pushed
/// to SAP when its [order] is, which is why the order is passed in.
String lineStatusFromSap(SapLineState line, {SapOrderState? order}) {
  if (line.hasSap) return kSapDispatched;
  if (order != null && reachedSap(order)) return kSapPushed;
  return kSapNotStarted;
}

const Map<String, int> _rank = {
  kSapNotStarted: 0,
  kSapPushed: 1,
  kSapDispatched: 2,
};

/// The order's status, rolled up from its lines: the least advanced one wins.
///
/// An order is Dispatched only when every line has been invoiced. A
/// partly-invoiced order is still open, and calling it Dispatched would close
/// it in a rep's mind while an item is outstanding.
///
/// With no lines at all, falls back to the order's own fields.
String orderStatusFromLines(List<SapLineState> lines, SapOrderState order) {
  if (lines.isEmpty) return productionStatusFromSap(order);
  return lines
      .map((l) => lineStatusFromSap(l, order: order))
      .reduce((worst, s) => (_rank[s] ?? 0) < (_rank[worst] ?? 0) ? s : worst);
}

/// True when SAP has the order but nothing has reconciled it recently.
bool sapStale(SapOrderState s, DateTime now, {int hours = 24}) {
  if (!reachedSap(s)) return false;
  final at = _clean(s.syncedAt);
  if (at.isEmpty) return true;
  final t = DateTime.tryParse(at);
  if (t == null) return true;
  return now.difference(t).inHours > hours;
}

/// One line a rep can read: which invoice, when, and the SAP order number.
///
/// Null when there is nothing worth saying, so a caller renders nothing rather
/// than an empty row.
String? sapSummary(SapOrderState s) {
  final bits = <String>[];
  final invoice = _clean(s.invoice);
  final date = _clean(s.invoiceDate);
  if (invoice.isNotEmpty) {
    bits.add('Invoice $invoice');
    if (date.isNotEmpty) bits.add(date);
  }
  final so = _clean(s.salesOrder);
  if (so.isNotEmpty) bits.add('SAP $so');
  return bits.isEmpty ? null : bits.join(' · ');
}

// --------------------------------------------------------------- cancelled ---

/// SAP's own enum value. Not free text, and the only one mapped to behaviour.
const String _kSapCancelled = 'bost_cancelled';

/// Whether SAP has cancelled this order.
///
/// `custom_sap_sales_order_status` is otherwise **shown verbatim, never
/// parsed** — the rest of SAP's vocabulary belongs to SAP and must change
/// without an app release. This is the single exception, and it earns it: a
/// cancelled order is not a shade of progress, it is the order not happening,
/// and an app that goes on calling it Approved is telling a rep to expect goods
/// nobody is making.
///
/// `bost_Cancelled` is a SAP enum, so it is stable. The sync folds SAP's
/// separate `Cancelled = tYES` flag into the same value — see
/// `Resolve-SoStatus` in `Sync-SapOrders.ps1` — so this one check covers both
/// ways SAP says it.
///
/// Found on 18 September 2026: SAP order 399 had been cancelled and ERPNext had
/// recorded it correctly for days. Nothing read it, so the order still showed
/// as approved.
///
/// The TypeScript twin is `cancelledInSap` in `client/src/domain/sapOrderState.ts`.
bool cancelledInSap(SapOrderState s) =>
    _clean(s.salesOrderStatus).toLowerCase() == _kSapCancelled;

/// The approval line an order shows, once SAP has had its say.
///
/// One function rather than the same check on every screen, which is how the
/// two apps drift. Cancellation outranks the approval status because it is the
/// later fact and the terminal one.
String orderApprovalLabel(dynamic rawPoStatus, SapOrderState sap) =>
    cancelledInSap(sap) ? 'Cancelled in SAP' : approvalLabel(rawPoStatus);
