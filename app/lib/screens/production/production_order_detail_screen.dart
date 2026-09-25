// An approved order as the production floor sees it.
//
// The customer used to be deliberately missing here — never fetched, on the
// reasoning that production plans vans rather than relationships, and the
// destination route was enough to do that.
//
// Dispatch is what changed it, on 19 Aug 2026. Somebody loading a vehicle has
// to know whose pallet is whose, and a route does not say that when two
// customers sit on one round. `Api.getOrderForProduction` now resolves the
// name off the Customer record — not the copy stored on the order, which goes
// stale the moment a customer is renamed — and this screen leads with it,
// with the route underneath.
//
// THE STATUS IS SAP'S (25 September 2026)
//
// Each line had a "Move to stage" picker and a stage progress bar, and the
// order rolled up from the lines. Removed on instruction: the status comes
// from SAP's own sales order -> invoice loop, so nothing here sets it. The
// order reads Pushed to SAP until SAP invoices it, Dispatched once it has,
// Cancelled in SAP if SAP cancels it; each line reads Dispatched once the
// invoice that carried it exists. Rules: core/sap_order_state.dart, pinned by
// shared/fixtures/sap_order_state.json. The dashboard's production order page
// was changed the same day and reads the same way.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/sap_order_state.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/services/api.dart';

class ProductionOrderDetailScreen extends StatefulWidget {
  final String orderName;
  const ProductionOrderDetailScreen({super.key, required this.orderName});
  @override
  State<ProductionOrderDetailScreen> createState() =>
      _ProductionOrderDetailScreenState();
}

