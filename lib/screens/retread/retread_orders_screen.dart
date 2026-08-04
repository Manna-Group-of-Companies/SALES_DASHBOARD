import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/screens/retread/retread_order_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';

class RetreadOrdersScreen extends StatefulWidget {
  const RetreadOrdersScreen({super.key});
  @override
  State<RetreadOrdersScreen> createState() => _RetreadOrdersScreenState();
}

class _RetreadOrdersScreenState extends State<RetreadOrdersScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  static const _rank = {
    'Ordered': 0,
    'Scheduled': 1,
    'Delivered': 2,
    'Invoiced': 3
  };

  @override
  void initState() {
    super.initState();
    _future = Api.getMyRetreadOrderedTyres();
  }

  void _reload() => setState(() => _future = Api.getMyRetreadOrderedTyres());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Retread Orders'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text(humanError(snap.error)));
          final tyres = snap.data ?? [];
          if (tyres.isEmpty) {
            return const Center(
                child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                        'No orders yet. Order ready tyres from "Ready Tyres".',
                        textAlign: TextAlign.center)));
          }
          final groups = <String, List<Map<String, dynamic>>>{};
          for (final t in tyres) {
            final ref = '${t['order_ref'] ?? ''}';
            (groups[ref] ??= []).add(t);
          }
          final refs = groups.keys.toList();
          return ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: refs.length,
            itemBuilder: (_, i) {
              final ref = refs[i];
              final items = groups[ref]!;
              final cust =
                  '${items.first['customer_name'] ?? items.first['customer'] ?? ''}';
              final date = '${items.first['order_date'] ?? ''}';
              final total = items.fold<double>(
                  0,
                      (s, t) =>
                  s + ((t['rate'] is num) ? (t['rate'] as num).toDouble() : 0));
              int minRank = 3;
              for (final t in items) {
                final r = _rank['${t['status']}'] ?? 0;
                if (r < minRank) minRank = r;
              }
              final allInv =
              items.every((t) => '${t['status']}' == 'Invoiced');
              final label = allInv
                  ? 'Invoiced'
                  : _rank.entries
                  .firstWhere((e) => e.value == minRank,
                  orElse: () => const MapEntry('Ordered', 0))
                  .key;
              Color col;
              switch (label) {
                case 'Invoiced':
                  col = const Color(0xFF2563EB);
                  break;
                case 'Delivered':
                  col = Colors.green;
                  break;
                case 'Scheduled':
                  col = Colors.teal;
                  break;
                default:
                  col = const Color(0xFF7C3AED);
              }
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.local_shipping,
                      color: Color(0xFFF46A21)),
                  title: Text(cust),
                  subtitle: Text(
                      '$date  ·  ${items.length} tyre(s)  ·  ₹${total.toStringAsFixed(0)}'),
                  trailing: Text(label,
                      style: TextStyle(
                          color: col,
                          fontWeight: FontWeight.bold,
                          fontSize: 12)),
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => RetreadOrderDetailScreen(
                              orderRef: ref, tyres: items))),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

