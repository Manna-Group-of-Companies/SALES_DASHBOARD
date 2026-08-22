// Conditions the GM attached to letting this customer's orders through.
//
// WHY THIS EXISTS
//
// An order over the customer's credit limit escalates to the general manager.
// The GM usually says yes — the rep needs the sale — but says yes *on terms*:
// clear the sixty-day outstanding by the fifteenth, collect a cheque before
// the next delivery. Until 22 August 2026 none of that was recorded anywhere.
// The approval went through, the terms lived in a phone call, and nobody was
// accountable for them afterwards.
//
// Now the GM types the condition at the moment of approval and it lands here,
// owned by the rep who raised the order.
//
// WHAT IT DOES NOT DO
//
// It never blocks anything. No order is refused because a condition is open or
// overdue. A rule that stopped a rep selling in front of a customer over an
// obligation somebody forgot to close would cost more than it saved, and this
// can be given teeth later once there is any evidence of how conditions
// actually behave.
//
// WHO CAN DO WHAT
//
// The rep answers; only the GM closes. The person under an obligation
// declaring it satisfied is not accountability, so the close button is the
// GM's alone — enforced in `Api.decideCondition` as well as hidden here,
// because this site has no Server Script behind the screen.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';

class CreditConditionsSection extends StatefulWidget {
  final String customer;
  const CreditConditionsSection({super.key, required this.customer});

  @override
  State<CreditConditionsSection> createState() =>
      _CreditConditionsSectionState();
}

class _CreditConditionsSectionState extends State<CreditConditionsSection> {
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await Api.creditConditions(widget.customer);
      if (mounted) setState(() { _rows = rows; _loading = false; });
    } catch (_) {
      // A customer screen must still open when this cannot be read.
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _respond(Map<String, dynamic> r) async {
    final ctrl = TextEditingController(text: '${r['response'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your response'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${r['condition'] ?? ''}',
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'What you did about it',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
              'This goes to the general manager, who decides whether it '
              'settles the condition.',
              style: TextStyle(fontSize: 11, color: Colors.black45)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Send')),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty || !mounted) return;

    setState(() => _busy = true);
    try {
      await Api.respondToCondition('${r['name']}', ctrl.text.trim());
      await _load();
      if (mounted) _snack('Sent to the general manager.');
    } catch (e) {
      if (mounted) _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decide(Map<String, dynamic> r, bool close) async {
    setState(() => _busy = true);
    try {
      await Api.decideCondition('${r['name']}', closed: close);
      await _load();
      if (mounted) _snack(close ? 'Closed.' : 'Sent back to the rep.');
    } catch (e) {
      if (mounted) _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Nothing at all when there is nothing to say. Most customers never have
    // a condition, and a permanent "No conditions" card would train everyone
    // to skip past the place the real ones appear.
    if (_loading || _rows.isEmpty) return const SizedBox.shrink();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Credit conditions',
          style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      for (final r in _rows) _card(r),
    ]);
  }

  Widget _card(Map<String, dynamic> r) {
    final status = '${r['status'] ?? 'Open'}';
    final closed = status == 'Closed';
    final due = '${r['due_date'] ?? ''}';
    // Overdue only matters while it is still owed. A condition closed late was
    // still met, and colouring it red for ever would be a permanent accusation.
    final overdue = !closed && due.isNotEmpty && due.compareTo(_today()) < 0;

    final mine = '${r['sales_person'] ?? ''}' == (Session.I.salesPerson ?? '');
    final canRespond = mine && !closed;
    final canDecide = Session.I.isGM && status == 'Awaiting Review';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: overdue ? const Color(0xFFFFEBEE) : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _chip(status, closed
                ? Colors.green.shade700
                : status == 'Awaiting Review'
                    ? Colors.orange.shade800
                    : Colors.blueGrey),
            const Spacer(),
            if (due.isNotEmpty)
              Text(
                  closed ? 'was due $due' : (overdue ? 'OVERDUE — due $due' : 'due $due'),
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: overdue ? FontWeight.bold : FontWeight.normal,
                      color: overdue ? Colors.red.shade700 : Colors.black54)),
          ]),
          const SizedBox(height: 6),
          Text('${r['condition'] ?? ''}',
              style: const TextStyle(fontSize: 13, height: 1.35)),
          const SizedBox(height: 6),
          Text(
              'Set by ${r['set_by'] ?? '—'} · owed by ${r['sales_person'] ?? '—'}'
              '${r['sales_order'] != null && '${r['sales_order']}'.isNotEmpty ? ' · ${r['sales_order']}' : ''}',
              style: const TextStyle(fontSize: 11, color: Colors.black45)),

          if ('${r['response'] ?? ''}'.trim().isNotEmpty) ...[
            const Divider(height: 16),
            const Text('Response', style: TextStyle(fontSize: 11, color: Colors.black54)),
            Text('${r['response']}', style: const TextStyle(fontSize: 12.5)),
          ],
          if ('${r['close_note'] ?? ''}'.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('GM: ${r['close_note']}',
                style: const TextStyle(
                    fontSize: 12, fontStyle: FontStyle.italic)),
          ],

          if (canRespond || canDecide) ...[
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              if (canRespond)
                TextButton(
                    onPressed: _busy ? null : () => _respond(r),
                    child: Text(status == 'Open' ? 'Respond' : 'Update response')),
              if (canDecide) ...[
                TextButton(
                    onPressed: _busy ? null : () => _decide(r, false),
                    child: const Text('Send back')),
                FilledButton(
                    onPressed: _busy ? null : () => _decide(r, true),
                    child: const Text('Close')),
              ],
            ]),
          ],
        ]),
      ),
    );
  }

  static String _today() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)}';
  }

  Widget _chip(String text, Color colour) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
            color: colour, borderRadius: BorderRadius.circular(4)),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white)),
      );
}
