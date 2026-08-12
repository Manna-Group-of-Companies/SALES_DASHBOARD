// What a rep travelled and spent over a period they choose.
//
// The trips list answers "what did I do on Tuesday". This answers a different
// question — "what am I owed for the month" — which is the one a rep asks
// before payday and the one they currently work out on paper.
//
// Shared trips are kept apart rather than folded in. A trip with a colleague
// tagged on it is one cost between two people, and adding its whole amount
// into each rep's total would count the same money once per person on board.
// So the headline figure is what is this rep's alone, and the shared total
// sits beside it, labelled.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/expenses.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/core/week.dart';
import 'package:manna_field_sales/services/api.dart';

class ExpenseSummaryScreen extends StatefulWidget {
  const ExpenseSummaryScreen({super.key});
  @override
  State<ExpenseSummaryScreen> createState() => _ExpenseSummaryScreenState();
}

class _ExpenseSummaryScreenState extends State<ExpenseSummaryScreen> {
  late DateTime _from;
  late DateTime _to;
  late Future<List<Map<String, dynamic>>> _fut;

  @override
  void initState() {
    super.initState();
    // Opens on this month so far, which is the period a rep asks about most
    // and saves them setting two dates to see anything at all.
    final now = serverNow();
    _from = DateTime(now.year, now.month, 1);
    _to = DateTime(now.year, now.month, now.day);
    _reload();
  }

  void _reload() =>
      _fut = Api.getExpenseSummary(from: isoDate(_from), to: isoDate(_to));

  Future<void> _pick({required bool start}) async {
    final now = serverNow();
    final picked = await showDatePicker(
      context: context,
      initialDate: start ? _from : _to,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year, now.month, now.day),
      helpText: start ? 'Period starts' : 'Period ends',
    );
    if (picked == null) return;
    setState(() {
      if (start) {
        _from = picked;
        // A start after the end is not a period. Rather than refuse it, the
        // other end follows, which is what somebody dragging a range means.
        if (_to.isBefore(_from)) _to = _from;
      } else {
        _to = picked;
        if (_to.isBefore(_from)) _from = _to;
      }
      _reload();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Expenses'), actions: [
        IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(_reload)),
      ]),
      body: Column(children: [
        _periodBar(),
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
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No trips in this period.',
                        style: TextStyle(color: Colors.black54)),
                  ),
                );
              }

              final totals = sumExpenses(rows);
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                itemCount: rows.length + 1,
                itemBuilder: (_, i) =>
                    i == 0 ? _totals(totals) : _tripRow(rows[i - 1]),
              );
            },
          ),
        ),
      ]),
    );
  }

  Widget _periodBar() => Card(
        margin: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(children: [
            Expanded(child: _dateButton('From', _from, () => _pick(start: true))),
            const Icon(Icons.arrow_forward, size: 16, color: Colors.black38),
            Expanded(child: _dateButton('To', _to, () => _pick(start: false))),
          ]),
        ),
      );

  Widget _dateButton(String label, DateTime d, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          child: Column(children: [
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.black45)),
            const SizedBox(height: 2),
            Text(isoDate(d),
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
          ]),
        ),
      );

  Widget _totals(ExpenseTotals t) => Card(
        color: const Color(0xFFE8F0FE),
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${t.trips} ${t.trips == 1 ? 'trip' : 'trips'}',
                style: const TextStyle(
                    fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            _figure('Distance travelled', '${money(t.totalKm)} km', big: true),
            _figure('Total expenses', 'Rs ${money(t.totalCost)}', big: true),
            const SizedBox(height: 6),
            // Broken out because the two are asked about separately: the
            // allowance is arithmetic off the odometer and nothing to argue
            // with, while the out-of-pocket figure is the receipts the rep is
            // holding and the part that goes wrong.
            _figure('  Travel allowance', 'Rs ${money(t.travelAllowance)}'),
            _figure('  Out of pocket', 'Rs ${money(t.outOfPocket)}'),
            if (t.hasShared) ...[
              const Divider(height: 20),
              // Split out rather than buried: a shared trip's cost is not this
              // rep's alone, and a total that hid that would be claimed twice.
              Row(children: const [
                Icon(Icons.people_alt_outlined,
                    size: 15, color: Color(0xFF92400E)),
                SizedBox(width: 6),
                Text('Of which shared with other reps',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF92400E))),
              ]),
              const SizedBox(height: 4),
              _figure('Shared distance', '${money(t.sharedKm)} km',
                  colour: const Color(0xFF92400E)),
              _figure('Shared expenses', 'Rs ${money(t.sharedCost)}',
                  colour: const Color(0xFF92400E)),
              const SizedBox(height: 4),
              const Text(
                  'These trips were shared, so the amount is split between '
                  'everyone tagged on them.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF92400E))),
            ],
          ]),
        ),
      );

  Widget _figure(String label, String value,
          {bool big = false, Color? colour}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label,
              style: TextStyle(
                  fontSize: big ? 13 : 12, color: colour ?? Colors.black87)),
          Text(value,
              style: TextStyle(
                  fontSize: big ? 15 : 12.5,
                  fontWeight: big ? FontWeight.bold : FontWeight.w600,
                  color: colour)),
        ]),
      );

  Widget _tripRow(Map<String, dynamic> t) {
    final shared = isSharedTrip(t);
    final mine = t['_mine'] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: shared ? const Color(0xFFFFF8EC) : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('${t['purpose'] ?? t['name']}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            if (shared)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: const Color(0xFFFDE68A),
                    borderRadius: BorderRadius.circular(4)),
                child: const Text('SHARED',
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF92400E))),
              ),
          ]),
          const SizedBox(height: 2),
          Text(
              '${t['trip_date'] ?? ''}  ·  ${t['name']}'
              '${mine ? '' : '  ·  ${t['sales_person'] ?? ''}\'s trip'}',
              style: const TextStyle(fontSize: 11, color: Colors.black54)),
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.route, size: 14, color: Colors.black45),
            const SizedBox(width: 4),
            Text('${money(tripKm(t))} km',
                style: const TextStyle(fontSize: 12)),
            const Spacer(),
            Text('Rs ${money(tripCost(t))}',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.bold)),
          ]),
        ]),
      ),
    );
  }
}
