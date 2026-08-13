import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/location_service.dart';

class CollectionScreen extends StatefulWidget {
  final Map<String, dynamic> customer;
  final List<Map<String, dynamic>> reps;
  const CollectionScreen(
      {super.key, required this.customer, required this.reps});
  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  late Future<void> _init;
  List<String> _modes = [];
  String? _rep;
  String? _mode;
  final _amount = TextEditingController();
  final _ref = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.reps.isNotEmpty) _rep = widget.reps.first['name'] as String;
    _init = _load();
  }

  Future<void> _load() async {
    _modes = await Api.getModesOfPayment();
    _mode = _modes.contains('Cash')
        ? 'Cash'
        : (_modes.isNotEmpty ? _modes.first : null);
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  Future<void> _save() async {
    final amt = double.tryParse(_amount.text.trim());
    if (_rep == null) return _snack('Pick a sales person.');
    if (amt == null || amt <= 0) return _snack('Enter a valid amount.');
    if (_mode == null) return _snack('Pick a payment mode.');
    setState(() => _busy = true);
    _snack('Getting GPS…');
    try {
      final pos = await getCurrentLocation();
      final name = await Api.createCollectionEntry(
        customer: widget.customer['name'],
        salesPerson: _rep!,
        amount: amt,
        mode: _mode!,
        referenceNo: _ref.text.trim(),
        lat: pos.latitude,
        lng: pos.longitude,
      );
      _snack('Collection saved ✓  $name (₹${amt.toStringAsFixed(2)})');
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(
              'Collection — ${widget.customer['customer_name'] ?? widget.customer['name']}')),
      body: FutureBuilder<void>(
        future: _init,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text(humanError(snap.error)));
          return Padding(
            padding: const EdgeInsets.all(20),
            child: ListView(children: [
              DropdownButtonFormField<String>(
                value: _rep,
                decoration: const InputDecoration(
                    labelText: 'Sales Person', border: OutlineInputBorder()),
                items: widget.reps
                    .map((r) => DropdownMenuItem(
                  value: r['name'] as String,
                  child: Text(r['sales_person_name'] ?? r['name']),
                ))
                    .toList(),
                onChanged: (v) => setState(() => _rep = v),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _amount,
                keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Amount (₹)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _mode,
                decoration: const InputDecoration(
                    labelText: 'Mode of Payment', border: OutlineInputBorder()),
                items: _modes
                    .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                    .toList(),
                onChanged: (v) => setState(() => _mode = v),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _ref,
                decoration: const InputDecoration(
                    labelText: 'Reference No (optional)',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _busy
                      ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                      : const Text('Save Collection'),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }
}

// -------------------- HISTORY SCREENS --------------------
