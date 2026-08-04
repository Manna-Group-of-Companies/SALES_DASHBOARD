import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/screens/leads/lead_order_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';

class LeadOrderScreen extends StatefulWidget {
  final Map<String, dynamic> lead;
  const LeadOrderScreen({super.key, required this.lead});
  @override
  State<LeadOrderScreen> createState() => _LeadOrderScreenState();
}

class _LeadOrderScreenState extends State<LeadOrderScreen> {
  late Future<void> _init;
  List<Map<String, dynamic>> _items = [];
  final Map<String, int> _qty = {};
  bool _submitting = false;
  String _q = '';

  List<Map<String, dynamic>> get _filtered {
    if (_q.trim().isEmpty) return _items;
    final qq = _q.toLowerCase();
    return _items
        .where((it) => ('${it['item_name'] ?? ''} ${it['name'] ?? ''}')
        .toLowerCase()
        .contains(qq))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _init = _load();
  }

  Future<void> _load() async {
    _items = await Api.getItems();
  }

  double get _total {
    double t = 0;
    for (final it in _items) {
      final q = _qty[it['name']] ?? 0;
      t += q * ((it['standard_rate'] ?? 0) as num).toDouble();
    }
    return t;
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  Future<void> _submit() async {
    final lines = <Map<String, dynamic>>[];
    for (final it in _items) {
      final q = _qty[it['name']] ?? 0;
      if (q > 0) {
        final rate = ((it['standard_rate'] ?? 0) as num).toDouble();
        lines.add({
          'item_code': it['name'],
          'item_name': it['item_name'] ?? it['name'],
          'qty': q,
          'rate': rate,
          'amount': q * rate,
        });
      }
    }
    if (lines.isEmpty) {
      _snack('Add at least one item (use + ).');
      return;
    }
    setState(() => _submitting = true);
    try {
      final name = await Api.createLeadOrder(
          lead: widget.lead['name'] as String, items: lines, total: _total);
      _snack('Lead order saved ✓  $name');
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) {
        Navigator.pushReplacement(
            context,
            MaterialPageRoute(
                builder: (_) => LeadOrderDetailScreen(
                    orderName: name, lead: widget.lead)));
      }
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(
              'Order — ${widget.lead['lead_name'] ?? widget.lead['name']}')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search products…',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: FutureBuilder<void>(
            future: _init,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(child: Text('Error: ${snap.error}'));
              }
              if (_items.isEmpty) {
                return const Center(child: Text('No sellable items found.'));
              }
              final shown = _filtered;
              if (shown.isEmpty) {
                return const Center(child: Text('No matching products.'));
              }
              return ListView.separated(
                itemCount: shown.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final it = shown[i];
                  final code = it['name'] as String;
                  final rate = ((it['standard_rate'] ?? 0) as num).toDouble();
                  final q = _qty[code] ?? 0;
                  return ListTile(
                    title: Text(it['item_name'] ?? code),
                    subtitle:
                    Text('Rs ${rate.toStringAsFixed(2)} / ${it['stock_uom'] ?? ''}'),
                    trailing:
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: q > 0
                              ? () => setState(() => _qty[code] = q - 1)
                              : null),
                      Text('$q', style: const TextStyle(fontSize: 16)),
                      IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: () => setState(() => _qty[code] = q + 1)),
                    ]),
                  );
                },
              );
            },
          ),
        ),
      ]),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Expanded(
              child: Text('Total: Rs ${_total.toStringAsFixed(2)}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold))),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: _submitting
                  ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
                  : const Text('Save Lead Order'),
            ),
          ),
        ]),
      ),
    );
  }
}

