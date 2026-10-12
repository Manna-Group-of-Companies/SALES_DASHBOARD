// What the sales manager sees before an order is allowed anywhere near
// production.
//
// Approving used to be a yes/no on a card in a list, which is a thin basis for
// a decision that fixes the price permanently and commits stock. This screen
// puts the three things that decision actually depends on in front of them:
//
//   - what the customer already owes, against their limit;
//   - what each line is drawing from minimum stock, who is holding it, and
//     whether there is older stock of the same product that should go out
//     instead;
//   - whether *each line* deserves the held-back stock, or should wait for a
//     production run.
//
// That last decision is per line and not per order. An order can carry six
// products that are all on the minimum-stock list, and the manager may want two
// of them out of the pool today and the rest made to order.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/credit.dart';
import 'package:manna_field_sales/core/credit_commitment.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/core/sap_order_state.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/widgets/commitment_thread.dart';
import 'package:manna_field_sales/widgets/gm_condition_dialog.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/screens/orders/order_screen.dart';
import 'package:manna_field_sales/models/order_ref.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/sync_all_button.dart';

class ManagerOrderReviewScreen extends StatefulWidget {
  final String orderName;

  /// True for an order taken against a lead. The review is the same — same
  /// lines, same minimum stock, same per-line fulfilment decision — but
  /// approving one also converts the lead and raises the Sales Order, and it
  /// is refused until the lead is complete enough to invoice.
  final bool isLead;

  const ManagerOrderReviewScreen({
    super.key,
    required this.orderName,
    this.isLead = false,
  });

  @override
  State<ManagerOrderReviewScreen> createState() =>
      _ManagerOrderReviewScreenState();
}

