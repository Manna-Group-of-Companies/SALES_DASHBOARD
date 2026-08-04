import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/services/api.dart';

class RegularizationApprovalsScreen extends StatefulWidget {
  final bool forHR;
  const RegularizationApprovalsScreen({super.key, required this.forHR});
  @override
  State<RegularizationApprovalsScreen> createState() =>
      _RegularizationApprovalsScreenState();
}

class _RegularizationApprovalsScreenState
    extends State<RegularizationApprovalsScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() => widget.forHR
      ? Api.getPendingRegularizationsForHR()
      : Api.getPendingRegularizationsForManager();

  void _reload() => setState(() {
    _future = _load();
  });

  String _fmt(dynamic dt) {
    if (dt == null) return '—';
    final d = DateTime.tryParse('$dt'.replaceFirst(' ', 'T'));
    if (d == null) return '$dt';
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _act(Map<String, dynamic> reg, bool approve) async {
    try {
      await Api.approveRegularization(reg, approve);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '${approve ? 'Approved' : 'Rejected'} ${reg['name']}')));
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
      appBar: AppBar(
          title: const Text('Attendance Regularizations'),
          actions: [
            IconButton(icon: const Icon(Icons.refresh), onPressed: _reload)
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
            return const Center(child: Text('No pending regularizations 🎉'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            itemBuilder: (_, i) {
              final r = items[i];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${r['sales_person']} · ${r['attendance_date']}',
                            style:
                            const TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 6),
                        Text(
                            'Requested:  In ${_fmt(r['requested_punch_in'])}   ·   Out ${_fmt(r['requested_punch_out'])}',
                            style: const TextStyle(fontSize: 13)),
                        if ('${r['reason'] ?? ''}'.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('Reason: ${r['reason']}',
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.black54)),
                          ),
                        const SizedBox(height: 10),
                        Row(children: [
                          Expanded(
                              child: FilledButton.icon(
                                  onPressed: () => _act(r, true),
                                  icon: const Icon(Icons.check),
                                  label: const Text('Approve'))),
                          const SizedBox(width: 8),
                          Expanded(
                              child: OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.red),
                                  onPressed: () => _act(r, false),
                                  icon: const Icon(Icons.close),
                                  label: const Text('Reject'))),
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

