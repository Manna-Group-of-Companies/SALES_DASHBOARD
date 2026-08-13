import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/pdf/proforma_pdf.dart';
import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/models/order_ref.dart';
import 'package:manna_field_sales/screens/orders/order_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/info_box.dart';

class LeadOrderDetailScreen extends StatefulWidget {
  final String orderName;
  final Map<String, dynamic> lead;
  const LeadOrderDetailScreen(
      {super.key, required this.orderName, required this.lead});
  @override
  State<LeadOrderDetailScreen> createState() => _LeadOrderDetailScreenState();
}

class _LeadOrderDetailScreenState extends State<LeadOrderDetailScreen> {
  late Future<void> _init;
  Map<String, dynamic> _order = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init = _load();
  }

  Future<void> _load() async {
    _order = await Api.getLeadOrder(widget.orderName);
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  Future<void> _proforma({required bool asPO}) async {
    final synthCust = {
      'customer_name': widget.lead['lead_name'] ?? _order['lead_name'],
      'territory': widget.lead['territory'],
      'custom_phone': widget.lead['mobile_no'],
    };
    final synthOrder = {
      'name': _order['name'],
      'transaction_date': _order['order_date'],
      'customer': _order['lead_name'],
      'items': _order['items'] ?? [],
    };
    if (!mounted) return;
    setState(() => _busy = true);
    final err = await openProformaPdf(
        order: synthOrder, customer: synthCust, isPurchaseOrder: asPO);
    if (mounted) setState(() => _busy = false);
    if (err != null && mounted) _snack('Proforma error: $err');
  }

  /// Opens the same order screen the rep raised it with, so a lead order is
  /// changed exactly the way a customer order is.
  Future<void> _edit() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => OrderScreen(
                party: OrderParty.lead(widget.lead),
                existingOrder: _order,
              )),
    );
    if (changed == true && mounted) setState(() => _init = _load());
  }

  // The signed-PO scan and its PO-number prompt are gone. Nothing comes back
  // from the customer any more — raising the order is the request for
  // approval, exactly as it is for a customer order.

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Lead Order ${widget.orderName}')),
      body: FutureBuilder<void>(
        future: _init,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text(humanError(snap.error)));
          final status = '${_order['status'] ?? ''}';
          final items = (_order['items'] as List?) ?? [];
          final total = items.fold<double>(
              0, (s, it) => s + (((it['amount'] ?? 0) as num).toDouble()));
          final approved = status == 'Approved' ||
              status == 'PO Uploaded' ||
              status == 'PO Approved - Ready for SAP';
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text(widget.lead['lead_name'] ?? _order['lead_name'] ?? '',
                style:
                const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
                'Total: Rs ${total.toStringAsFixed(2)}  ·  ${items.length} item(s)'),
            const SizedBox(height: 12),
            Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: const Color(0xFFF1F3F4),
                    borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  const Icon(Icons.flag, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('Status: $status',
                          style: const TextStyle(fontWeight: FontWeight.w600))),
                ])),
            const Divider(height: 28),
            if (status == 'Pending Approval')
              const InfoBox(
                  icon: Icons.hourglass_top,
                  color: Colors.orange,
                  text:
                  'Awaiting manager order approval. Once approved, you can send the proforma.'),
            if (status == 'Rejected')
              const InfoBox(
                  icon: Icons.cancel,
                  color: Colors.red,
                  text: 'This lead order was rejected by the manager.'),
            // Editable on exactly the same terms as a customer order: until
            // 1 pm on the delivery date, by the rep who raised it or their
            // manager. Approved rates stay locked through the edit.
            if (canEditOrder(_order))
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _edit,
                  icon: const Icon(Icons.edit),
                  label: const Padding(
                      padding: EdgeInsets.all(10), child: Text('Edit order')),
                ),
              )
            else if (orderLockReason(_order).isNotEmpty)
              InfoBox(
                  icon: Icons.lock_clock,
                  color: Colors.black54,
                  text: orderLockReason(_order)),
            if (approved) ...[
              const SizedBox(height: 16),
              const Text('Proforma',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                  'For the customer’s own records. Nothing has to come back — '
                  'the order is already with the factory.',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy ? null : () => _proforma(asPO: false),
                icon: const Icon(Icons.picture_as_pdf),
                label: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Text('Generate & Send Proforma')),
              ),
            ],
            if (_busy)
              const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: Center(child: CircularProgressIndicator())),
          ]);
        },
      ),
    );
  }
}

// -------------------- COMPLAINT --------------------