class _ManagerOrderReviewScreenState extends State<ManagerOrderReviewScreen> {
  late Future<void> _init;
  Map<String, dynamic> _order = {};
  Map<String, dynamic> _customer = {};
  Map<String, MinStock> _stock = {};
  Map<String, Product> _products = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init = _load();
    SapSyncAll.epoch.addListener(_reload);
  }

  @override
  void dispose() {
    SapSyncAll.epoch.removeListener(_reload);
    super.dispose();
  }

  /// Fresh figures after a sync, so the credit picture the decision rests on
  /// is SAP's latest rather than what the screen opened with.
  void _reload() {
    if (mounted && !_busy) setState(() => _init = _load());
  }

  /// What a lead order is still missing before it can be approved. Empty for a
  /// customer order, and for a lead that is already complete.
  List<String> _missing = const [];

  bool get _isLead => widget.isLead;

  Future<void> _load() async {
    _order = _isLead
        ? await Api.getLeadOrder(widget.orderName)
        : await Api.getOrder(widget.orderName);

    final party = _isLead ? '${_order['lead']}' : '${_order['customer']}';
    final results = await Future.wait([
      _isLead ? Api.getLeadDoc(party) : Api.getCustomerDoc(party),
      Api.getMinimumStock(),
      Api.getItems(),
    ]);
    _customer = results[0] as Map<String, dynamic>;
    _stock = results[1] as Map<String, MinStock>;
    _products = {
      for (final d in results[2] as List<Map<String, dynamic>>)
        '${d['name']}': Product(d)
    };
    // A lead becomes a customer at approval and is invoiced straight after, so
    // it has to carry what an invoice needs before the manager can say yes.
    _missing = _isLead ? missingLeadDetails(_customer) : const [];
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  List<Map<String, dynamic>> get _items =>
      ((_order['items'] as List?) ?? []).cast<Map<String, dynamic>>();

  /// What the customer owes and may owe, read the way [creditEscalates] reads
  /// them: the stored total, or the buckets when SAP left the total at zero.
  /// Reading the stored total alone (until 26 Sep 2026) offered Approve on an
  /// order the save then refused as over the limit — and never Send to GM — so
  /// such an order could not move at all.
  double get _outstanding => agingOf(_customer).total;
  double get _limit => agingOf(_customer).creditLimit;
  /// What a line is worth.
  ///
  /// It went through `lineAfterDiscount` until 17 September 2026, which
  /// preferred the stored `amount` and fell back to qty x rate. The same
  /// fallback applies, and for the same reason — `amount` is not always
  /// written on a custom child table — but there is no discount to apply.
  static double _lineAmount(Map<String, dynamic> it) {
    final amount = _num(it['amount']);
    if (amount > 0) return amount;
    return _num(it['qty']) * _num(it['rate']);
  }

  /// What the customer will be invoiced. The credit limit is checked against
  /// this, and the rep's rate is already the rate after discount.
  double get _orderTotal =>
      _items.fold<double>(0, (sum, it) => sum + _lineAmount(it));

  /// What the customer would owe if this order shipped. The limit question is
  /// not "do they owe too much now" but "will they after this".
  double get _projected => _outstanding + _orderTotal;
  bool get _overLimit => _limit > 0 && _projected > _limit;

  /// A decision is outstanding unless the order is actually approved. Read off
  /// the status rather than the rate flag: a rep who edits an approved order
  /// sends it back here, and it has to look like work to do again.
  ///
  /// A lead order keeps its decision in `status`, so it is asked through
  /// [orderSignedOff]; read as a Sales Order it looked undecided for ever and
  /// offered Approve again, which raises a second Sales Order.
  bool get _approved =>
      _isLead ? orderSignedOff(_order, isLead: true) : orderApproved(_order);

  bool get _rejected =>
      '${_isLead ? _order['status'] : _order['custom_po_status']}'.trim() ==
      'Rejected';

  /// True when the sales manager cannot finish this alone.
  ///
  /// Over the customer's credit limit is a decision about how much this
  /// business is willing to be owed, which is above a sales manager. A lead has
  /// no limit and no trading history, so there is nothing to be over — and a
  /// GM asked to approve credit for a party nobody has ever invoiced would be
  /// deciding on no information at all.
  ///
  /// Since 11 Oct 2026 also when the customer has invoices overdue past their
  /// payment terms (credit.json `past_terms`), limit or no limit.
  bool get _escalates => !_isLead && (_overLimit || _pastTerms);

  /// Overdue past the customer's SAP payment terms — the second reason an
  /// order goes to the GM. Read through core/credit.dart, like the limit.
  bool get _pastTerms => escalationOf(_customer, _orderTotal).pastTerms;

  /// The GM has approved the credit and handed the order back: the sales
  /// manager's one move is Push to SAP, and the credit figures no longer send
  /// it anywhere else.
  bool get _gmApproved =>
      !_isLead && '${_order['custom_po_status']}' == kPoFinalApproval;

  /// What this login may do to the order, by the rule the dashboard and
  /// `Api.approveSalesOrderPO` also apply (credit_commitment.json). The GM
  /// approves what reaches them rather than being offered "Send to GM" on an
  /// order already escalated to them; a sales manager never approves an
  /// over-limit order, and once it is with the GM does not decide it at all.
  OrderActions get _acts => orderActions(
      role: orderRoleOf(isGM: Session.I.isGM, isManager: Session.I.isManager),
      poStatus: _order['custom_po_status'],
      overLimit: _escalates);

  bool get _cancelled =>
      !_isLead && cancelledInSap(SapOrderState.fromOrder(_order));

  /// Cancelled outranks approved: an order SAP cancelled after approval was
  /// shown in approval green until 11 Oct 2026, and read as good news.
  Color get _statusColour => _cancelled || _rejected
      ? Colors.red.shade700
      : _approved
          ? Colors.green.shade700
          : Colors.orange.shade800;

  static double _num(dynamic v) =>
      v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

  /// Frappe reads an unset field back as null, '' or the string 'null'.
  static String _s(dynamic v) {
    final s = '${v ?? ''}'.trim();
    return s == 'null' ? '' : s;
  }
  static int _int(dynamic v) =>
      v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);

  // ------------------------------------------------------------ actions ---

  Future<void> _edit() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => OrderScreen(
                party: _isLead
                    ? OrderParty.lead(_customer.isNotEmpty
                        ? _customer
                        : {'name': _order['lead']})
                    : OrderParty.customer(_customer.isNotEmpty
                        ? _customer
                        : {'name': _order['customer']}),
                existingOrder: _order,
              )),
    );
    if (mounted) setState(() => _init = _load());
  }

  // Switching a line between minimum stock and new production was removed:
  // the pool goes to whoever booked it first, so there was never really a
  // choice to make here. `Api.setLineFulfilmentMode` is left in place — it is
  // still the only correct way to move a line between the two pools, should a
  // reason to do that deliberately ever appear.

  /*
   * `_editDiscount` stood here until 17 September 2026.
   *
   * It asked for a percentage rather than a rate — a manager negotiating says
   * "give them five percent", and making them work out 6,976.80 from 7,344 by
   * hand is how the wrong number gets typed — and wrote it straight away.
   *
   * The feature is gone from both apps. The rep types the rate AFTER discount,
   * so the rate on the line is the whole price and a manager who wants to move
   * it edits the rate.
   */

  /// The GM's approval of a customer order: on the rep's commitment, which
  /// becomes their condition. The dialog is the confirmation. It does not
  /// push to SAP — the order goes back to the sales manager, who does.
  Future<void> _gmApprove() async {
    final terms = await askGmCondition(context,
        party: '${_customer['customer_name'] ?? _order['customer'] ?? ''}',
        rep: '${_order['custom_sales_person'] ?? 'the rep'}',
        commitment: _order['custom_credit_commitment'],
        commitmentDue: _order['custom_credit_commitment_due']);
    if (terms == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final saved = await Api.approveEscalatedOrder(widget.orderName,
          condition: terms.condition, dueDateIso: terms.dueIso);
      if (!mounted) return;
      if (saved == false) {
        // The approval stands, so the order will not come back to be approved
        // again. The retry writes the condition alone, and outlives this
        // screen because the messenger belongs to the app.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 12),
          content: const Text('Approved, but the condition could not be saved.'),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => Api.addCreditCondition(
              customer: '${_order['customer']}',
              salesPerson: '${_order['custom_sales_person']}',
              condition: terms.condition,
              dueDateIso: terms.dueIso,
              salesOrder: widget.orderName,
            ),
          ),
        ));
      } else {
        _snack(saved == true
            ? 'Approved — back with the sales manager to push to SAP. The '
                'condition is on the rep’s phone.'
            : 'Approved — back with the sales manager to push to SAP.');
      }
      Navigator.pop(context, true);
    } catch (e) {
      _snack(humanError(e));
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decide(bool approve) async {
    // A lead that cannot be invoiced cannot be approved. Refused here rather
    // than left to fail deep inside the conversion, so the manager is told
    // exactly what to chase the rep for.
    if (approve && _isLead && _missing.isNotEmpty) {
      _snack('Cannot approve — the lead still needs its '
          '${_missing.join(', ').toLowerCase()}.');
      return;
    }

    if (approve && !_isLead && Session.I.isGM) return _gmApprove();

    // Over the limit escalates — unless the GM has already approved it, when
    // the only thing left is the push.
    final escalating = approve && _escalates && !_gmApproved;

    // Asked before anything is written. Kept to a line each: the screen
    // above already shows what the decision rests on.
    String gmNote = '';
    if (approve && _gmApproved) {
      final by = _s(_order['custom_gm_approved_by']);
      final ok = await _confirm('Push to SAP?',
          '${by.isEmpty ? 'The GM' : by} approved the credit. Rates become final.');
      if (ok != true) return;
    } else if (escalating) {
      final note = await _askGmNote();
      if (note == null) return;
      gmNote = note;
    } else if (approve) {
      final ok = await _confirm(
        _isLead ? 'Approve and convert?' : 'Approve this order?',
        [
          if (_isLead) 'The lead becomes a customer.',
          if (_overLimit) 'This takes the customer past their credit limit.',
          'Rates become final.',
        ].join(' '),
      );
      if (ok != true) return;
    } else {
      final withdrawing = Session.I.isGM && _gmApproved;
      final ok = await _confirm(
          withdrawing ? 'Withdraw your approval?' : 'Reject this order?',
          'It goes back to the rep.',
          action: withdrawing ? 'Withdraw' : 'Reject',
          destructive: true);
      if (ok != true) return;
    }

    setState(() => _busy = true);
    try {
      if (_isLead) {
        final customer = await Api.approveLeadOrder(widget.orderName, approve);
        _snack(approve
            ? (customer == null
                ? 'Approved.'
                : 'Approved — converted to customer $customer.')
            : 'Rejected.');
        if (mounted) Navigator.pop(context, true);
        return;
      }
      if (escalating) {
        // The note first, as the dashboard does: the GM reads the thread when
        // the order lands, so it has to be there before it does.
        if (gmNote.isNotEmpty) {
          await Api.addCreditComment(
              salesOrder: widget.orderName, comment: gmNote);
        }
        await Api.escalateSalesOrderPOToGM(widget.orderName);
        _snack('Sent to the GM.');
      } else {
        await Api.approveSalesOrderPO(widget.orderName, approve);
        _snack(approve
            ? (_gmApproved ? 'Pushed to SAP.' : 'Approved.')
            : 'Rejected.');
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _snack(humanError(e));
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirm(String title, String body,
          {String action = 'Continue', bool destructive = false}) =>
      showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                style: destructive
                    ? FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFB3261E))
                    : null,
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(action)),
          ],
        ),
      );

  /// Send to GM, with an optional note for them. Null when cancelled; blank
  /// when sent without one.
  Future<String?> _askGmNote() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send to GM?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(escalationReason(_customer, _orderTotal)),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            maxLines: 3,
            minLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
                hintText: 'Note for the GM (optional)',
                border: OutlineInputBorder()),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Send to GM')),
        ],
      ),
    );
  }

  /// Takes back a rejection — the dashboard's Undo rejection. The order goes
  /// back to waiting on the manager.
  Future<void> _undoReject() async {
    setState(() => _busy = true);
    try {
      await Api.undoOrderRejection(widget.orderName);
      _snack('Rejection undone.');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _snack(humanError(e));
      if (mounted) setState(() => _busy = false);
    }
  }

  // -------------------------------------------------------------- build ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.orderName),
        actions: const [SyncAppBarButton(), SizedBox(width: 4)],
      ),
      body: FutureBuilder<void>(
        future: _init,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
                child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(humanError(snap.error))));
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            Row(children: [
              Expanded(
                child: Text(
                    _isLead
                        ? '${_customer['company_name'] ?? _customer['lead_name'] ?? _order['lead'] ?? ''}'
                        : '${_customer['customer_name'] ?? _order['customer'] ?? ''}',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
              ),
              if (_isLead)
                const Chip(
                    label: Text('Lead', style: TextStyle(fontSize: 11)),
                    backgroundColor: Color(0xFFE0E7FF),
                    visualDensity: VisualDensity.compact),
            ]),
            const SizedBox(height: 2),
            Text(
                [
                  if (_s(_order['custom_sap_sales_order']).isNotEmpty)
                    'SAP ${_s(_order['custom_sap_sales_order'])}',
                  '${_order['custom_sales_person'] ?? _order['sales_person'] ?? '—'}',
                  if (_s(_order['delivery_date']).isNotEmpty)
                    'Delivery ${_s(_order['delivery_date'])}',
                ].join('  ·  '),
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            Text(
                _isLead
                    ? '${_order['status'] ?? ''}'
                    : orderApprovalLabel(_order['custom_po_status'],
                        SapOrderState.fromOrder(_order)),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _statusColour)),
            // How much this order has been churned before it reached approval.
            // An order rewritten five times is worth a second look at, and the
            // manager had no way to tell one from an order raised once.
            if (editCountLabel(_int(_order['custom_edit_count'])).isNotEmpty)
              Text(editCountLabel(_int(_order['custom_edit_count'])),
                  style: const TextStyle(
                      fontSize: 12, color: Colors.black54)),
            if (_missing.isNotEmpty) ...[
              const SizedBox(height: 12),
              _missingCard(),
            ],
            const SizedBox(height: 12),
            _creditCard(),
            // Straight under the credit picture it answers. Keyed on the
            // order's `modified`, so a reload after an edit re-reads the thread.
            if (!_isLead) ...[
              const SizedBox(height: 12),
              CommitmentThread(
                  key: ValueKey('${_order['modified']}'),
                  order: _order,
                  overLimit: _escalates),
            ],
            const SizedBox(height: 16),
            const Text('Lines', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            for (final it in _items) _lineCard(it),
            const SizedBox(height: 8),
            _totalsBlock(),
            const SizedBox(height: 8),
            // Why a locked order is locked was spelled out here. The status
            // line at the top already says it — approved, with the GM,
            // cancelled — and the paragraph was clutter on a phone.
            if (canEditOrder(_order))
              OutlinedButton.icon(
                onPressed: _busy ? null : _edit,
                icon: const Icon(Icons.edit),
                label: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('Add / Remove / Requantify')),
              ),
            const Divider(height: 28),
            _decisionSection(),
            if (_busy)
              const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: Center(child: CircularProgressIndicator())),
          ]);
        },
      ),
    );
  }

  /// Outstanding against limit, projected forward. A manager approving an order
  /// is extending credit, so the number that matters is what the customer will
  /// owe once it ships, not what they owe today.
  /// What the lead still owes the office before this can be approved.
  ///
  /// Named plainly and placed above everything else, because it is the one
  /// thing that will stop the approval and the manager should see it before
  /// they have read the lines and made up their mind.
  Widget _missingCard() => Card(
        color: const Color(0xFFFFF1F0),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.report_problem_outlined,
                  size: 18, color: Color(0xFFB3261E)),
              SizedBox(width: 8),
              Text('Cannot approve yet',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 8),
            Text('Missing on the lead: ${_missing.join(', ')}.',
                style: const TextStyle(fontSize: 13, height: 1.4)),
          ]),
        ),
      );

  Widget _creditCard() {
    // A lead has no trading history and no limit, so there is nothing to be
    // within. A green "Within credit limit" against a party who has never been
    // invoiced is a reassurance nobody earned, and the manager might read it as
    // a check that passed rather than one that was never run.
    if (_isLead) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: const Color(0xFFF1F3F4),
            borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.receipt_long, size: 18, color: Colors.black54),
            const SizedBox(width: 6),
            Text('Rs ${_orderTotal.toStringAsFixed(0)}',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16)),
          ]),
          const SizedBox(height: 4),
          const Text(
              'New party — no trading history or credit limit to check against.',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
        ]),
      );
    }

    final flagged = _overLimit || _pastTerms;
    final colour = flagged ? Colors.red : Colors.green;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: flagged ? const Color(0xFFFFEBEE) : const Color(0xFFE8F5E9),
          borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(flagged ? Icons.warning_amber_rounded : Icons.check_circle,
              size: 18, color: colour),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                _overLimit && _pastTerms
                    ? 'Over credit limit and overdue past terms'
                    : _overLimit
                        ? 'Over credit limit'
                        : _pastTerms
                            ? 'Overdue past payment terms'
                            : 'Within credit limit',
                style: TextStyle(fontWeight: FontWeight.bold, color: colour)),
          ),
        ]),
        // The second reason an order goes to the GM (11 Oct 2026), in words.
        if (_pastTerms)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('${pastTermsPhrase(_customer)}.',
                style: const TextStyle(fontSize: 12.5, color: Colors.red)),
          ),
        const SizedBox(height: 6),
        _kv('Owes now', 'Rs ${_outstanding.toStringAsFixed(0)}'),
        // One figure. It was a before-and-after pair where the order carried a
        // discount, because the manager was deciding two things at once —
        // whether the customer could carry it, and what was being given away
        // to win it. The discount feature went on 17 September 2026 and the
        // rep's rate is already net, so there is only the first question.
        _kv('This order', 'Rs ${_orderTotal.toStringAsFixed(0)}'),
        _kv('Would owe', 'Rs ${_projected.toStringAsFixed(0)}'),
        _kv('Credit limit',
            _limit > 0 ? 'Rs ${_limit.toStringAsFixed(0)}' : 'none set'),

        /*
         * How old the debt is, added 21 August 2026. "Owes now" alone answers
         * only half the question a manager is actually asking: forty thousand
         * owed for three weeks and forty thousand owed for six months are the
         * same figure and not remotely the same decision.
         *
         * Shown, never enforced — the credit rule is still the total against
         * the limit, exactly as core/credit.dart has it, and nothing here
         * blocks an order.
         */
        const SizedBox(height: 10),
        const Text('How old it is',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        _agingRow(),
      ]),
    );
  }

  /// The four SAP buckets, oldest last and only the oldest coloured.
  ///
  /// Reads through core/credit.dart so the phone and the dashboard cannot
  /// disagree about what "not synced" means — pinned by
  /// shared/fixtures/credit.json.
  Widget _agingRow() {
    final a = agingOf(_customer);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(
        children: a.buckets
            .map((b) => Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 8),
                    decoration: BoxDecoration(
                      color: (b.overdue && a.bucketsKnown)
                          ? const Color(0xFFFFEBEE)
                          : const Color(0xFFF7F7F8),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(b.label,
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.black54)),
                          const SizedBox(height: 3),
                          // A dash, not a zero, when nothing has synced.
                          Text(
                              a.bucketsKnown
                                  ? 'Rs ${b.amount.toStringAsFixed(0)}'
                                  : kAgingNoData,
                              style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.bold,
                                  color: (b.overdue && a.bucketsKnown)
                                      ? Colors.red.shade700
                                      : null)),
                        ]),
                  ),
                ))
            .toList(),
      ),
      if (!a.bucketsKnown)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(kAgingNotSynced,
              style: const TextStyle(fontSize: 11, color: Colors.black45)),
        ),
      if (a.mismatch)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(kAgingMismatch,
              style: TextStyle(fontSize: 11, color: Colors.orange.shade900)),
        ),
    ]);
  }

  Widget _lineCard(Map<String, dynamic> it) {
    final code = '${it['item_code']}';
    final s = _stock[code];
    final p = _products[code];
    final unit = p?.category.stockUnit ?? 'units';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: Text('${it['item_name'] ?? code}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600))),
            // One figure. The full price used to sit struck through above the
            // discounted one, so a manager could see what was given away — but
            // the rate the rep types is already the rate after discount.
            Text('Rs ${_lineAmount(it).toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 2),
          Text(
              '${it['custom_packing_note'] ?? ''}'
              '${_num(it['custom_rate_per_kg']) > 0 ? '  ·  Rs ${trimQty(_num(it['custom_rate_per_kg']))}/kg' : ''}',
              style: const TextStyle(fontSize: 11, color: Colors.black54)),
          // "Rate final", "made to order" and where the line is served from
          // were each a line here until 11 Oct 2026. SAP commits stock when
          // the order reaches it, so none of them was a decision for the
          // manager, and on a phone they buried the figures that are.
          if (s != null) ...[
            const Divider(height: 14),
            _stockBreakdown(s, unit, it),
          ],
        ]),
      ),
    );
  }

  /// The order total.
  ///
  /// It was a green panel with a before/after/percentage breakdown whenever
  /// any line carried a discount — "3 of 5 lines discounted" and all. The
  /// discount feature went on 17 September 2026 and the rep's rate is already
  /// net, so there is one figure.
  Widget _totalsBlock() =>
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Order total',
            style: TextStyle(fontWeight: FontWeight.bold)),
        Text('Rs ${_orderTotal.toStringAsFixed(2)}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ]);

  /*
   * `_totalRow` and `_discountRow` stood here.
   *
   * `_discountRow` showed the concession on a line and the way to change it,
   * becoming a plain "10% off — Rs 875 to Rs 787.50. Final." once the order
   * was approved. Both went with the feature on 17 September 2026.
   */


  /// What was asked for against what SAP has.
  ///
  /// This used to attribute bookings — how much of the pool this very order
  /// was holding, and how much every other order was. There are no bookings
  /// left to attribute: SAP commits stock against its own sales orders, and
  /// the figure below already has every one of them taken off it. The manager
  /// is shown the two numbers the decision actually turns on.
  Widget _stockBreakdown(MinStock s, String unit,
      [Map<String, dynamic>? item]) {
    final orderedRolls = item == null ? 0.0 : _num(item['custom_rolls']);
    final orderedBelts = item == null ? 0 : _int(item['custom_loose_belts']);
    final short = orderedRolls - s.availableQty;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (item != null)
        _dot('Ordered', s.describe(orderedRolls, orderedBelts, unit),
            Colors.black87,
            bold: true),
      if (!s.weightsKnown)
        _dot('In stock', 'not set up for this item', Colors.black45)
      else
        _dot('Available in SAP',
            s.describe(s.availableQty, s.availableLooseBelts, unit),
            s.availableQty <= 0 ? Colors.red : Colors.green),
      // Only when the order is bigger than the shelf. Below that the manager
      // needs no prompting, and a "0 to be made" row on every covered line is
      // noise on a screen that is already dense.
      if (item != null && s.weightsKnown && short > 0.0001)
        _dot('Short by', s.describe(short, 0, unit), Colors.deepPurple,
            bold: true),
      // A "last sold" line, reddened when the item was drifting towards dead
      // stock, stood here until 21 August 2026. Removed with the rest of the
      // dead-stock feature; approving an order is not the moment to weigh how
      // long something has been on a shelf.
    ]);
  }

  Widget _dot(String label, String value, Color colour, {bool bold = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: TextStyle(fontSize: 11, color: colour)),
              Text(value,
                  style: TextStyle(
                      fontSize: 11,
                      color: colour,
                      fontWeight: bold ? FontWeight.bold : FontWeight.w600)),
            ]),
      );

  Widget _decisionSection() {
    // Cancelled in SAP is the last word on an order; nothing here moves it.
    if (!_isLead && cancelledInSap(SapOrderState.fromOrder(_order))) {
      return _note(const Color(0xFFFFEBEE), Icons.block, Colors.red,
          'Cancelled in SAP.');
    }
    // A rejection is undone rather than re-decided, as on the dashboard: the
    // order goes back to waiting, and the rep may change it first.
    if (_rejected) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _note(const Color(0xFFFFEBEE), Icons.cancel, Colors.red,
            'Rejected and returned to the rep.'),
        if (!_isLead && !Session.I.isGM) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _undoReject,
            icon: const Icon(Icons.undo),
            label: const Padding(
                padding: EdgeInsets.all(8), child: Text('Undo rejection')),
          ),
        ],
      ]);
    }
    if (_approved) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: const Color(0xFFE8F5E9),
            borderRadius: BorderRadius.circular(8)),
        child: Row(children: const [
          Icon(Icons.check_circle, color: Colors.green),
          SizedBox(width: 8),
          Expanded(
              child: Text('Approved. Rates are final.',
                  style: TextStyle(color: Colors.green))),
        ]),
      );
    }
    // A lead never escalates and has its own statuses, so it keeps the plain
    // pair. Everything below is for customer orders.
    final acts = _isLead
        ? const OrderActions(approve: true, reject: true)
        : _acts;
    final isGm = Session.I.isGM && !_isLead;
    // The single forward move, whoever holds it: the sales manager's approve
    // (a push to SAP), their escalation, or the GM's approval of the credit.
    final forward = acts.approve || acts.escalate || acts.gmApprove;
    final by = _s(_order['custom_gm_approved_by']);
    final on = _s(_order['custom_gm_approved_on']);
    final approvedLine = [
      if (by.isNotEmpty) by else 'The general manager',
      'approved the credit',
      if (on.length >= 10) 'on ${on.substring(0, 10)}',
    ].join(' ');

    if (!forward && !acts.reject) {
      // With the GM, the sales manager no longer decides it. Offering "Send to
      // GM" here used to re-escalate an order already escalated.
      final withGm = '${_order['custom_po_status']}' == 'Pending GM Approval';
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: const Color(0xFFE3F2FD),
            borderRadius: BorderRadius.circular(8)),
        child: Text(
            withGm
                ? 'With the General Manager for credit approval.'
                : 'Nothing on this order is yours to decide.',
            style: const TextStyle(fontSize: 12.5)),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (acts.escalate)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(6)),
          child: const Text('Needs GM approval for credit.',
              style: TextStyle(fontSize: 12.5, color: Colors.deepOrange)),
        ),
      // Back from the GM, approved: said plainly, because the push is now the
      // sales manager's and the GM's name is what they are acting on.
      if (_gmApproved)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(6)),
          child: Text(
              isGm
                  ? 'You approved the credit. The sales manager pushes it to SAP.'
                  : '$approvedLine.',
              style: const TextStyle(fontSize: 12.5)),
        ),
      const SizedBox(height: 4),
      Row(children: [
        if (forward)
          Expanded(
              child: FilledButton.icon(
                  onPressed: _busy ? null : () => _decide(true),
                  icon: Icon(_gmApproved && !isGm
                      ? Icons.cloud_upload
                      : Icons.check),
                  label: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(acts.gmApprove
                          ? 'Approve'
                          : acts.escalate
                              ? 'Send to GM'
                              : _gmApproved
                                  ? 'Push to SAP'
                                  : 'Approve')))),
        if (forward && acts.reject) const SizedBox(width: 8),
        if (acts.reject)
          Expanded(
              child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: _busy ? null : () => _decide(false),
                  icon: const Icon(Icons.close),
                  label: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(isGm && _gmApproved
                          ? 'Withdraw approval'
                          : 'Reject')))),
      ]),
    ]);
  }

  Widget _note(Color bg, IconData icon, Color fg, String text) => Container(
        padding: const EdgeInsets.all(12),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Icon(icon, color: fg),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: fg))),
        ]),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k, style: const TextStyle(fontSize: 12)),
          Text(v,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      );
}
