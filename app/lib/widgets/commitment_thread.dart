// The rep's commitment on an over-limit order, and the conversation under it.
//
// The rep writes what the customer promised when raising the order; the sales
// manager and the GM add what they know beneath it; the GM decides with all of
// it in front of them. Shown on the order review for both, because the whole
// point is that both read the same words. The dashboard's twin is
// `client/src/features/orders/CommitmentThread.tsx`.
//
// Who may add a comment is `orderActions(...).comment`, asked again by
// `Api.addCreditComment` against the order as stored.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/credit_commitment.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';

class CommitmentThread extends StatefulWidget {
  final Map<String, dynamic> order;
  final bool overLimit;

  const CommitmentThread({
    super.key,
    required this.order,
    required this.overLimit,
  });

  @override
  State<CommitmentThread> createState() => _CommitmentThreadState();
}

class _CommitmentThreadState extends State<CommitmentThread> {
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _comments = const [];
  bool _loaded = false;
  bool _busy = false;

  String get _name => '${widget.order['name'] ?? ''}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final c = await Api.creditComments([_name]);
      if (mounted) setState(() => _comments = c);
    } catch (_) {
      // The commitment itself is on the order and still shows. A thread that
      // could not be read is not a reason to hide it.
    } finally {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _post() async {
    setState(() => _busy = true);
    try {
      await Api.addCreditComment(salesOrder: _name, comment: _ctrl.text);
      _ctrl.clear();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _s(dynamic v) {
    final s = '${v ?? ''}'.trim();
    return s == 'null' ? '' : s;
  }

  @override
  Widget build(BuildContext context) {
    final commitment = _s(widget.order['custom_credit_commitment']);
    final due = _s(widget.order['custom_credit_commitment_due']);
    final committed = hasCommitment(commitment);

    // Nothing to say on an order that never needed one and has none.
    if (!committed && !widget.overLimit && _comments.isEmpty) {
      return const SizedBox.shrink();
    }

    final role =
        orderRoleOf(isGM: Session.I.isGM, isManager: Session.I.isManager);
    final mayComment = orderActions(
            role: role,
            poStatus: widget.order['custom_po_status'],
            overLimit: widget.overLimit)
        .comment;
    final rep = _s(widget.order['custom_sales_person']);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text("The rep's commitment",
          style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      if (committed)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: const BoxDecoration(
            color: Color(0xFFFFF8E1),
            border: Border(left: BorderSide(color: Color(0xFFF9A825), width: 3)),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(commitment,
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w600, height: 1.35)),
            const SizedBox(height: 4),
            Text(
                '${rep.isEmpty ? 'The rep' : rep} · '
                '${due.isEmpty ? 'no date given' : 'to be met by $due'}',
                style: const TextStyle(fontSize: 11.5, color: Colors.black54)),
          ]),
        )
      else
        // Said out loud, so an empty space is not read as a screen that failed
        // to load. Orders raised before 24 Sep 2026 have none, and so does one
        // pushed over the limit after the rep sent it.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(6)),
          child: const Text(
              'No commitment from the rep. This order was raised before '
              'commitments were asked for, or went over the limit after it was '
              'sent. Ask the rep what the customer has promised.',
              style: TextStyle(fontSize: 12, color: Colors.deepOrange)),
        ),
      for (final c in _comments)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.fromLTRB(10, 2, 0, 2),
          decoration: const BoxDecoration(
              border: Border(left: BorderSide(color: Colors.black12, width: 2))),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                [
                  _s(c['author']),
                  _s(c['author_role']),
                  if (_s(c['posted_on']).length >= 10)
                    _s(c['posted_on']).substring(0, 10),
                ].where((x) => x.isNotEmpty).join(' · '),
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
            const SizedBox(height: 2),
            Text(_s(c['comment'])),
          ]),
        ),
      if (_loaded && mayComment) ...[
        const SizedBox(height: 10),
        TextField(
          controller: _ctrl,
          maxLines: 2,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Add what you know — payment history, what to collect first…',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: 'Add comment',
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              onPressed: _busy ? null : _post,
            ),
          ),
        ),
      ],
      if (committed) ...[
        const SizedBox(height: 6),
        const Text(
            "When the general manager approves, this becomes the rep's "
            'condition, with these comments beside it.',
            style: TextStyle(fontSize: 11.5, color: Colors.black54)),
      ],
    ]);
  }
}
