import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/production/combine_week_screen.dart';
import 'package:manna_field_sales/screens/production/production_order_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/order_complete_tick.dart';

class ProductionDashboardScreen extends StatefulWidget {
  const ProductionDashboardScreen({super.key});
  @override
  State<ProductionDashboardScreen> createState() =>
      _ProductionDashboardScreenState();
}

class _ProductionDashboardScreenState extends State<ProductionDashboardScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _future = Api.getApprovedPOsForProduction();
  }

  void _reload() =>
      setState(() => _future = Api.getApprovedPOsForProduction());

  /// Searches the order number and the route only. The customer is never
  /// loaded for production, so there is nothing else to match on — and a
  /// search box that quietly matched a hidden field would be a way of
  /// confirming who an order belongs to by guessing.
  bool _match(Map<String, dynamic> r) {
    if (_q.isEmpty) return true;
    final hay = [r['name'], r['destination']]
        .map((e) => (e ?? '').toString().toLowerCase())
        .join(' ');
    return hay.contains(_q.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text('Production · ${Session.I.productionCompany ?? ''}'),
          actions: [
            IconButton(
                icon: const Icon(Icons.merge_type),
                tooltip: 'Close the week',
                onPressed: () async {
                  await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const CombineWeekScreen()));
                  _reload();
                }),
            IconButton(icon: const Icon(Icons.refresh), onPressed: _reload)
          ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search order no. / route…',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _future,
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
              final all = snap.data ?? [];
              final rows = all.where(_match).toList();
              if (all.isEmpty) {
                return const Center(
                    child: Text('No approved POs waiting for SAP entry 🎉'));
              }
              if (rows.isEmpty) {
                return const Center(child: Text('No matches.'));
              }
              return ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final r = rows[i];
                  final changed =
                      (r['custom_changed_after_approval'] ?? 0) == 1;
                  final delivery = '${r['delivery_date'] ?? ''}';
                  return ListTile(
                    isThreeLine: true,
                    leading: Icon(
                        changed ? Icons.priority_high : Icons.receipt_long,
                        color: changed
                            ? Colors.red
                            : const Color(0xFF7C3AED)),
                    // The route, not the customer. Production never receives
                    // the identity — see Api.getApprovedPOsForProduction.
                    title: Row(children: [
                      Expanded(
                        child: Text('${r['destination'] ?? 'No route set'}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w600)),
                      ),
                      if (changed)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4)),
                          child: Text('CHANGED',
                              style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.red.shade700)),
                        ),
                    ]),
                    subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '${r['name']}  ·  raised ${r['transaction_date'] ?? ''}'
                              '\nDeliver by ${delivery.isEmpty || delivery == 'null' ? 'not set' : delivery}'),
                          const SizedBox(height: 4),
                          OrderCompleteTick(order: r),
                        ]),
                    trailing: Text('₹${(r['grand_total'] ?? 0)}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    onTap: () async {
                      await Navigator.push(
                          ctx,
                          MaterialPageRoute(
                              builder: (_) => ProductionOrderDetailScreen(
                                  orderName: r['name'] as String)));
                      _reload();
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

