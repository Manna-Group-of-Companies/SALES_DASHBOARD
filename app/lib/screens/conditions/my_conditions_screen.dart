// Everything this rep owes the general manager, in one place.
//
// WHY A SCREEN OF ITS OWN
//
// The conditions were only ever visible on the customer they belonged to. That
// is the right place to see them while standing in the shop, and the wrong
// place to answer the question a rep actually has: what have I still got
// outstanding? An obligation on a shop nobody is visiting this week was
// invisible until the deadline had already gone past.
//
// So this lists them across every customer, soonest deadline first, with the
// overdue ones called out. Asked for 7 September 2026.
//
// WHO CAN DO WHAT
//
// The rep answers; only the GM closes. That is decided by
// `core/credit_condition.dart` and enforced again in `Api.decideCondition`,
// not merely hidden here — this site has no Server Script behind the screen,
// so a hidden button is a suggestion and not a permission.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/credit_condition.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/services/api.dart';

class MyConditionsScreen extends StatefulWidget {
  const MyConditionsScreen({super.key});

  @override
  State<MyConditionsScreen> createState() => _MyConditionsScreenState();
}

class _MyConditionsScreenState extends State<MyConditionsScreen> {
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await Api.myCreditConditions();
      if (mounted) {
        setState(() {
          _rows = rows;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = humanError(e);
          _loading = false;
        });
      }
    }
  }

  String _s(Map<String, dynamic> r, String k) => '${r[k] ?? ''}'.trim();

  /// The rep's answer. It moves to Awaiting Review — saying what you did is
  /// not the same as being let off, and only the GM decides the latter.
  Future<void> _respond(Map<String, dynamic> r) async {
    final ctrl = TextEditingController(text: _s(r, 'response'));
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('What have you done about it?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s(r, 'condition'),
                style: const TextStyle(fontStyle: FontStyle.italic)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Collected 40,000 on the 3rd, cheque for the rest',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'The general manager reviews this and decides whether it settles '
              'the condition.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final t = ctrl.text.trim();
              if (t.isNotEmpty) Navigator.pop(ctx, t);
            },
            child: const Text('Send for review'),
          ),
        ],
      ),
    );
    if (text == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await Api.respondToCondition(r['name'] as String, text);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sent to the general manager')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _card(Map<String, dynamic> r, DateTime today) {
    final status = _s(r, 'status');
    final due = _s(r, 'due_date');
    final late = conditionOverdue(status: status, dueDateIso: due, today: today);
    final closed = status == kCondClosed;

    final Color chipBg;
    final String chipText;
    if (late) {
      chipBg = Colors.red.shade50;
      chipText = 'Overdue';
    } else if (closed) {
      chipBg = Colors.green.shade50;
      chipText = 'Closed';
    } else if (status == kCondAwaiting) {
      chipBg = Colors.blue.shade50;
      chipText = 'Awaiting review';
    } else {
      chipBg = Colors.orange.shade50;
      chipText = 'Open';
    }

    final order = _s(r, 'sales_order');
    final setBy = _s(r, 'set_by');
    final answer = _s(r, 'response');
    final noteOnClose = _s(r, 'close_note');
    final hasDeadline = due.isNotEmpty && due != 'null';

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(_s(r, 'customer'),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: chipBg, borderRadius: BorderRadius.circular(10)),
                  child: Text(chipText, style: const TextStyle(fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(_s(r, 'condition')),
            const SizedBox(height: 8),
            Wrap(
              spacing: 14,
              runSpacing: 2,
              children: [
                // A missing deadline is said out loud rather than left blank.
                // Blank reads as a rendering fault; the rep needs to know
                // there genuinely is no date rather than assume one is hidden.
                Text(hasDeadline ? 'Due $due' : 'No deadline',
                    style: TextStyle(
                        fontSize: 12,
                        color: late ? Colors.red.shade700 : null,
                        fontWeight: late ? FontWeight.w600 : null)),
                if (order.isNotEmpty)
                  Text('Order $order', style: const TextStyle(fontSize: 12)),
                if (setBy.isNotEmpty)
                  Text('Set by $setBy', style: const TextStyle(fontSize: 12)),
              ],
            ),
            if (answer.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(6)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Your answer',
                        style: TextStyle(fontSize: 11, color: Colors.black54)),
                    const SizedBox(height: 2),
                    Text(answer),
                  ],
                ),
              ),
            ],
            if (closed && noteOnClose.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Closed: $noteOnClose',
                  style: const TextStyle(fontSize: 12)),
            ],
            // The rule, in the one place it matters: a rep may answer, never
            // close. `canMoveCondition` decides, so the button and the API
            // agree by construction rather than by memory.
            if (canMoveCondition(
                status: status, action: CondAction.respond, actor: 'rep')) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _respond(r),
                  child: Text(status == kCondAwaiting
                      ? 'Change my answer'
                      : 'Answer this'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final open = _rows.where((r) => '${r['status']}' != kCondClosed).toList();
    final overdue = open
        .where((r) => conditionOverdue(
            status: '${r['status']}',
            dueDateIso: '${r['due_date'] ?? ''}',
            today: today))
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Conditions'),
        actions: [
          IconButton(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24), child: Text(_error!)))
              : _rows.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Nothing outstanding.\n\nWhen the general manager '
                          'approves an over-limit order on terms, those terms '
                          'appear here.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        children: [
                          if (open.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                              child: Text(
                                overdue > 0
                                    ? '${open.length} outstanding · $overdue overdue'
                                    : '${open.length} outstanding',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: overdue > 0
                                        ? Colors.red.shade700
                                        : Colors.black54),
                              ),
                            ),
                          for (final r in _rows) _card(r, today),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
    );
  }
}
