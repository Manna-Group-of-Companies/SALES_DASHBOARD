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
  /// Open on this order's row: scrolled to and outlined. Set when the rep
  /// comes here from the order's own screen, which only summarises the
  /// follow-up and links here rather than carrying the whole conversation.
  final String? focusSalesOrder;

  const MyConditionsScreen({super.key, this.focusSalesOrder});

  @override
  State<MyConditionsScreen> createState() => _MyConditionsScreenState();
}

class _MyConditionsScreenState extends State<MyConditionsScreen> {
  List<Map<String, dynamic>> _rows = const [];

  /// The order's thread, keyed by order: what the sales manager and the GM
  /// said about the commitment, the GM's notes since, and the rep's own
  /// answers. The condition is what the rep owes; this is the conversation
  /// about it, the same one the GM reads in their follow-up.
  Map<String, List<Map<String, dynamic>>> _comments = const {};

  /// What the rep originally wrote, keyed by order — shown only where the GM
  /// reworded it, so the rep can see what changed.
  Map<String, String> _commitments = const {};
  bool _loading = true;
  bool _busy = false;
  String? _error;

  /// One key per condition, so the order the rep came from can be scrolled to.
  final Map<String, GlobalKey> _keys = {};

  /// Scrolled to once, on the first load. A refresh afterwards must not yank
  /// the list back to it while the rep is reading something else.
  bool _focused = false;

  bool _isFocus(Map<String, dynamic> r) {
    final f = (widget.focusSalesOrder ?? '').trim();
    return f.isNotEmpty && _s(r, 'sales_order') == f;
  }

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
      final orders = [
        for (final r in rows)
          if (_s(r, 'sales_order').isNotEmpty) _s(r, 'sales_order')
      ];
      // Neither may cost the rep their list: the conditions are what they
      // owe, and the thread is context. A thread that will not load is left
      // off rather than failing the screen.
      final extra = await Future.wait([
        Api.creditComments(orders).catchError((_) => <Map<String, dynamic>>[]),
        Api.commitmentsFor(orders).catchError((_) => <String, String>{}),
      ]);
      final byOrder = <String, List<Map<String, dynamic>>>{};
      for (final c in extra[0] as List<Map<String, dynamic>>) {
        byOrder.putIfAbsent(_s(c, 'sales_order'), () => []).add(c);
      }
      if (mounted) {
        setState(() {
          _rows = rows;
          _comments = byOrder;
          _commitments = extra[1] as Map<String, String>;
          _loading = false;
        });
        if (!_focused) {
          _focused = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final target = rows.where(_isFocus).toList();
            if (target.isEmpty) return;
            final ctx = _keys['${target.first['name']}']?.currentContext;
            if (ctx != null) {
              Scrollable.ensureVisible(ctx,
                  duration: const Duration(milliseconds: 350),
                  alignment: 0.05);
            }
          });
        }
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
      await Api.respondToCondition(r['name'] as String, text,
          salesOrder: _s(r, 'sales_order'), customer: _s(r, 'customer'));
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

    // The row the rep came here for, outlined so it is found at a glance.
    final focus = _isFocus(r);
    return Card(
      key: _keys.putIfAbsent('${r['name']}', () => GlobalKey()),
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      shape: focus
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Colors.blue.shade600, width: 2))
          : null,
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
            // The rep's own words, where the GM approved on different ones.
            if ((_commitments[order] ?? '').isNotEmpty &&
                _commitments[order] != _s(r, 'condition')) ...[
              const SizedBox(height: 4),
              Text('You committed: ${_commitments[order]}',
                  style: const TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: Colors.black54)),
            ],
            if ((_comments[order] ?? const []).isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final c in _comments[order]!)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.fromLTRB(8, 2, 0, 2),
                  decoration: const BoxDecoration(
                      border: Border(
                          left: BorderSide(color: Colors.black12, width: 2))),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The rep's own answers sit in the thread too, since
                        // 25 Sep 2026, so every answer is kept; they read as
                        // "You" rather than as the rep's own name.
                        Text(
                            _s(c, 'author_role') == 'Sales Rep'
                                ? [
                                    'You',
                                    if (_s(c, 'posted_on').length >= 10)
                                      _s(c, 'posted_on').substring(0, 10),
                                  ].join(' · ')
                                : [_s(c, 'author'), _s(c, 'author_role')]
                                    .where((x) => x.isNotEmpty)
                                    .join(' · '),
                            style: const TextStyle(
                                fontSize: 11, color: Colors.black54)),
                        Text(_s(c, 'comment'),
                            style: const TextStyle(fontSize: 12.5)),
                      ]),
                ),
            ],
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
            // Only when the thread does not already show it — an answer given
            // before answers were kept on the order exists only here.
            if (answer.isNotEmpty &&
                !(_comments[order] ?? const []).any((c) =>
                    _s(c, 'author_role') == 'Sales Rep' &&
                    _s(c, 'comment') == answer)) ...[
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
                  // Every row is built up front, not lazily, so the one the rep
                  // was sent to can be scrolled to wherever it sits. A rep's
                  // conditions run to a handful, not hundreds.
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    ),
    );
  }
}
