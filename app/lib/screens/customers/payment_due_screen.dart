// Customers whose payment is due, and their orders (14 Nov 2026, the user:
// "show the payment due customer, show orders, show in dashboard").
//
// Due means overdue past the customer's payment terms, as SAP's credit sync
// wrote it (core/credit.dart, paymentDueCustomers). The list is the
// customers this login sees - a rep's own, a manager's team's - most
// overdue first; opening one shows its latest orders.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/credit.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/screens/orders/order_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';

class PaymentDueScreen extends StatefulWidget {
  const PaymentDueScreen({super.key});

  @override
  State<PaymentDueScreen> createState() => _PaymentDueScreenState();
}

class _PaymentDueScreenState extends State<PaymentDueScreen> {
  late Future<List<Map<String, dynamic>>> _due = _load();

  Future<List<Map<String, dynamic>>> _load() async =>
      paymentDueCustomers(await Api.getCustomers());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment Due')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _due,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
                child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(humanError(snap.error!))));
          }
          final rows = snap.data!;
          return RefreshIndicator(
            onRefresh: () async {
              setState(() => _due = _load());
              await _due;
            },
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Text(
                    rows.isEmpty
                        ? 'No customer is overdue past their terms.'
                        : '${rows.length} customer${rows.length == 1 ? '' : 's'}'
                            '  ·  ${inr(rows.fold(0.0, (s, c) => s + overduePastTerms(c)))} overdue',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                for (final c in rows) _DueCustomer(customer: c),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DueCustomer extends StatefulWidget {
  final Map<String, dynamic> customer;
  const _DueCustomer({required this.customer});

  @override
  State<_DueCustomer> createState() => _DueCustomerState();
}

class _DueCustomerState extends State<_DueCustomer> {
  Future<List<Map<String, dynamic>>>? _orders;

  Map<String, dynamic> get c => widget.customer;

  @override
  Widget build(BuildContext context) {
    final days = overdueDaysOf(c);
    final terms = paymentTermsOf(c);
    final total = agingOf(c).total;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ExpansionTile(
        onExpansionChanged: (open) {
          if (open && _orders == null) {
            setState(() => _orders = Api.getCustomerOrders('${c['name']}'));
          }
        },
        title: Text('${c['customer_name'] ?? c['name']}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          [
            '${inr(overduePastTerms(c))} overdue',
            if (days > 0) '$days days',
            'Outstanding ${inr(total)}',
            if (terms.isNotEmpty) terms,
          ].join('  ·  '),
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Text(inr(overduePastTerms(c)),
            style: const TextStyle(
                color: Colors.red, fontWeight: FontWeight.bold)),
        children: [
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _orders,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                    padding: EdgeInsets.all(12),
                    child: LinearProgressIndicator());
              }
              if (snap.hasError) {
                return Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(humanError(snap.error!)));
              }
              final orders = snap.data ?? const [];
              if (orders.isEmpty) {
                return const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('No orders on record.',
                        style: TextStyle(color: Colors.black54)));
              }
              return Column(children: [
                for (final o in orders)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.receipt_long, size: 20),
                    title: Text('${o['name']}  ·  ${o['transaction_date'] ?? ''}'),
                    subtitle: Text(_status(o)),
                    trailing: Text(inr(_num(o['grand_total']))),
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                OrderDetailScreen(orderName: '${o['name']}'))),
                  ),
              ]);
            },
          ),
        ],
      ),
    );
  }

  static double _num(Object? v) =>
      v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

  static String _text(Object? v) {
    final s = '${v ?? ''}'.trim();
    return s == 'null' ? '' : s;
  }

  /// Invoiced in SAP beats anything ERPNext says about the order.
  static String _status(Map<String, dynamic> o) {
    final invoice = _text(o['custom_sap_invoice']);
    if (invoice.isNotEmpty) return 'Invoiced · $invoice';
    final po = _text(o['custom_po_status']);
    final rep = _text(o['custom_sales_person']);
    return [if (po.isNotEmpty) po, if (rep.isNotEmpty) rep].join('  ·  ');
  }
}
