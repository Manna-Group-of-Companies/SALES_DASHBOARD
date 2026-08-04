import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/services/api.dart';

class AddExpenseScreen extends StatefulWidget {
  const AddExpenseScreen({super.key});
  @override
  State<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends State<AddExpenseScreen> {
  late Future<List<Map<String, dynamic>>> _reps;
  String? _rep;
  String _category = 'Daily Allowance';
  final _amount = TextEditingController();
  final _remarks = TextEditingController();
  bool _busy = false;

  static const _categories = [
    'Daily Allowance',
    'Travel Expense',
    'Accommodation Expense',
  ];

  @override
  void initState() {
    super.initState();
    _reps = Api.getSalesPersons();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _save() async {
    final amt = double.tryParse(_amount.text.trim());
    if (_rep == null) return _snack('Pick a sales person.');
    if (amt == null || amt <= 0) return _snack('Enter a valid amount.');
    setState(() => _busy = true);
    try {
      final name = await Api.createExpense(
        salesPerson: _rep!,
        category: _category,
        amount: amt,
        remarks: _remarks.text.trim(),
      );
      _snack('Expense saved ✓  $name (₹${amt.toStringAsFixed(2)})');
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
      appBar: AppBar(title: const Text('Add Expense')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _reps,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final reps = snap.data ?? [];
          if (_rep == null && reps.isNotEmpty) _rep = reps.first['name'] as String;
          return Padding(
            padding: const EdgeInsets.all(20),
            child: ListView(children: [
              DropdownButtonFormField<String>(
                value: _rep,
                decoration: const InputDecoration(
                    labelText: 'Sales Person', border: OutlineInputBorder()),
                items: reps
                    .map((r) => DropdownMenuItem(
                    value: r['name'] as String,
                    child: Text(r['sales_person_name'] ?? r['name'])))
                    .toList(),
                onChanged: (v) => setState(() => _rep = v),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _category,
                decoration: const InputDecoration(
                    labelText: 'Category', border: OutlineInputBorder()),
                items: _categories
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) => setState(() => _category = v ?? _category),
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
              TextField(
                controller: _remarks,
                maxLines: 2,
                decoration: const InputDecoration(
                    labelText: 'Remarks (optional)',
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
                      : const Text('Save Expense'),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }
}

// -------------------- TRIPS (rich model) --------------------
