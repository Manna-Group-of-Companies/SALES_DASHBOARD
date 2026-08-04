import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';

class _TargetRow {
  final String rep;
  final double target;
  final double actual;
  final String unit; // 'Currency' or 'Tonnes'
  _TargetRow(this.rep, this.target, this.actual, this.unit);
}

class ManagerTargetsScreen extends StatefulWidget {
  const ManagerTargetsScreen({super.key});
  @override
  State<ManagerTargetsScreen> createState() => _ManagerTargetsScreenState();
}

class _ManagerTargetsScreenState extends State<ManagerTargetsScreen> {
  late Future<List<_TargetRow>> _future;
  late String _month;
  late int _year;
  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = Api.monthNames[now.month - 1];
    _year = now.year;
    _future = _load();
  }

  Future<List<_TargetRow>> _load() async {
    final targets = await Api.getTargets(_month, _year);
    final amt = {
      for (final t in targets)
        t['sales_person'] as String: ((t['target_amount'] ?? 0) as num).toDouble()
    };
    final unit = {
      for (final t in targets)
        t['sales_person'] as String: (t['target_unit'] ?? 'Currency') as String
    };
    final rows = <_TargetRow>[];
    for (final rep in Session.I.teamReps) {
      final u = unit[rep] ?? 'Currency';
      // Tonnage isn't tracked yet; only currency has a real "achieved".
      final actual = u == 'Currency' ? await Api.getMonthSales(rep) : 0.0;
      rows.add(_TargetRow(rep, amt[rep] ?? 0, actual, u));
    }
    return rows;
  }

  void _reload() => setState(() { _future = _load(); });

  Future<void> _editTarget(_TargetRow row) async {
    final ctrl = TextEditingController(
        text: row.target > 0 ? row.target.toStringAsFixed(0) : '');
    String unit = row.unit;
    final cur = Api.teamCurrency; // 'INR' or 'AED'
    final saved = await showDialog<bool>(
        context: context,
        builder: (_) => StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: Text('Target — ${row.rep}'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                      value: 'Currency',
                      label: Text(cur),
                      icon: const Icon(Icons.payments)),
                  const ButtonSegment(
                      value: 'Tonnes',
                      label: Text('Tonnes'),
                      icon: Icon(Icons.scale)),
                ],
                selected: {unit},
                onSelectionChanged: (s) => setLocal(() => unit = s.first),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  prefixText: unit == 'Currency' ? '$cur ' : '',
                  suffixText: unit == 'Tonnes' ? 't' : '',
                  hintText: unit == 'Currency'
                      ? 'Monthly target amount'
                      : 'Monthly target in tonnes',
                  border: const OutlineInputBorder(),
                ),
              ),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Save')),
            ],
          ),
        ));
    if (saved != true) return;
    final v = double.tryParse(ctrl.text.trim());
    if (v == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Enter a number.')));
      }
      return;
    }
    try {
      await Api.upsertTarget(
          salesPerson: row.rep,
          month: _month,
          year: _year,
          amount: v,
          unit: unit);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Target set for ${row.rep}')));
      }
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    }
  }

  String _fmtTarget(_TargetRow r) {
    if (r.target <= 0) return '— not set';
    if (r.unit == 'Tonnes') return '${r.target.toStringAsFixed(0)} t';
    return '${Api.teamCurrency} ${r.target.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Targets · $_month $_year')),
      body: FutureBuilder<List<_TargetRow>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
                child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('Error: ${snap.error}')));
          }
          final rows = snap.data!;
          return ListView(
              padding: const EdgeInsets.all(12),
              children: rows.map((r) {
                final isCur = r.unit == 'Currency';
                final pct = (isCur && r.target > 0)
                    ? (r.actual / r.target).clamp(0.0, 1.0)
                    : 0.0;
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(
                                child: Text(r.rep,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold))),
                            if (r.target > 0)
                              Chip(
                                label: Text(r.unit == 'Tonnes'
                                    ? 'Tonnes'
                                    : Api.teamCurrency),
                                visualDensity: VisualDensity.compact,
                              ),
                            IconButton(
                                icon: const Icon(Icons.edit),
                                onPressed: () => _editTarget(r)),
                          ]),
                          Text('Target: ${_fmtTarget(r)}',
                              style: const TextStyle(
                                  fontSize: 13, color: Colors.black87)),
                          const SizedBox(height: 6),
                          if (isCur && r.target > 0) ...[
                            Text(
                                'Sales (approved POs): ${Api.teamCurrency} ${r.actual.toStringAsFixed(0)}',
                                style: const TextStyle(
                                    fontSize: 13, color: Colors.black54)),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                                value: pct,
                                minHeight: 8,
                                backgroundColor: const Color(0xFFE0E0E0)),
                            const SizedBox(height: 4),
                            Text('${(pct * 100).toStringAsFixed(0)}% of target',
                                style: const TextStyle(fontSize: 12)),
                          ] else if (r.unit == 'Tonnes' && r.target > 0)
                            const Text(
                                'Tonnage achieved isn\'t tracked yet (comes from SAP dispatch later).',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.deepOrange))
                          else
                            const Text('Tap ✎ to set a target',
                                style: TextStyle(fontSize: 12)),
                        ]),
                  ),
                );
              }).toList());
        },
      ),
    );
  }
}

// -------------------- LEADS --------------------
