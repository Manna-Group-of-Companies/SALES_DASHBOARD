import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/screens/expenses/add_expense_screen.dart';
import 'package:manna_field_sales/services/api.dart';

class ExpenseListScreen extends StatefulWidget {
  const ExpenseListScreen({super.key});
  @override
  State<ExpenseListScreen> createState() => _ExpenseListScreenState();
}

class _ExpenseListScreenState extends State<ExpenseListScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  @override
  void initState() {
    super.initState();
    _future = Api.getMyExpenses();
  }

  void _reload() => setState(() { _future = Api.getMyExpenses(); });
  double _num(dynamic v) => (v is num) ? v.toDouble() : 0.0;
  String _q = '';
  bool _match(Map<String, dynamic> r) {
    if (_q.isEmpty) return true;
    final hay = r.values.map((e) => (e ?? '').toString().toLowerCase()).join(' ');
    return hay.contains(_q.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Expenses'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AddExpenseScreen()));
          _reload();
        },
        icon: const Icon(Icons.add),
        label: const Text('Add Expense'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search expenses…',
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
                if (snap.hasError) return Center(child: Text(humanError(snap.error)));
                final all = snap.data!;
                final rows = all.where(_match).toList();
                if (all.isEmpty) {
                  return const Center(
                      child: Text('No expenses yet. Tap Add Expense.'));
                }
                if (rows.isEmpty) {
                  return const Center(child: Text('No matches.'));
                }
                return ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    final status = (r['status'] ?? 'Pending').toString();
                    final rem = (r['remarks'] ?? '').toString();
                    return ListTile(
                      leading: const Icon(Icons.receipt_long),
                      title: Text(
                          '${r['category'] ?? ''} · ₹${_num(r['amount']).toStringAsFixed(2)}'),
                      subtitle: Text('${r['expense_date'] ?? ''}'
                          '${rem.isNotEmpty ? ' · $rem' : ''}'),
                      trailing: Text(status,
                          style: TextStyle(
                              color: status == 'Approved'
                                  ? Colors.green
                                  : status == 'Rejected'
                                  ? Colors.red
                                  : Colors.orange,
                              fontWeight: FontWeight.w600)),
                    );
                  },
                );
              },
            )),
      ]),
    );
  }
}

