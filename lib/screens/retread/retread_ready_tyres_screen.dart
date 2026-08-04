import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/services/api.dart';

class RetreadReadyTyresScreen extends StatefulWidget {
  const RetreadReadyTyresScreen({super.key});
  @override
  State<RetreadReadyTyresScreen> createState() =>
      _RetreadReadyTyresScreenState();
}

class _RetreadReadyTyresScreenState extends State<RetreadReadyTyresScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  final Set<String> _sel = {};
  final Map<String, double> _rate = {};
  bool _placing = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final tyres = await Api.getMyReadyTyres();
    final pfNames = <String>{};
    for (final t in tyres) {
      final p = '${t['proforma'] ?? ''}';
      if (p.isNotEmpty) pfNames.add(p);
    }
    final pfRates = <String, List>{};
    for (final pf in pfNames) {
      try {
        final d = await Api.getRetreadProforma(pf);
        pfRates[pf] = (d['rates'] as List?) ?? const [];
      } catch (_) {}
    }
    _rate.clear();
    for (final t in tyres) {
      final rates = pfRates['${t['proforma'] ?? ''}'] ?? const [];
      for (final r in rates) {
        if ('${r['tyre_size']}' == '${t['tyre_size']}' &&
            '${r['retread_type']}' == '${t['retread_type']}') {
          _rate['${t['name']}'] =
          (r['rate'] is num) ? (r['rate'] as num).toDouble() : 0.0;
          break;
        }
      }
    }
    return tyres;
  }

  void _reload() {
    setState(() {
      _sel.clear();
      _future = _load();
    });
  }

  Future<void> _place() async {
    if (_sel.isEmpty) return;
    setState(() => _placing = true);
    try {
      final rates = <String, double>{};
      for (final n in _sel) {
        rates[n] = _rate[n] ?? 0;
      }
      await Api.placeRetreadOrder(_sel.toList(), rates);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ordered ${_sel.length} tyre(s) ✓')));
      }
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    } finally {
      if (mounted) setState(() => _placing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ready Tyres'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
          final tyres = snap.data ?? [];
          if (tyres.isEmpty) {
            return const Center(
                child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                        'No ready tyres yet. When production marks your tagged tyres Ready, they appear here to order.',
                        textAlign: TextAlign.center)));
          }
          final widgets = <Widget>[];
          String? lastCust;
          for (final t in tyres) {
            final cust = '${t['customer_name'] ?? t['customer'] ?? ''}';
            if (cust != lastCust) {
              lastCust = cust;
              widgets.add(Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
                child: Text(cust,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ));
            }
            final name = '${t['name']}';
            final rate = _rate[name];
            final hasRate = rate != null;
            final sub = '${t['tyre_size'] ?? ''} · ${t['retread_type'] ?? ''}'
                '${'${t['tyre_brand'] ?? ''}'.isNotEmpty ? ' · ${t['tyre_brand']}' : ''}'
                '${'${t['tread_pattern'] ?? ''}'.isNotEmpty ? ' · ${t['tread_pattern']}' : ''}';
            widgets.add(CheckboxListTile(
              value: _sel.contains(name),
              onChanged: hasRate
                  ? (v) => setState(() {
                if (v == true) {
                  _sel.add(name);
                } else {
                  _sel.remove(name);
                }
              })
                  : null,
              title: Text('${t['tyre_number'] ?? name}'),
              subtitle: Text(hasRate
                  ? sub
                  : '$sub  ·  no rate in proforma — cannot order',
                  style: hasRate
                      ? null
                      : const TextStyle(color: Colors.orange, fontSize: 12)),
              secondary: hasRate
                  ? Text('₹${rate.toStringAsFixed(0)}',
                  style: const TextStyle(fontWeight: FontWeight.bold))
                  : const Icon(Icons.error_outline, color: Colors.orange),
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
            ));
          }
          return ListView(children: widgets);
        },
      ),
      bottomNavigationBar: _sel.isEmpty
          ? null
          : SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: _placing ? null : _place,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _placing
                  ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
                  : Text(
                  'Place order — ${_sel.length} tyre(s) · ₹${_sel.fold<double>(0, (s, n) => s + (_rate[n] ?? 0)).toStringAsFixed(0)}'),
            ),
          ),
        ),
      ),
    );
  }
}

// -------------------- RETREAD ORDERS (rep's placed orders, grouped) --------------------
