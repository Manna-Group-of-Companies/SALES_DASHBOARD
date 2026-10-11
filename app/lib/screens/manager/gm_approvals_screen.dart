import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/credit.dart';
import 'package:manna_field_sales/core/credit_commitment.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/models/approval.dart';
import 'package:manna_field_sales/screens/manager/manager_order_review_screen.dart';
import 'package:manna_field_sales/widgets/gm_condition_dialog.dart';
import 'package:manna_field_sales/services/api.dart';

class GMApprovalsScreen extends StatefulWidget {
  const GMApprovalsScreen({super.key});
  @override
  State<GMApprovalsScreen> createState() => _GMApprovalsScreenState();
}

class _GMApprovalsScreenState extends State<GMApprovalsScreen> {
  late Future<List<Approval>> _future;
  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  void _reload() => setState(() { _future = _load(); });

  Future<List<Approval>> _load() async {
    final res = await Future.wait([
      Api.getPendingGMSalesOrderPOs(),
      Api.getPendingGMLeadOrderPOs(),
    ]);
    final orders = <Approval>[];
    for (final r in res[0]) {
      orders.add(Approval('Customer PO — GM approval', r['name'],
          r['custom_sales_person'], r['customer'], (r['grand_total'] ?? 0),
          'gm_so_po',
          commitment: r['custom_credit_commitment'],
          commitmentDue: r['custom_credit_commitment_due'],
          partyName: '${r['customer_name'] ?? ''}'.trim(),
          placedOn: '${r['transaction_date'] ?? ''}'.trim()));
    }
    // Longest-waiting first, as on the dashboard: an escalation holds a
    // customer's goods, and the one raised three days ago matters more.
    orders.sort((x, y) => x.placedOn.compareTo(y.placedOn));
    final out = <Approval>[...orders];
    for (final r in res[1]) {
      out.add(Approval('Lead PO — GM approval', r['name'], r['sales_person'],
          r['lead_name'], (r['total_amount'] ?? 0), 'gm_lead_po'));
    }
    // These reach the GM because the customer would go past their credit
    // limit, so the credit picture is the decision — what they owe now, what
    // this order adds, and what the limit was. Without all three the GM is
    // being asked to approve a number with nothing to weigh it against.
    await Future.wait(out.map((a) async {
      if (a.kind != 'gm_so_po') return;
      final party = (a.party ?? '').toString();
      if (party.isEmpty) return;
      a.orderTotal = (a.amount is num) ? (a.amount as num).toDouble() : 0;
      try {
        a.custOutstanding = await Api.getCustomerOutstanding(party);
        a.custLimit = await Api.getCustomerCreditLimit(party);
        // The second reason an order is here (11 Oct 2026): overdue past the
        // customer's payment terms, by the rule in core/credit.dart.
        final row = await Api.getCustomerCreditRow(party);
        if (escalationOf(row, a.orderTotal).pastTerms) {
          a.pastTerms = pastTermsPhrase(row);
        }
      } catch (_) {
        // A missing figure must not hide the approval. It is shown as unknown
        // rather than as zero, which would read as "owes nothing".
      }
    }));
    return out;
  }

