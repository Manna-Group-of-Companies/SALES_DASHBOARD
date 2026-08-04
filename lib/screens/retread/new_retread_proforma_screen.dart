import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/services/api.dart';

class _RateRow {
  final TextEditingController size = TextEditingController();
  final TextEditingController rate = TextEditingController();
  String type = 'Hot';
}

class NewRetreadProformaScreen extends StatefulWidget {
  const NewRetreadProformaScreen({super.key});
  @override
  State<NewRetreadProformaScreen> createState() =>
      _NewRetreadProformaScreenState();
}

class _NewRetreadProformaScreenState extends State<NewRetreadProformaScreen> {
  late Future<List<Map<String, dynamic>>> _customers;
  String _q = '';
  Map<String, dynamic>? _sel;
  final List<_RateRow> _rows = [_RateRow()];
  final _notes = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _customers = Api.getCustomers();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _save() async {
    if (_sel == null) return _snack('Pick a customer first.');
    final rates = <Map<String, dynamic>>[];
    for (final r in _rows) {
      final size = r.size.text.trim();
      final rate = double.tryParse(r.rate.text.trim());
      if (size.isEmpty || rate == null) continue;
      rates.add({'tyre_size': size, 'retread_type': r.type, 'rate': rate});
    }
    if (rates.isEmpty) return _snack('Add at least one rate (size + rate).');
    setState(() => _busy = true);
    try {
      final name = await Api.createRetreadProforma(
        customer: _sel!['name'] as String,
        customerName: _sel!['customer_name'] as String?,
        rates: rates,
        notes: _notes.text,
      );
      _snack('Proforma $name created');
      await Future.delayed(const Duration(milliseconds: 400));
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
      appBar: AppBar(title: const Text('New Retread Proforma')),
      body: _sel == null ? _customerPicker() : _form(),
    );
  }

  Widget _customerPicker() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Search customer…',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => _q = v),
        ),
      ),
      Expanded(
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _customers,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final all = snap.data ?? [];
            final list = all.where((c) {
              if (_q.isEmpty) return true;
              final hay = '${c['customer_name'] ?? ''} ${c['name'] ?? ''}'
                  .toLowerCase();
              return hay.contains(_q.toLowerCase());
            }).toList();
            return ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final c = list[i];
                return ListTile(
                  title: Text('${c['customer_name'] ?? c['name']}'),
                  onTap: () => setState(() => _sel = c),
                );
              },
            );
          },
        ),
      ),
    ]);
  }

  Widget _form() {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: ListTile(
          leading: const Icon(Icons.store, color: Color(0xFFF46A21)),
          title: Text('${_sel!['customer_name'] ?? _sel!['name']}'),
          trailing: TextButton(
              onPressed: () => setState(() => _sel = null),
              child: const Text('Change')),
        ),
      ),
      const SizedBox(height: 8),
      const Text('Retread rates (no quantities)',
          style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      ..._rows.asMap().entries.map((e) {
        final i = e.key;
        final row = e.value;
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(children: [
              TextField(
                controller: row.size,
                decoration: const InputDecoration(
                    labelText: 'Tyre size (e.g. 1000-20)',
                    isDense: true,
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: row.type,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'Type',
                        isDense: true,
                        border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'Hot', child: Text('Hot')),
                      DropdownMenuItem(value: 'Cold', child: Text('Cold')),
                    ],
                    onChanged: (v) => setState(() => row.type = v ?? 'Hot'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: row.rate,
                    keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Rate ₹',
                        isDense: true,
                        border: OutlineInputBorder()),
                  ),
                ),
                if (_rows.length > 1)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => setState(() => _rows.removeAt(i)),
                  ),
              ]),
            ]),
          ),
        );
      }),
      TextButton.icon(
        onPressed: () => setState(() => _rows.add(_RateRow())),
        icon: const Icon(Icons.add),
        label: const Text('Add rate line'),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _notes,
        maxLines: 2,
        decoration: const InputDecoration(
            labelText: 'Notes (optional)', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: _busy
            ? const SizedBox(
            height: 18,
            width: 18,
            child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Create proforma'),
      ),
    ]);
  }
}

