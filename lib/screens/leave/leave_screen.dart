import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/leave/apply_leave_screen.dart';
import 'package:manna_field_sales/screens/map/day_map_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/offline_banner.dart';

class LeaveScreen extends StatefulWidget {
  const LeaveScreen({super.key});
  @override
  State<LeaveScreen> createState() => _LeaveScreenState();
}

class _LeaveScreenState extends State<LeaveScreen> {
  late Future<List<dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<dynamic>> _load() async {
    final me = Session.I.salesPerson ?? '__none__';
    return Future.wait([Api.getLeaveBalance(me), Api.getMyLeaves()]);
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

  Widget _balanceCard(Map<String, double> b) {
    final fy = financialYear(DateTime.now());
    final remaining = b['remaining'] ?? 0;
    final over = remaining < 0;
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
          Text('Leave balance · FY ${fy.label}-${fy.label + 1}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(children: [
            cell('Allowance', (b['allowance'] ?? 12).toStringAsFixed(0),
                Colors.black87),
            cell('Taken', (b['taken'] ?? 0).toStringAsFixed(1),
                const Color(0xFFF46A21)),
            cell('Pending', (b['pending'] ?? 0).toStringAsFixed(1),
                Colors.orange),
            cell('Remaining', remaining.toStringAsFixed(1),
                over ? Colors.red : Colors.green),
          ]),
          if (over)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                  '${(-remaining).toStringAsFixed(1)} day(s) beyond the 12-day allowance — treated as without pay (LOP).',
                  style: const TextStyle(fontSize: 12, color: Colors.red)),
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
      body: FutureBuilder<List<dynamic>>(
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
          final balance = snap.data![0] as Map<String, double>;
          final leaves = snap.data![1] as List<Map<String, dynamic>>;
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

