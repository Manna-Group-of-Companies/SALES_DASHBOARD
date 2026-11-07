// A sales manager's monthly targets for their team, and what SAP has invoiced
// against each.
//
// Achieved means invoiced: the figure and the list under each rep come from
// the `manna_sales_targets` Server Script, which counts only order lines SAP
// has raised an A/R invoice for, dated in the month (lib/core/sales_target.dart).
// Taken off the manager's screen on 11 Oct 2026 while no targets were set, and
// put back on 3 Nov 2026 on that basis.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/sales_target.dart';
import 'package:manna_field_sales/services/api.dart';

class ManagerTargetsScreen extends StatefulWidget {
  const ManagerTargetsScreen({super.key});
  @override
  State<ManagerTargetsScreen> createState() => _ManagerTargetsScreenState();
}

class _ManagerTargetsScreenState extends State<ManagerTargetsScreen> {
  late Future<TargetMonth> _future;
  late int _monthIdx; // 0..11
  late int _year;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _monthIdx = now.month - 1;
    _year = now.year;
    _future = _load();
  }

  String get _month => kTargetMonths[_monthIdx];

  Future<TargetMonth> _load() => Api.getTargetMonth(_month, _year);

  void _reload() => setState(() {
        _future = _load();
      });

  void _shift(int by) {
    final m = _year * 12 + _monthIdx + by;
    setState(() {
      _year = m ~/ 12;
      _monthIdx = m % 12;
      _future = _load();
    });
  }

  /// Next month may be planned ahead; no further than that.
  bool get _canGoForward {
    final now = DateTime.now();
    return _year * 12 + _monthIdx <= now.year * 12 + now.month - 1;
  }

  Future<void> _editTarget(TargetRow row) async {
    final ctrl = TextEditingController(
        text: row.hasTarget ? row.targetAmount.toStringAsFixed(0) : '');
    String unit = row.unit;
    final cur = row.currency;
    final saved = await showDialog<bool>(
        context: context,
        builder: (_) => StatefulBuilder(
              builder: (ctx, setLocal) => AlertDialog(
                title: Text('Target — ${row.salesPerson}\n$_month $_year'),
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
                    autofocus: true,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      prefixText: unit == 'Currency' ? '$cur ' : '',
                      suffixText: unit == 'Tonnes' ? 't' : '',
                      hintText: unit == 'Currency'
                          ? 'Monthly target amount'
                          : 'Monthly target in tonnes',
                      helperText: 'Measured against SAP invoices',
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
    final v = double.tryParse(ctrl.text.trim().replaceAll(',', ''));
    if (v == null || v < 0) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Enter a number.')));
      }
      return;
    }
    try {
      await Api.upsertTarget(
          salesPerson: row.salesPerson,
          month: _month,
          year: _year,
          amount: v,
          unit: unit);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Target set for ${row.salesPerson}')));
      }
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    }
  }

  void _openInvoices(TargetRow r) => Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => TargetInvoicesScreen(
              row: r, title: '${r.salesPerson} · $_month $_year')));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Team Targets')),
      body: Column(children: [
        Material(
          color: Colors.grey.shade100,
          child: Row(children: [
            IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _shift(-1)),
            Expanded(
                child: Text('$_month $_year',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16))),
            IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: _canGoForward ? () => _shift(1) : null),
          ]),
        ),
        Expanded(
          child: FutureBuilder<TargetMonth>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(
                    child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(humanError(snap.error),
                            textAlign: TextAlign.center)));
              }
              final m = snap.data!;
              if (m.rows.isEmpty) {
                return const Center(
                    child: Text('No reps in your team were found.'));
              }
              return RefreshIndicator(
                onRefresh: () async => _reload(),
                child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('Achieved = SAP invoices this month (before GST).',
                            style:
                                TextStyle(fontSize: 12, color: Colors.black54)),
                      ),
                      for (final r in m.rows)
                        TargetCard(
                          row: r,
                          onEdit: m.canEdit.contains(r.salesPerson)
                              ? () => _editTarget(r)
                              : null,
                          onOpen: r.hasInvoices ? () => _openInvoices(r) : null,
                        ),
                    ]),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// One rep's target and invoiced progress. Shared by the manager's list and
