import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/attendance/regularization_approvals_screen.dart';
import 'package:manna_field_sales/screens/leave/leave_approvals_screen.dart';
import 'package:manna_field_sales/screens/manager/manager_approvals_screen.dart';
import 'package:manna_field_sales/screens/manager/manager_orders_screen.dart';
import 'package:manna_field_sales/screens/manager/manager_limits_screen.dart';
import 'package:manna_field_sales/screens/manager/manager_targets_screen.dart';
import 'package:manna_field_sales/services/api.dart';

class ManagerDashboardScreen extends StatefulWidget {
  const ManagerDashboardScreen({super.key});
  @override
  State<ManagerDashboardScreen> createState() => _ManagerDashboardScreenState();
}

class _ManagerDashboardScreenState extends State<ManagerDashboardScreen> {
  late Future<int> _pending;
  @override
  void initState() {
    super.initState();
    _pending = _countPending();
  }

  Future<int> _countPending() async {
    final r = await Future.wait([
      Api.getPendingLeadOrderApprovals(),
      Api.getPendingLeadOrderPOs(),
      Api.getPendingSalesOrderPOs(),
      Api.getPendingProformaReleases(),
      Api.getPendingLocationVerifications(),
      Api.getPendingSiteVerifications(),
      Api.getPendingLeadLocationVerifications(),
    ]);
    return r.fold<int>(0, (s, l) => s + l.length);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Manager · ${Session.I.managedTeam} Team')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        FutureBuilder<int>(
            future: _pending,
            builder: (_, snap) {
              final n = snap.data;
              return Card(
                color: const Color(0xFF3F3F3F),
                child: ListTile(
                  leading: const Icon(Icons.inbox, color: Colors.white),
                  title: const Text('Approvals Inbox',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: Text(
                      n == null ? 'Loading…' : '$n pending request(s)',
                      style: const TextStyle(color: Colors.white70)),
                  trailing:
                  const Icon(Icons.chevron_right, color: Colors.white),
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const ManagerApprovalsScreen()))
                      .then((_) =>
                      setState(() { _pending = _countPending(); })),
                ),
              );
            }),
        const SizedBox(height: 12),
        // The approvals inbox only ever holds what is outstanding, so an order
        // vanishes from it the moment it is decided. This is where it goes.
        Card(
          child: ListTile(
            leading:
                const Icon(Icons.receipt_long, color: Color(0xFFF46A21)),
            title: const Text('Team Orders',
                style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text(
                'Approve orders, and see what happened to the ones you already '
                'decided — by week'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context,
                    MaterialPageRoute(
                        builder: (_) => const ManagerOrdersScreen()))
                .then((_) => setState(() { _pending = _countPending(); })),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.flag, color: Color(0xFFF46A21)),
            title: const Text('Targets',
                style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle:
            const Text('Set & track monthly targets for your team'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ManagerTargetsScreen())),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.account_balance_wallet,
                color: Color(0xFFD97706)),
            title: const Text('Outstanding Limits',
                style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text(
                'Set each rep\'s max outstanding (over-limit POs need GM)'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ManagerLimitsScreen())),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading:
            const Icon(Icons.event_available, color: Color(0xFFF46A21)),
            title: const Text('Attendance Regularizations',
                style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle:
            const Text('Approve your team\'s punch corrections'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                    const RegularizationApprovalsScreen(forHR: false))),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.beach_access, color: Color(0xFFF46A21)),
            title: const Text('Leave Approvals',
                style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text('Approve your team\'s leave requests'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const LeaveApprovalsScreen(forHR: false))),
          ),
        ),
        // Trip rates are an HR setting, not a sales one — they live on the HR
        // dashboard so one person owns what reps get reimbursed.
        const SizedBox(height: 20),
        const Text('Team', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ...Session.I.teamReps.map((r) => Card(
            child: ListTile(
                leading: const Icon(Icons.person), title: Text(r)))),
      ]),
    );
  }
}

