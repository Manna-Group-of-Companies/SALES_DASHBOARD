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
// So this lists them across every customer, with the overdue ones called
// out. Asked for 7 September 2026. Newest first since 10 November 2026; it
// was soonest deadline first.
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
import 'package:manna_field_sales/widgets/condition_answer_sheet.dart';
import 'package:manna_field_sales/widgets/condition_ui.dart';

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

  /// Cards the rep opened or folded. Unset, a card is open while it is still
  /// owed and folded once closed.
  final Map<String, bool> _expanded = {};

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
      // Newest first (10 Nov 2026, the user): the condition the GM set last
      // is the one the rep is most likely looking for. MCC- names count up,
      // so they break a tie on the same day.
      final rows = [...await Api.myCreditConditions()]
        ..sort((a, b) {
          final byDate = _s(b, 'set_on').compareTo(_s(a, 'set_on'));
          return byDate != 0 ? byDate : _s(b, 'name').compareTo(_s(a, 'name'));
        });
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
    final text = await showConditionAnswerSheet(context,
        condition: _s(r, 'condition'), initial: _s(r, 'response'));
    if (text == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await Api.respondToCondition(r['name'] as String, text,
          salesOrder: _s(r, 'sales_order'), customer: _s(r, 'customer'));
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sent to the GM')),
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

  CondBadge _badge(String status, bool late) {
    if (late) return CondBadge.overdue;
    if (status == kCondClosed) return CondBadge.closed;
    if (status == kCondAwaiting) return CondBadge.awaiting;
    return CondBadge.open;
  }

  /// The condition's history, oldest first: the GM setting it, what the
  /// sales manager and the GM said about the order, the rep's answers, and
  /// the GM closing it.
  List<CondEvent> _events(Map<String, dynamic> r) {
    final order = _s(r, 'sales_order');
    final thread = _comments[order] ?? const <Map<String, dynamic>>[];
    final answer = _s(r, 'response');
    final setBy = _s(r, 'set_by');
    final due = _s(r, 'due_date');
    return [
      CondEvent(
        icon: Icons.flag_rounded,
        color: CondColors.orange,
        who: setBy.isNotEmpty ? setBy : 'GM',
        role: 'set this condition',
        when: condDate(_s(r, 'set_on')),
        // A missing deadline is said out loud rather than left blank. Blank
        // reads as a rendering fault; the rep needs to know there genuinely
        // is no date rather than assume one is hidden.
        text: condDate(due).isNotEmpty ? 'Due by ${condDate(due)}' : 'No deadline',
      ),
      for (final c in thread)
        // The rep's own answers sit in the thread too, since 25 Sep 2026, so
        // every answer is kept; they read as "You" rather than as the rep's
        // own name.
        if (_s(c, 'author_role') == 'Sales Rep')
          CondEvent(
            icon: Icons.person_rounded,
            color: CondColors.orange,
            who: 'You',
            when: condDate(_s(c, 'posted_on')),
            text: _s(c, 'comment'),
            mine: true,
          )
        else
          CondEvent(
            icon: _s(c, 'author_role') == 'General Manager'
                ? Icons.workspace_premium_rounded
                : _s(c, 'author_role') == 'Sales Manager'
                    ? Icons.supervisor_account_rounded
                    : Icons.chat_bubble_outline_rounded,
            color: const Color(0xFF5B5B5B),
            who: _s(c, 'author').isNotEmpty ? _s(c, 'author') : _s(c, 'author_role'),
            role: _s(c, 'author').isNotEmpty ? _s(c, 'author_role') : '',
            when: condDate(_s(c, 'posted_on')),
            text: _s(c, 'comment'),
          ),
      // Only when the thread does not already show it — an answer given
      // before answers were kept on the order exists only here.
      if (answer.isNotEmpty &&
          !thread.any((c) => _s(c, 'author_role') == 'Sales Rep' && _s(c, 'comment') == answer))
        CondEvent(
          icon: Icons.person_rounded,
          color: CondColors.orange,
          who: 'You',
          role: 'your answer',
          when: condDate(_s(r, 'responded_on')),
          text: answer,
          mine: true,
        ),
      if (_s(r, 'status') == kCondClosed)
        CondEvent(
          icon: Icons.check_circle_rounded,
          color: CondColors.green,
          who: _s(r, 'closed_by').isNotEmpty ? _s(r, 'closed_by') : 'GM',
          role: 'closed it',
          when: condDate(_s(r, 'closed_on')),
          text: _s(r, 'close_note'),
        ),
    ];
  }

  Widget _card(Map<String, dynamic> r, DateTime today, int index) {
    final name = '${r['name']}';
    final status = _s(r, 'status');
    final due = _s(r, 'due_date');
    final late = conditionOverdue(status: status, dueDateIso: due, today: today);
    final closed = status == kCondClosed;
    final order = _s(r, 'sales_order');
    final setBy = _s(r, 'set_by');
    final customer = _s(r, 'customer_name').isNotEmpty ? _s(r, 'customer_name') : _s(r, 'customer');
    final committed = _commitments[order] ?? '';
    final events = _events(r);
    final open = _expanded[name] ?? _isFocus(r);

    // The rule, in the one place it matters: a rep may answer, never close.
    // `canMoveCondition` decides, so the button and the API agree by
    // construction rather than by memory.
    final canAnswer = canMoveCondition(status: status, action: CondAction.respond, actor: 'rep');

    // A missing deadline is said out loud rather than left blank. Blank reads
    // as a rendering fault; the rep needs to know there genuinely is no date.
    final meta = [
      condDate(due).isNotEmpty ? 'Due ${condDate(due)}' : 'No deadline',
      if (setBy.isNotEmpty) 'Set by $setBy',
    ].join('  ·  ');

    // The row the rep came here for, outlined so it is found at a glance.
    final focus = _isFocus(r);

    return Container(
      key: _keys.putIfAbsent(name, () => GlobalKey()),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: BoxDecoration(
        color: CondColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: focus ? CondColors.orange : CondColors.border, width: focus ? 1.5 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Text(customer,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: CondColors.text)),
              ),
              const SizedBox(width: 8),
              CondStatusBadge(_badge(status, late)),
            ]),
            const SizedBox(height: 8),
            Text(_s(r, 'condition'),
                style: const TextStyle(fontSize: 14, height: 1.4, color: CondColors.text)),
            // The rep's own words, where the GM approved on different ones.
            if (committed.isNotEmpty && committed != _s(r, 'condition')) ...[
              const SizedBox(height: 4),
              Text('You committed: $committed',
                  style: const TextStyle(fontSize: 12.5, fontStyle: FontStyle.italic, color: CondColors.muted)),
            ],
            const SizedBox(height: 8),
            Text(meta,
                style: TextStyle(
                    fontSize: 12.5,
                    color: late ? CondColors.red : CondColors.muted,
                    fontWeight: late ? FontWeight.w600 : FontWeight.w400)),
          ]),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: CondTimeline(events: events),
          ),
        const SizedBox(height: 10),
        const Divider(height: 1, thickness: 1, color: CondColors.border),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
          child: Row(children: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: CondColors.muted),
              onPressed: () => setState(() => _expanded[name] = !open),
              child: Text(open ? 'Hide activity' : 'Activity (${events.length})',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            const Spacer(),
            if (canAnswer && !closed)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: CondColors.orange),
                onPressed: _busy ? null : () => _respond(r),
                child: Text(status == kCondAwaiting ? 'Change my answer' : 'Answer this',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _message({required IconData icon, required String title, String? body, Widget? action}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(color: CondColors.lightOrange, shape: BoxShape.circle),
              child: Icon(icon, size: 34, color: CondColors.orange),
            ),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: CondColors.text)),
            if (body != null) ...[
              const SizedBox(height: 6),
              Text(body, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13.5, color: CondColors.muted, height: 1.4)),
            ],
            if (action != null) ...[const SizedBox(height: 16), action],
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();

    final Widget body;
    if (_loading && _rows.isEmpty) {
      body = const Center(child: CircularProgressIndicator(color: CondColors.orange));
    } else if (_error != null) {
      body = _message(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load',
        body: _error,
        action: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: CondColors.orange),
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Try again'),
        ),
      );
    } else if (_rows.isEmpty) {
      body = _message(
        icon: Icons.task_alt_rounded,
        title: 'Nothing outstanding',
        body: 'Conditions the GM sets on your orders show up here.',
      );
    } else {
      // Every row is built up front, not lazily, so the one the rep was sent
      // to can be scrolled to wherever it sits. A rep's conditions run to a
      // handful, not hundreds.
      body = RefreshIndicator(
        color: CondColors.orange,
        onRefresh: _load,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Center(
            child: ConstrainedBox(
              // Phones fill the width; a tablet keeps cards readable.
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SizedBox(height: 16),
                for (var i = 0; i < _rows.length; i++) _card(_rows[i], today, i),
                const SizedBox(height: 24),
              ]),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: CondColors.background,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: CondColors.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 4,
        title: const Text('My Conditions',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: CondColors.text)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              tooltip: 'Refresh',
              style: IconButton.styleFrom(backgroundColor: CondColors.lightOrange),
              onPressed: _loading ? null : _load,
              icon: _loading && _rows.isNotEmpty
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: CondColors.orange))
                  : const Icon(Icons.refresh_rounded, color: CondColors.orange),
            ),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: CondColors.border),
        ),
      ),
      body: AnimatedSwitcher(duration: const Duration(milliseconds: 200), child: body),
    );
  }
}