/// the rep's own home card.
class TargetCard extends StatelessWidget {
  final TargetRow row;
  final String? title;
  final VoidCallback? onEdit;
  final VoidCallback? onOpen;

  const TargetCard(
      {super.key, required this.row, this.title, this.onEdit, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final r = row;
    final pct = r.fraction;
    final done = pct >= 1;
    return Card(
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.flag, color: Color(0xFFF46A21)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(title ?? r.salesPerson,
                          style: const TextStyle(fontWeight: FontWeight.bold))),
                  Text(r.hasTarget ? r.format(r.targetAmount) : 'No target',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: r.hasTarget ? null : Colors.grey)),
                  if (onEdit != null)
                    IconButton(
                        tooltip: 'Set target',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.edit),
                        onPressed: onEdit),
                ]),
                const SizedBox(height: 6),
                // Achieved always shows, 0 until something is invoiced.
                Text(
                    'Achieved (invoiced): ${r.format(r.achieved)}'
                    '${r.hasInvoices ? ' · ${r.lineCount} line${r.lineCount == 1 ? '' : 's'}' : ''}',
                    style:
                        const TextStyle(fontSize: 13, color: Colors.black87)),
                if (!r.hasInvoices)
                  const Text('No SAP invoices yet this month',
                      style: TextStyle(fontSize: 12, color: Colors.black54)),
                // What the rep's customers owe today, from SAP.
                Text.rich(TextSpan(
                    style: const TextStyle(fontSize: 13, color: Colors.black87),
                    children: [
                      TextSpan(text: 'Outstanding: ${r.money(r.outstanding)}'),
                      if (r.overdue > 0)
                        TextSpan(
                            text: '  ·  ${r.money(r.overdue)} overdue',
                            style: const TextStyle(color: Colors.red)),
                    ])),
                ...[
                  if (r.hasTarget) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                          value: pct.clamp(0.0, 1.0),
                          minHeight: 8,
                          color: done ? Colors.green : null,
                          backgroundColor: const Color(0xFFE0E0E0)),
                    ),
                    const SizedBox(height: 4),
                    Text('${(pct * 100).toStringAsFixed(0)}% of target',
                        style: TextStyle(
                            fontSize: 12,
                            color: done ? Colors.green.shade800 : null,
                            fontWeight:
                                done ? FontWeight.bold : FontWeight.normal)),
                  ],
                  if (onOpen != null)
                    const Align(
                        alignment: Alignment.centerRight,
                        child: Text('See invoices ›',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFFF46A21)))),
                ],
              ]),
        ),
      ),
    );
  }
}

/// The invoiced lines behind a rep's figure, newest invoice first.
class TargetInvoicesScreen extends StatelessWidget {
  final TargetRow row;
  final String title;
  const TargetInvoicesScreen(
      {super.key, required this.row, required this.title});

  @override
  Widget build(BuildContext context) {
    final lines = row.lines.reversed.toList();
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: lines.length + 1,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                  'Total invoiced: ${row.format(row.achieved)}'
                  '${row.isTonnes ? '  (${row.currency} ${row.invoicedAmount.toStringAsFixed(0)})' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            );
          }
          final l = lines[i - 1];
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(l.customerName.isEmpty ? 'Invoice ${l.invoice}' : l.customerName),
            subtitle: Text('Invoice ${l.invoice} · ${l.invoiceDate}\n'
                '${l.itemName}'),
            isThreeLine: true,
            trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${row.currency} ${l.amount.toStringAsFixed(0)}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('${l.kg.toStringAsFixed(1)} kg',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.black54)),
                ]),
          );
        },
      ),
    );
  }
}
