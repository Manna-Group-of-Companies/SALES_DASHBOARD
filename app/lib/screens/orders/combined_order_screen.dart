// One customer's week, and the orders inside it.
//
// After the production manager closes a week, a customer's several orders are
// one order to everybody downstream. This is that one order opened up: the
// week, what it came to, and every individual order it holds — each still
// openable, because the combined view is a summary and never a replacement for
// the document that was actually raised.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/screens/orders/order_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/order_complete_tick.dart';

class CombinedOrderScreen extends StatefulWidget {
  /// The combined order row as the list already had it, so the header can be
  /// drawn before the individual orders arrive.
  final Map<String, dynamic> combined;

  const CombinedOrderScreen({super.key, required this.combined});

  @override
  State<CombinedOrderScreen> createState() => _CombinedOrderScreenState();
}

class _CombinedOrderScreenState extends State<CombinedOrderScreen> {
  late Future<List<Map<String, dynamic>>> _fut;

  String get _name => '${widget.combined['name']}';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => _fut = Api.ordersInCombined(_name);

  static double _num(dynamic v) =>
      v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

  String get _weekLabel {
    final a = '${widget.combined['week_start'] ?? ''}';
    final b = '${widget.combined['week_end'] ?? ''}';
    if (a.isEmpty || b.isEmpty) return '';
    return '$a  to  $b';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.combined;
    return Scaffold(
      appBar: AppBar(title: Text(_name)),
      body: Column(children: [
        Card(
          margin: const EdgeInsets.all(12),
          color: const Color(0xFFEFEBE9),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.merge_type, color: Color(0xFF6D4C41)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          '${c['customer_name'] ?? c['customer'] ?? ''}',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                    Text('Rs ${_num(c['total_amount']).toStringAsFixed(2)}',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold)),
                  ]),
                  const SizedBox(height: 6),
                  if (_weekLabel.isNotEmpty)
                    Text('Week $_weekLabel',
                        style: const TextStyle(
                            fontSize: 12.5, color: Colors.black87)),
                  const SizedBox(height: 2),
                  Text(
                      '${c['order_count'] ?? 0} '
                      '${(c['order_count'] ?? 0) == 1 ? 'order' : 'orders'}'
                      '  ·  ${c['status'] ?? 'Draft'}',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.black54)),
                ]),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Orders in this week',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _fut,
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
              final rows = snap.data ?? const [];
              if (rows.isEmpty) {
                // Membership lives on the Sales Orders, so an empty group means
                // they were taken back out — not that the screen failed.
                return const Center(
                    child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                            'No orders are in this combined order any more.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.black54))));
              }
              return ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final r = rows[i];
                  return ListTile(
                    leading: const Icon(Icons.receipt_long),
                    title: Text('${r['name']}'),
                    subtitle: Text(
                        '${r['transaction_date'] ?? ''}'
                        '  ·  ${r['custom_sales_person'] ?? '—'}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      OrderCompleteTick(order: r, compact: true),
                      const SizedBox(width: 8),
                      Text('Rs ${_num(r['grand_total']).toStringAsFixed(0)}',
                          style:
                              const TextStyle(fontWeight: FontWeight.bold)),
                      const Icon(Icons.chevron_right),
                    ]),
                    onTap: () async {
                      await Navigator.of(ctx).push(MaterialPageRoute(
                          builder: (_) => OrderDetailScreen(
                              orderName: r['name'] as String)));
                      if (mounted) setState(_reload);
                    },
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}
