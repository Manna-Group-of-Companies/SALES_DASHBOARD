import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';

class ManagerLimitsScreen extends StatefulWidget {
  const ManagerLimitsScreen({super.key});
  @override
  State<ManagerLimitsScreen> createState() => _ManagerLimitsScreenState();
}

class _LimitRow {
  final String rep;
  final double limit;
  final double outstanding;
  _LimitRow(this.rep, this.limit, this.outstanding);
}

class _ManagerLimitsScreenState extends State<ManagerLimitsScreen> {
  late Future<List<_LimitRow>> _future;
  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  void _reload() => setState(() { _future = _load(); });

  Future<List<_LimitRow>> _load() async {
    final rows = <_LimitRow>[];
    for (final rep in Session.I.teamReps) {
      final lim = await Api.getRepOutstandingLimit(rep);
      final out = await Api.getRepOutstanding(rep);
      rows.add(_LimitRow(rep, lim, out));
    }
    return rows;
  }

  Future<void> _edit(_LimitRow row) async {
    final ctrl = TextEditingController(
        text: row.limit > 0 ? row.limit.toStringAsFixed(0) : '');
    final cur = Api.teamCurrency;
    final saved = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('Outstanding limit — ${row.rep}'),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                prefixText: '$cur ',
                hintText: 'Max allowed outstanding',
                border: const OutlineInputBorder()),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save')),
          ],
        ));
    if (saved != true) return;
    final v = double.tryParse(ctrl.text.trim());
    if (v == null) return;
    try {
      await Api.upsertOutstandingLimit(row.rep, v);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Limit set for ${row.rep}')));
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
    final cur = Api.teamCurrency;
    return Scaffold(
      appBar: AppBar(title: const Text('Outstanding Limits')),
      body: FutureBuilder<List<_LimitRow>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text(humanError(snap.error)));
          }
          final rows = snap.data!;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                    'Set the maximum collection-outstanding each rep is allowed. '
                        'When a rep goes over their limit, approving their POs needs General Manager sign-off.',
                    style: TextStyle(fontSize: 12, color: Colors.black54)),
              ),
              ...rows.map((r) {
                final over = r.limit > 0 && r.outstanding > r.limit;
                return Card(
                  child: ListTile(
                    title: Text(r.rep),
                    subtitle: Text(
                        'Outstanding: $cur ${r.outstanding.toStringAsFixed(0)}'
                            '${r.limit > 0 ? '   ·   Limit: $cur ${r.limit.toStringAsFixed(0)}' : '   ·   No limit set'}',
                        style: TextStyle(
                            color: over ? Colors.red : Colors.black54)),
                    trailing: IconButton(
                        icon: const Icon(Icons.edit), onPressed: () => _edit(r)),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}