  /// Opens the full order review, where the GM can change anything — the
  /// lines, the quantities, the rate, the delivery date — before deciding.
  Future<void> _open(Approval a) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ManagerOrderReviewScreen(
                orderName: a.name, isLead: a.kind == 'gm_lead_po')));
    _reload();
  }

  /// Approve on the rep's commitment, which becomes their condition.
  ///
  /// The GM's yes on an over-limit order used to leave no trace of what was
  /// promised in return, so nobody could be held to it afterwards. Asking here
  /// is what makes the condition and the approval one act. Since 24 Sep 2026
  /// the words start as the rep's own commitment, and with one on the order
  /// the condition is required — `askGmCondition` and
  /// `Api.approveEscalatedOrder` both hold that line.
  Future<void> _act(Approval a, bool approve) async {
    GmApproval? terms;
    // Only on a real Sales Order, and only on the way in. A rejection carries
    // no obligation, and a Lead Order has no customer to hang one on yet.
    if (approve && a.kind == 'gm_so_po') {
      terms = await askGmCondition(context,
          party: '${a.party}',
          rep: '${a.rep}',
          commitment: a.commitment,
          commitmentDue: a.commitmentDue);
      // Backing out is not approving.
      if (terms == null || !mounted) return;
    }

    try {
      bool? conditionSaved;
      if (a.kind == 'gm_so_po') {
        if (approve) {
          final t = terms!;
          conditionSaved = await Api.approveEscalatedOrder(a.name,
              condition: t.condition, dueDateIso: t.dueIso);
        } else {
          await Api.approveSalesOrderPO(a.name, false);
        }
      } else {
        await Api.approveLeadOrderPO(a.name, approve);
      }

      // The approval stands whatever happened to the condition — see
      // `approveEscalatedOrder` — so the order is no longer in this queue to
      // approve again. The retry writes the condition alone.
      if (conditionSaved == false && mounted) {
        final t = terms!;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 12),
          content: const Text('Approved, but the condition could not be saved.'),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => Api.addCreditCondition(
              customer: '${a.party}',
              salesPerson: '${a.rep}',
              condition: t.condition,
              dueDateIso: t.dueIso,
              salesOrder: a.name,
            ),
          ),
        ));
        _reload();
        return;
      }
      if (mounted) {
        // The GM's approval is not a push: say where the order went, so
        // nobody waits for it to turn up in SAP.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(!approve
                ? 'Rejected ${a.name}'
                : a.kind == 'gm_so_po'
                    ? 'Approved ${a.name} — back with the sales manager to push to SAP'
                    : 'Approved ${a.name}')));
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
      appBar: AppBar(title: const Text('Escalated to You'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      body: FutureBuilder<List<Approval>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text(humanError(snap.error)));
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.verified_outlined,
                      size: 44, color: Color(0xFF16794B)),
                  SizedBox(height: 10),
                  Text('Nothing escalated to you',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  SizedBox(height: 4),
                  Text(
                      'Orders that take a customer past their credit limit, or '
                      'whose customer is overdue past their payment terms, '
                      'appear here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54)),
                ]),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              _reload();
              await _future;
            },
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: items.length,
              itemBuilder: (_, i) {
                final a = items[i];
                return GmEscalationCard(
                  approval: a,
                  onOpen: () => _open(a),
                  onApprove: () => _act(a, true),
                  onReject: () => _act(a, false),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// One order escalated to the GM: who it is for, the credit picture drawn,
/// what the customer promised, and the three things the GM can do.
///
/// Its own widget so a test can lay it out at phone width — a card that
/// overflows a small phone is a card the GM cannot act on.
class GmEscalationCard extends StatelessWidget {
  const GmEscalationCard({
    super.key,
    required this.approval,
    required this.onOpen,
    required this.onApprove,
    required this.onReject,
    this.today,
  });

  final Approval approval;
  final VoidCallback onOpen;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  /// The day the waiting time is counted to; today when not given.
  final DateTime? today;

  static const _red = Color(0xFFB3261E);
  static const _amber = Color(0xFF9A6206);

  /// A figure in rupees with Indian grouping: ₹6,57,629.
  static String inr(num v) {
    final neg = v < 0;
    var digits = v.abs().round().toString();
    if (digits.length > 3) {
      final last3 = digits.substring(digits.length - 3);
      var rest = digits.substring(0, digits.length - 3);
      final groups = <String>[];
      while (rest.length > 2) {
        groups.insert(0, rest.substring(rest.length - 2));
        rest = rest.substring(0, rest.length - 2);
      }
      if (rest.isNotEmpty) groups.insert(0, rest);
      digits = '${groups.join(',')},$last3';
    }
    return '${neg ? '-' : ''}₹$digits';
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// "15 Oct" from an ISO date; the text as it came if it is not one.
  static String _day(dynamic iso) {
    final t = '${iso ?? ''}'.trim();
    final d = DateTime.tryParse(t.length >= 10 ? t.substring(0, 10) : t);
    return d == null ? t : '${d.day} ${_months[d.month - 1]}';
  }

  /// "Waiting 2 days" — how long the order has sat with the GM.
  static String waited(String placedOn, DateTime now) {
    final d = DateTime.tryParse(placedOn);
    if (d == null) return '';
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(d.year, d.month, d.day))
        .inDays;
    if (days <= 0) return 'Raised today';
    return 'Waiting $days day${days == 1 ? '' : 's'}';
  }

  /// One figure of the credit picture: a small label over the amount.
  Widget _fig(String label, double value, {Color? color}) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  fontSize: 10, letterSpacing: 0.4, color: Colors.black54)),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(inr(value),
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: color)),
          ),
        ]),
      );

  /// What is owed, what this order adds, and where the limit falls — drawn,
  /// so the GM sees how far over before reading a figure. The dashboard's
  /// queue draws the same bar (CreditBar.tsx).
  Widget _creditBar() {
    final a = approval;
    final owed = a.custOutstanding;
    final order = a.orderTotal;
    final limit = a.custLimit;
    final projected = owed + order;
    final top = [projected, limit, 1.0].reduce((x, y) => x > y ? x : y) * 1.04;
    final over = limit > 0 && projected > limit;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      double px(double v) => (v / top).clamp(0.0, 1.0) * w;
      return SizedBox(
        height: 30,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(
            left: 0,
            right: 0,
            top: 16,
            height: 10,
            child: Container(
                decoration: BoxDecoration(
                    color: const Color(0xFFEEF2F6),
                    borderRadius: BorderRadius.circular(5))),
          ),
          Positioned(
            left: 0,
            top: 16,
            height: 10,
            width: px(owed),
            child: Container(
                decoration: const BoxDecoration(
                    color: Color(0xFF76869B),
                    borderRadius:
                        BorderRadius.horizontal(left: Radius.circular(5)))),
          ),
          Positioned(
            left: px(owed),
            top: 16,
            height: 10,
            width: px(order),
            child: Container(
                decoration: BoxDecoration(
                    color: over ? _red : const Color(0xFF1F5FBF),
                    borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(5)))),
          ),
          if (limit > 0) ...[
            Positioned(
              left: px(limit) - 1,
              top: 12,
              height: 18,
              width: 2,
              child: Container(color: const Color(0xFF16212E)),
            ),
            Positioned(
              left: (px(limit) - 55).clamp(0.0, w > 110 ? w - 110 : 0.0),
              top: 0,
              width: 110,
              child: Text('Limit ${inr(limit)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w600)),
            ),
          ],
        ]),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = approval;
    final isSo = a.kind == 'gm_so_po';
    final projected = a.custOutstanding + a.orderTotal;
    final over = projected - a.custLimit;
    final isOver = a.custLimit > 0 && over > 0;
    final wait = waited(a.placedOn, today ?? DateTime.now());
    final fresh = wait.startsWith('Raised');
    final who = a.partyName.isNotEmpty ? a.partyName : '${a.party ?? ''}';
    final promised = hasCommitment(a.commitment);
    final due = '${a.commitmentDue ?? ''}'.trim();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFFDBE2EA))),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(who,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                        '${a.rep ?? '—'}  ·  ${a.name}${isSo ? '' : '  ·  Lead order'}',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.black54)),
                  ]),
            ),
            if (wait.isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: fresh
                        ? const Color(0xFFEEF2F6)
                        : const Color(0xFFFDF3E2),
                    borderRadius: BorderRadius.circular(20)),
                child: Text(wait,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: fresh ? Colors.black54 : _amber)),
              ),
            ],
          ]),
          const SizedBox(height: 12),
          // The credit picture, which is the whole reason this reached the GM.
          // Projected is the number that matters: the question is not what
          // they owe now but what they will owe once this ships.
          if (isSo) ...[
            Row(children: [
              _fig('This order', a.orderTotal),
              const SizedBox(width: 8),
              _fig('Would owe', projected),
              const SizedBox(width: 8),
              _fig(isOver ? 'Over by' : 'Credit limit',
                  isOver ? over : a.custLimit,
                  color: isOver ? _red : null),
            ]),
            const SizedBox(height: 6),
            _creditBar(),
            const SizedBox(height: 4),
            Text(
                a.custLimit <= 0
                    ? 'No credit limit set for this customer.'
                    : 'Owes ${inr(a.custOutstanding)} now · '
                        '${isOver ? '${(projected / a.custLimit * 100).round()}% of the limit' : 'within the limit'}',
                style: TextStyle(
                    fontSize: 11.5, color: isOver ? _red : Colors.black54)),
            // The second reason an order reaches the GM (11 Oct 2026).
            if (a.pastTerms.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Overdue: ${a.pastTerms}',
                    style: const TextStyle(fontSize: 11.5, color: _red)),
              ),
            // What the customer promised in return — the other half of the
            // question, so it is on the card rather than a tap away.
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(
                color:
                    promised ? const Color(0xFFFDF3E2) : const Color(0xFFF8FAFC),
                border: Border(
                    left: BorderSide(
                        color: promised ? _amber : const Color(0xFFC3CED9),
                        width: 3)),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      promised
                          ? '“${'${a.commitment}'.trim()}”'
                          : 'No commitment from the customer.',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          fontStyle:
                              promised ? FontStyle.normal : FontStyle.italic,
                          color: promised ? null : Colors.black54),
                    ),
                    if (promised && due.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text('Promised by ${_day(due)}',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.black54)),
                      ),
                  ]),
            ),
          ] else
            Text(
                'Order value ${inr((a.amount is num) ? a.amount as num : 0)}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          // Approving here is a credit decision, not a review of the order.
          // Opening it gives the GM the lines, the stock position and the
          // ability to change anything.
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open the order'),
            ),
          ),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
                child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: _red),
                    onPressed: onReject,
                    icon: const Icon(Icons.close),
                    label: const Text('Reject'))),
            const SizedBox(width: 8),
            Expanded(
                child: FilledButton.icon(
                    onPressed: onApprove,
                    icon: const Icon(Icons.check),
                    label: const Text('Approve'))),
          ]),
        ]),
      ),
    );
  }
}

// -------------------- ATTENDANCE CALENDAR --------------------
