import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/services/api.dart';

class RetreadProformaDetailScreen extends StatefulWidget {
  final String name;
  const RetreadProformaDetailScreen({super.key, required this.name});
  @override
  State<RetreadProformaDetailScreen> createState() =>
      _RetreadProformaDetailScreenState();
}

class _RetreadProformaDetailScreenState
    extends State<RetreadProformaDetailScreen> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = Api.getRetreadProforma(widget.name);
  }

  Future<void> _supersede() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Supersede proforma?'),
        content: const Text(
            'Mark this rate proforma as superseded (e.g. rates renegotiated). It stays on record but shows as inactive.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('Supersede')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.supersedeProforma(widget.name);
      if (mounted) {
        setState(() => _future = Api.getRetreadProforma(widget.name));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text(humanError(snap.error)));
          final p = snap.data!;
          final rates = (p['rates'] as List?) ?? [];
          final superseded = '${p['status']}' == 'Superseded';
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text('${p['customer_name'] ?? p['customer'] ?? ''}',
                style:
                const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('${p['proforma_date'] ?? ''}  ·  ${p['status'] ?? ''}',
                style:
                TextStyle(color: superseded ? Colors.grey : Colors.green)),
            const SizedBox(height: 16),
            const Text('Rates', style: TextStyle(fontWeight: FontWeight.bold)),
            const Divider(),
            ...rates.map((r) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                        child: Text(
                            '${r['tyre_size'] ?? ''}  ·  ${r['retread_type'] ?? ''}')),
                    Text('₹${(r['rate'] ?? 0)}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ]),
            )),
            if (rates.isEmpty)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No rate lines.')),
            if ('${p['notes'] ?? ''}'.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Notes: ${p['notes']}',
                  style: const TextStyle(color: Colors.black54)),
            ],
            const SizedBox(height: 24),
            if (!superseded)
              OutlinedButton.icon(
                onPressed: _supersede,
                icon: const Icon(Icons.block, color: Colors.red),
                label: const Text('Supersede',
                    style: TextStyle(color: Colors.red)),
                style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.red)),
              ),
          ]);
        },
      ),
    );
  }
}

// -------------------- RETREAD READY TYRES (rep orders ready tyres) --------------------
