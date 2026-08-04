import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/services/api.dart';

class LeaveApprovalsScreen extends StatefulWidget {
  final bool forHR;
  const LeaveApprovalsScreen({super.key, required this.forHR});
  @override
  State<LeaveApprovalsScreen> createState() => _LeaveApprovalsScreenState();
}

class _LeaveApprovalsScreenState extends State<LeaveApprovalsScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  final Map<String, Map<String, double>> _balances = {};

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    List<Map<String, dynamic>> list;
    if (widget.forHR) {
      final mgr = await Api.getPendingLeaveForHR();
      for (final m in mgr) {
        m['_action'] = true;
      }
      List<Map<String, dynamic>> team = const [];
      try {
        team = await Api.getTeamLeavesForHR();
      } catch (_) {}
      for (final tm in team) {
        tm['_action'] = false;
      }
      list = [...mgr, ...team];
    } else {
      list = await Api.getPendingLeaveForManager();
      for (final m in list) {
        m['_action'] = true;
      }
    }
    final reps = list.map((e) => '${e['sales_person']}').toSet();
    _balances.clear();
    await Future.wait(reps.map((r) async {
      try {
        _balances[r] = await Api.getLeaveBalance(r);
      } catch (_) {}
    }));
    return list;
  }

  Color _leaveStatusColor(String s) {
    if (s == 'Approved') return Colors.green;
    if (s == 'Rejected') return Colors.red;
    return Colors.orange;
  }

  void _reload() => setState(() {
        _future = _load();
      });

  Future<void> _act(Map<String, dynamic> l, bool approve) async {
    try {
      await Api.approveLeave(l['name'] as String, approve);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${approve ? 'Approved' : 'Rejected'} ${l['name']}')));
      }
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Leave Approvals'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final items = snap.data ?? [];
          if (items.isEmpty) {
            return const Center(child: Text('No leave requests pending 🎉'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            itemBuilder: (_, i) {
              final l = items[i];
              final rep = '${l['sales_person']}';
              final half = (l['half_day'] ?? 0) == 1;
              final bal = _balances[rep];
              final reason = '${l['reason'] ?? ''}';
              final rem = bal == null ? 0.0 : (bal['remaining'] ?? 0);
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          const Icon(Icons.beach_access,
                              color: Color(0xFFF46A21)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('$rep · ${l['leave_date']}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                          ),
                          Text(half
                              ? 'Half (${l['half_day_period'] ?? ''})'
                              : 'Full day'),
                        ]),
                        if (reason.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('Reason: $reason',
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.black54)),
                          ),
                        if (bal != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                                'Balance: ${(bal['taken'] ?? 0).toStringAsFixed(1)} taken · ${rem.toStringAsFixed(1)} left of 12'
                                    '${rem <= 0 ? '  ·  will be LOP' : ''}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: rem <= 0
                                        ? Colors.red
                                        : Colors.black87)),
                          ),
                        const SizedBox(height: 8),
                        if (l['_action'] == true)
                          Row(children: [
                            Expanded(
                                child: FilledButton.icon(
                                    onPressed: () => _act(l, true),
                                    icon: const Icon(Icons.check),
                                    label: const Text('Approve'))),
                            const SizedBox(width: 8),
                            Expanded(
                                child: OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.red),
                                    onPressed: () => _act(l, false),
                                    icon: const Icon(Icons.close),
                                    label: const Text('Reject'))),
                          ])
                        else
                          Row(children: [
                            Icon(Icons.circle,
                                size: 10,
                                color: _leaveStatusColor('${l['status']}')),
                            const SizedBox(width: 6),
                            Text('${l['status']}',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color:
                                    _leaveStatusColor('${l['status']}'))),
                            const Spacer(),
                            if ('${l['team_manager'] ?? ''}'.isNotEmpty)
                              Text('mgr: ${l['team_manager']}',
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.black45)),
                          ]),
                      ]),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