class _ProductionOrderDetailScreenState
    extends State<ProductionOrderDetailScreen> {
  late Future<void> _init;
  Map<String, dynamic> _order = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init = _load();
  }

  Future<void> _load() async {
    _order = await Api.getOrderForProduction(widget.orderName);
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  List<Map<String, dynamic>> get _items =>
      ((_order['items'] as List?) ?? []).cast<Map<String, dynamic>>();

  bool get _changed => (_order['custom_changed_after_approval'] ?? 0) == 1;

  /// What the customer originally asked for, set only once production has
  /// actually moved the date.
  String get _originalDelivery {
    final s = '${_order['custom_original_delivery_date'] ?? ''}';
    return (s.isEmpty || s == 'null') ? '' : s.substring(0, 10);
  }

  bool get _moved {
    if (_originalDelivery.isEmpty) return false;
    final now = '${_order['delivery_date'] ?? ''}';
    return now.isNotEmpty && !now.startsWith(_originalDelivery);
  }

  bool get _postponed {
    final was = DateTime.tryParse(_originalDelivery);
    final now = DateTime.tryParse('${_order['delivery_date'] ?? ''}');
    if (was == null || now == null) return true;
    return now.isAfter(was);
  }

  static double _num(dynamic v) =>
      v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      _snack(done);
      setState(() => _init = _load());
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  SapOrderState get _sap => SapOrderState.fromOrder(_order);

  /// The order's reading. Cancellation first: it is the later fact.
  String get _orderStatus {
    if (cancelledInSap(_sap)) return 'Cancelled in SAP';
    if (!reachedSap(_sap)) return 'Not in SAP yet';
    return productionStatusFromSap(_sap);
  }

  /// One line's reading. A cancelled order's lines are cancelled with it.
  String _lineStatus(Map<String, dynamic> it) {
    if (cancelledInSap(_sap)) return 'Cancelled in SAP';
    final s = lineStatusFromSap(SapLineState.fromLine(it), order: _sap);
    return s == kSapNotStarted ? 'Not in SAP yet' : s;
  }

  static Color _statusColour(String s) {
    if (s == 'Cancelled in SAP') return Colors.red.shade700;
    if (s == kSapDispatched) return Colors.green.shade700;
    if (s == kSapPushed) return const Color(0xFF1D4ED8);
    return Colors.black54;
  }

  Widget _statusChip(String s) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: _statusColour(s).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4)),
        child: Text(s.toUpperCase(),
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: _statusColour(s))),
      );

  Future<void> _moveDelivery() async {
    final current =
        DateTime.tryParse('${_order['delivery_date'] ?? ''}') ??
            ServerNow.today();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: ServerNow.today().subtract(const Duration(days: 7)),
      lastDate: ServerNow.today().add(const Duration(days: 365)),
      helpText: 'Move delivery date',
    );
    if (picked == null) return;
    final iso = '${picked.year}-${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
    await _run(
        () => Api.setProductionDeliveryDate(widget.orderName, iso),
        'Delivery date moved — the rep sees this on their order.');
  }

  int get _editCount {
    final v = _order['custom_edit_count'];
    return v is num ? v.toInt() : (int.tryParse('${v ?? ''}'.trim()) ?? 0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.orderName)),
      body: FutureBuilder<void>(
        future: _init,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
                child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(humanError(snap.error))));
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            if (_changed) _changeAlert(),
            _header(),
            const SizedBox(height: 16),
            const Text('Items', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            for (final it in _items) _itemCard(it),
            const SizedBox(height: 12),
            if (_busy)
              const Center(child: CircularProgressIndicator()),
          ]);
        },
      ),
    );
  }

  /// The floor's warning that the order moved under them. Deliberately loud and
  /// deliberately sticky — it stays until somebody presses the button, because
  /// a change nobody noticed is a batch made to the wrong spec.
  Widget _changeAlert() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: const Color(0xFFFFEBEE),
            border: Border.all(color: Colors.red.shade300),
            borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.priority_high, color: Colors.red, size: 20),
            const SizedBox(width: 6),
            Text('This order changed after approval',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.red.shade700)),
          ]),
          const SizedBox(height: 4),
          const Text(
              'Items or quantities were edited after production was told about '
              'this order. Check the lines below before making anything else.',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _run(
                    () => Api.acknowledgeOrderChange(widget.orderName),
                    'Change acknowledged.'),
            icon: const Icon(Icons.check, size: 16),
            label: const Text('I have seen this'),
          ),
        ]),
      );

  Widget _header() {
    final delivery = '${_order['delivery_date'] ?? ''}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.storefront_outlined,
                size: 18, color: Colors.black54),
            const SizedBox(width: 6),
            Expanded(
              child: Text('${_order['customer_name'] ?? ''}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ]),
          const SizedBox(height: 2),
          Text('${_order['destination'] ?? 'No route set'}  ·  destination route',
              style: const TextStyle(fontSize: 11, color: Colors.black45)),
          const Divider(height: 20),
          _kv('Order', '${_order['name']}'),
          _kv('Raised', '${_order['transaction_date'] ?? '—'}'),
          _kv('Order value',
              'Rs ${_num(_order['grand_total']).toStringAsFixed(2)}'),
          // The floor is building to whatever the order says now. Knowing it
          // has been changed several times is the difference between trusting
          // the spec in front of them and going back to check it.
          if (editCountLabel(_editCount).isNotEmpty)
            _kv('Changes', editCountLabel(_editCount)),
          _kv('SAP order',
              reachedSap(_sap) ? '${_sap.salesOrder}' : 'Not in SAP yet'),
          if ((_sap.invoice ?? '').trim().isNotEmpty)
            _kv('Invoice', '${_sap.invoice}'),
          const SizedBox(height: 6),
          Row(children: [
            const Text('Status  ',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            _statusChip(_orderStatus),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.event_available,
                size: 18, color: Color(0xFFB45309)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                  'Delivery: '
                  '${delivery.isEmpty || delivery == 'null' ? 'not set' : delivery}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, color: Color(0xFFB45309))),
            ),
          ]),
          // Without this the new date is just a number and nobody — including
          // whoever moved it — can see that it moved, or what from.
          if (_moved) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(6)),
              child: Row(children: [
                Icon(_postponed ? Icons.event_repeat : Icons.fast_forward,
                    size: 16, color: Colors.orange.shade900),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      '${_postponed ? 'Postponed' : 'Brought forward'} by '
                      'production — customer asked for $_originalDelivery, '
                      'now $delivery.',
                      style: TextStyle(
                          fontSize: 11, color: Colors.orange.shade900)),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _moveDelivery,
            icon: const Icon(Icons.edit_calendar, size: 18),
            label: const Padding(
                padding: EdgeInsets.all(6),
                child: Text('Move delivery date')),
          ),
          const SizedBox(height: 2),
          const Text(
              'Postpone or bring forward to a date the floor can actually meet. '
              'The rep sees the new date on their order.',
              style: TextStyle(fontSize: 11, color: Colors.black45)),
        ]),
      ),
    );
  }

  Widget _itemCard(Map<String, dynamic> it) {
    final status = _lineStatus(it);
    final lineInvoice = '${it['custom_sap_invoice'] ?? ''}'.trim();
    final fromStock =
        '${it['custom_fulfilment_mode'] ?? ''}' == 'From Minimum Stock';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${it['item_name'] ?? it['item_code'] ?? ''}',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          // A purple "to make: 4 of 8 ordered, 4 already in stock" banner
          // stood here, splitting the line by what a shelf reservation
          // covered. There are no reservations to split by any more, so the
          // whole ordered quantity is what the floor is being asked for.
          Text('${it['custom_packing_note'] ?? ''}',
              style: const TextStyle(fontSize: 11, color: Colors.black54)),
          const SizedBox(height: 6),
          Row(children: [
            // Where it is coming from decides whether the floor makes it at
            // all, so it sits next to the quantity rather than in a footnote.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: (fromStock ? Colors.blue : Colors.deepPurple)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4)),
              child: Text(fromStock ? 'FROM MINIMUM STOCK' : 'NEW PRODUCTION',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: fromStock ? Colors.blue.shade700 : Colors.deepPurple)),
            ),
            const Spacer(),
            Text(
                'Rate Rs ${_num(it['custom_rate_per_kg']) > 0 ? '${trimQtyLocal(_num(it['custom_rate_per_kg']))}/kg' : _num(it['rate']).toStringAsFixed(2)}',
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600)),
          ]),
          const Divider(height: 18),
          // The line's status, from SAP. A stage progress bar and a "Move to
          // stage" picker stood here until 25 September 2026 — see the header.
          Row(children: [
            _statusChip(status),
            if (lineInvoice.isNotEmpty && lineInvoice != 'null') ...[
              const SizedBox(width: 8),
              Text('Invoice $lineInvoice',
                  style: const TextStyle(fontSize: 11, color: Colors.black54)),
            ],
          ]),
        ]),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k, style: const TextStyle(fontSize: 12, color: Colors.black54)),
          Text(v,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// Local trim so this screen does not have to pull in the stock model just to
/// print a rate without trailing zeroes.
String trimQtyLocal(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

/// Today, on the server's clock.
class ServerNow {
  static DateTime today() {
    final n = serverNow();
    return DateTime(n.year, n.month, n.day);
  }
}
