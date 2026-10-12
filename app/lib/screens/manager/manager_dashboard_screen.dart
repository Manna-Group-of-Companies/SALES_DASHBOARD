// The sales manager's team, behind the Manager bar on their home screen.
//
// A sales manager works the field as well, so the home screen stays theirs and
// the team is one tap away. A tabbed workspace that opened on sign-in instead
// was tried on 11 Oct 2026 and taken back out the same day for that reason.
//
// Order approval comes first because it is the priority; location checks sit
// near the end. Targets (none set yet) and Outstanding Limits (SAP supplies
// them now) were removed on 11 Oct 2026.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/manager_scope.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/attendance/regularization_approvals_screen.dart';
import 'package:manna_field_sales/screens/leave/leave_approvals_screen.dart';
import 'package:manna_field_sales/screens/manager/manager_approvals_screen.dart';
import 'package:manna_field_sales/screens/manager/manager_customers_screen.dart';
import 'package:manna_field_sales/screens/manager/manager_orders_screen.dart';
import 'package:manna_field_sales/services/api.dart';

class ManagerDashboardScreen extends StatefulWidget {
  const ManagerDashboardScreen({super.key});
  @override
  State<ManagerDashboardScreen> createState() => _ManagerDashboardScreenState();
}

class _ManagerDashboardScreenState extends State<ManagerDashboardScreen> {
  late Future<int> _orders;
  late Future<int> _locations;

  /// What this manager may open — the same rule as the dashboard's sidebar
  /// (shared/fixtures/manager_scope.json).
  bool _can(ManagerScreen s) => canOpenAs(
      isGM: Session.I.isGM, managedTeam: Session.I.managedTeam, screen: s);

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() => setState(() {
        _orders = _countOrders();
        _locations = _countLocations();
      });

  /// Orders waiting on a decision, whatever week they were raised in — Team
  /// Orders shows one week at a time, and an old one would otherwise hide.
  Future<int> _countOrders() async =>
      (await Api.getTeamWaitingOrders()).length;

  Future<int> _countLocations() async =>
      (await countApprovals(const [ApprovalQueue.locations]))[
          ApprovalQueue.locations] ??
      0;

  void _open(Widget screen) => Navigator.push(
          context, MaterialPageRoute(builder: (_) => screen))
      .then((_) => _refresh());

  Widget _waitingSubtitle(Future<int> count, String idle,
          String Function(int n) waiting) =>
      FutureBuilder<int>(
        future: count,
        builder: (_, snap) {
          final n = snap.data;
          final busy = (n ?? 0) > 0;
          return Text(
              snap.hasError
                  ? idle
                  : n == null
                      ? 'Loading…'
                      : busy
                          ? waiting(n)
                          : idle,
              style: TextStyle(
                  color: busy ? Colors.orange.shade800 : null,
                  fontWeight: busy ? FontWeight.w600 : FontWeight.normal));
        },
      );

  Widget _card(IconData icon, String title, Widget subtitle, Widget screen) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Card(
          child: ListTile(
            leading: Icon(icon, color: const Color(0xFFF46A21)),
            title: Text(title,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: subtitle,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(screen),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final parties = _can(ManagerScreen.customers) || _can(ManagerScreen.leads);
    return Scaffold(
      appBar: AppBar(title: Text('Manager · ${Session.I.managedTeam} Team')),
      body: RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (_can(ManagerScreen.orders))
            _card(
                Icons.receipt_long,
                'Team Orders',
                _waitingSubtitle(_orders, 'All orders decided',
                    (n) => '$n order${n == 1 ? '' : 's'} waiting on you'),
                const _TeamOrdersScreen()),
          if (_can(ManagerScreen.regularizations))
            _card(
                Icons.event_available,
                'Attendance Regularizations',
                const Text('Approve your team\'s punch corrections'),
                const RegularizationApprovalsScreen(forHR: false)),
          if (_can(ManagerScreen.locations))
            _card(
                Icons.place,
                'Location Approvals',
                _waitingSubtitle(_locations, 'Nothing to verify',
                    (n) => '$n location${n == 1 ? '' : 's'} to verify'),
                const LocationApprovalsScreen()),
          _card(
              Icons.beach_access,
              'Leave Approvals',
              const Text('Approve your team\'s leave requests'),
              const LeaveApprovalsScreen(forHR: false)),
          if (parties)
            _card(
                Icons.storefront,
                'Team Customers & Leads',
                const Text('Your team\'s parties'),
                _TeamPartiesScreen(
                    showCustomers: _can(ManagerScreen.customers),
                    showLeads: _can(ManagerScreen.leads))),
          const SizedBox(height: 8),
          const Text('Team', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...Session.I.teamReps.map((r) => Card(
              child: ListTile(
                  leading: const Icon(Icons.person), title: Text(r)))),
        ]),
      ),
    );
  }
}

class _TeamOrdersScreen extends StatelessWidget {
  const _TeamOrdersScreen();
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Team Orders')),
        body: const TeamOrdersView(),
      );
}

class _TeamPartiesScreen extends StatelessWidget {
  final bool showCustomers;
  final bool showLeads;
  const _TeamPartiesScreen(
      {required this.showCustomers, required this.showLeads});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Team Customers & Leads')),
        body: TeamPartiesView(
            showCustomers: showCustomers, showLeads: showLeads),
      );
}
