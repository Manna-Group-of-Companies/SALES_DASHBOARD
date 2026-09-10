import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/leave/apply_leave_screen.dart';
import 'package:manna_field_sales/core/leave_balance.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/offline_banner.dart';

class LeaveScreen extends StatefulWidget {
  const LeaveScreen({super.key});
  @override
  State<LeaveScreen> createState() => _LeaveScreenState();
}

class _LeaveScreenState extends State<LeaveScreen> {
  late Future<({LeaveBalance balance, List<Map<String, dynamic>> leaves})>
      _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// Both reads, in parallel, and typed all the way through.
  ///
  /// This used to be a `Future.wait` returning `List<dynamic>`, and the screen
  /// pulled the balance out with `as Map<String, double>`. When the flat
  /// twelve-day allowance became the accrual scheme, the API started returning
  /// a `LeaveBalance` and that cast began throwing inside `build` — a blank
  /// screen in release, with nothing in the analyzer to show for it, because a
  /// cast from `dynamic` always compiles.
  ///
  /// Starting both futures and awaiting them separately keeps the two calls
  /// concurrent and makes each one statically typed, so the next change of
  /// shape is a compile error rather than a dark screen.
  Future<({LeaveBalance balance, List<Map<String, dynamic>> leaves})>
      _load() async {
    final me = Session.I.salesPerson ?? '__none__';
    final balanceF = Api.getLeaveBalance(me);
    final leavesF = Api.getMyLeaves();
    return (balance: await balanceF, leaves: await leavesF);
  }

  void _reload() => setState(() {
        _future = _load();
      });

  Color _statusColor(String s) {
    switch (s) {
      case 'Approved':
        return Colors.green;
      case 'Rejected':
        return Colors.red;
      default:
        return Colors.orange;
    }
  }

  /// The balance card.
  ///
  /// Takes a [LeaveBalance], not a map. It used to take `Map<String, double>`,
  /// and when the flat twelve-day allowance was replaced by the real accrual
  /// scheme the API started returning the object while this screen went on
  /// casting it to a map. The cast throws inside `build`, which in a release
  /// build is a blank screen and no message — the analyzer cannot see it,
  /// because the value arrives as `dynamic` out of a `Future.wait`.
  Widget _balanceCard(LeaveBalance b) {
    // "Not on the scheme" is not "no days left". Saying 0 to someone who was
    // never enrolled reads as "you have used them all" and would have them
    // treat every day as unpaid.
    if (!b.onScheme) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Leave balance', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text(
                'You are not on the leave accrual scheme, so no balance is '
                'held here. Speak to HR about your leave.',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ]),
        ),
      );
    }

    Widget cell(String label, String value, Color color) => Expanded(
          child: Column(children: [
            Text(value,
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.bold, color: color)),
            Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ]),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // No financial-year heading. The accrual does not reset in January
          // or in April — it runs continuously from each rep's own start date
          // — so naming a year would promise a reset that never happens.
          const Text('Leave balance',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          // Where the entitlement comes from, because a number that grows by
          // itself each month is otherwise unexplainable to the person it
          // belongs to.
          Text(
              '${b.opening.toStringAsFixed(1)} carried forward '
              '+ ${b.accrued.toStringAsFixed(0)} accrued',
              style: const TextStyle(fontSize: 11, color: Colors.black54)),
          const SizedBox(height: 12),
          Row(children: [
            cell('Entitled', b.entitlement.toStringAsFixed(1), Colors.black87),
            cell('Taken', b.taken.toStringAsFixed(1), const Color(0xFFF46A21)),
            cell('Pending', b.pending.toStringAsFixed(1), Colors.orange),
            cell('Remaining', b.remaining.toStringAsFixed(1),
                b.overdrawn ? Colors.red : Colors.green),
          ]),
          if (b.overdrawn)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                  '${(b.taken - b.entitlement).toStringAsFixed(1)} day(s) beyond '
                  'your entitlement - those are without pay (LOP).',
                  style: const TextStyle(fontSize: 12, color: Colors.red)),
            ),
          if (b.pending > 0)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                  'Pending days are shown but not deducted - a request that is '
                  'refused was never leave.',
                  style: TextStyle(fontSize: 11, color: Colors.black54)),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Leave'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Apply for Leave'),
        onPressed: () async {
          final ok = await Navigator.of(context).push<bool>(
              MaterialPageRoute(builder: (_) => const ApplyLeaveScreen()));
          if (ok == true) _reload();
        },
      ),
      body: FutureBuilder<({LeaveBalance balance, List<Map<String, dynamic>> leaves})>(
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
          final balance = snap.data!.balance;
          final leaves = snap.data!.leaves;
          return ListView(padding: const EdgeInsets.all(12), children: [
            // A remaining-days figure is exactly the sort of number somebody
            // acts on without checking, so say when it is not current.
            OfflineBanner.forKeys([CacheKeys.leaveBalance, CacheKeys.leaves]),
            _balanceCard(balance),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 8, 4, 4),
              child: Text('My leave requests',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (leaves.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No leave requests yet. Tap "Apply for Leave".',
                    style: TextStyle(color: Colors.black54)),
              )
            else
              ...leaves.map((l) {
                final status = '${l['status'] ?? ''}';
                final half = (l['half_day'] ?? 0) == 1;
                final hr = (l['is_hr_entry'] ?? 0) == 1;
                final sub = [
                  if ('${l['reason'] ?? ''}'.isNotEmpty) '${l['reason']}',
                  if (hr) 'Added by HR',
                ].join('  ·  ');
                return Card(
                  child: ListTile(
                    leading:
                    Icon(Icons.beach_access, color: _statusColor(status)),
                    title: Text('${l['leave_date'] ?? ''}'
                        '${half ? '  ·  Half day (${l['half_day_period'] ?? ''})' : ''}'),
                    subtitle: sub.isEmpty ? null : Text(sub),
                    trailing: Text(status,
                        style: TextStyle(
                            color: _statusColor(status),
                            fontWeight: FontWeight.w600)),
                  ),
                );
              }),
          ]);
        },
      ),
    );
  }
}

