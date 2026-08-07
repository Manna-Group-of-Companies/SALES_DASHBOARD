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

import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/screens/orders/aging_stock_screen.dart';
import 'package:manna_field_sales/screens/orders/order_screen.dart';
import 'package:manna_field_sales/models/order_ref.dart';
import 'package:manna_field_sales/services/api.dart';

class ManagerOrderReviewScreen extends StatefulWidget {
  final String orderName;

  /// True when approving would push the order past the rep's outstanding
  /// limit, in which case the manager's yes escalates to the GM rather than
  /// finalising anything.
  final bool escalates;

  /// True for an order taken against a lead. The review is the same — same
  /// lines, same minimum stock, same per-line fulfilment decision — but
  /// approving one also converts the lead and raises the Sales Order, and it
  /// is refused until the lead is complete enough to invoice.
  final bool isLead;

  const ManagerOrderReviewScreen({
    super.key,
    required this.orderName,
    this.escalates = false,
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

  double get _outstanding => _num(_customer['custom_outstanding_balance']);
  double get _limit => _num(_customer['custom_credit_limit']);
  /// What a line is worth.
  ///
  /// Falls back to qty x rate when `amount` is missing or zero. Lead orders
  /// written before the app started sending `amount` have it as zero — nothing
  /// on a custom child table derives it — and a manager must never be shown a
  /// nil order against rates the rep entered correctly.
  static double _lineAmount(Map<String, dynamic> it) {
    final stored = _num(it['amount']);
    if (stored > 0) return stored;
    return _num(it['qty']) * _num(it['rate']);
  }

  double get _orderTotal =>
      _items.fold<double>(0, (s, it) => s + _lineAmount(it));

  /// What the customer would owe if this order shipped. The limit question is
  /// not "do they owe too much now" but "will they after this".
  double get _projected => _outstanding + _orderTotal;
  bool get _overLimit => _limit > 0 && _projected > _limit;

  /// A decision is outstanding unless the order is actually approved. Read off
  /// the status rather than the rate flag: a rep who edits an approved order
  /// sends it back here, and it has to look like work to do again.
  bool get _approved => orderApproved(_order);

  static double _num(dynamic v) =>
      v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
  static int _int(dynamic v) =>
      v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);

  // -------------------------------------------------- booking attribution ---

  /// What *this* order is holding of an item. Without splitting this out the
  /// manager reads "1 booked" and has no way to tell whether it is somebody
  /// else competing for the stock or the very order in front of them.
  double _heldHere(MinStock s) => s.bookings
      .where((b) => b.salesOrder == widget.orderName)
      .fold<double>(0, (t, b) => t + b.qty);

  int _beltsHeldHere(MinStock s) => s.bookings
      .where((b) => b.salesOrder == widget.orderName)
      .fold<int>(0, (t, b) => t + b.looseBelts);

  double _heldElsewhere(MinStock s) {
    final other = s.reservedQty - _heldHere(s);
    return other < 0 ? 0 : other;
  }

  /// The mode a line is on. Nothing recorded means the rep's own booking is the
  /// status quo — a line the rep booked is being served from minimum stock
  /// until the manager says otherwise, and a line with no booking is not.
  String _modeOf(Map<String, dynamic> it) {
    final stored = '${it['custom_fulfilment_mode'] ?? ''}';
    if (stored.isNotEmpty && stored != 'null') return stored;
    final s = _stock['${it['item_code']}'];
    if (s == null) return kFulfilNewProduction;
    return (_heldHere(s) > 0 || _beltsHeldHere(s) > 0)
        ? kFulfilMinimumStock
        : kFulfilNewProduction;
  }

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

  Future<void> _setLineMode(Map<String, dynamic> it, String mode) async {
    if (_modeOf(it) == mode) return;
    setState(() => _busy = true);
    try {
      await Api.setLineFulfilmentMode(
        orderName: widget.orderName,
        itemCode: '${it['item_code']}',
        mode: mode,
        isLead: _isLead,
      );
      _snack(mode == kFulfilMinimumStock
          ? 'Booked against minimum stock.'
          : 'Released — this line waits for production.');
      setState(() => _init = _load());
    } catch (e) {
      _snack(humanError(e));
    } finally {
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

    if (approve) {
      final ok = await _confirm(
        _isLead ? 'Approve and convert this lead?' : 'Approve this order?',
        [
          if (_isLead)
            'This turns the lead into a customer and raises the real order for '
                'production. The stock it is already holding moves across with '
                'it.',
          if (_overLimit)
            'This takes the customer past their credit limit.',
          'Approving fixes every rate on this order permanently. Nobody, '
              'including you, can change them afterwards.',
        ].join('\n\n'),
      );
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
      if (approve && widget.escalates) {
        await Api.escalateSalesOrderPOToGM(widget.orderName);
        _snack('Sent to the GM — the rep is over their outstanding limit.');
      } else {
        await Api.approveSalesOrderPO(widget.orderName, approve);
        _snack(approve
            ? 'Approved — rates are now final.'
            : 'Rejected ${widget.orderName}');
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _snack(humanError(e));
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirm(String title, String body) => showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continue')),
          ],
        ),
      );

  // -------------------------------------------------------------- build ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Review ${widget.orderName}')),
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
            Text(
                'Raised by ${_order['custom_sales_person'] ?? _order['sales_person'] ?? '—'}'
                '  ·  delivery ${_order['delivery_date'] ?? '—'}',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            Text(
                _isLead
                    ? '${_order['status'] ?? ''}'
                    : approvalLabel(_order['custom_po_status']),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _approved ? Colors.green : Colors.orange.shade800)),
            if (_missing.isNotEmpty) ...[
              const SizedBox(height: 12),
              _missingCard(),
            ],
            const SizedBox(height: 12),
            _creditCard(),
            const SizedBox(height: 16),
            const Text('Lines', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            const Text(
                'Choose per line whether it comes out of minimum stock or waits '
                'for a production run. Changes take effect immediately.',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 4),
            for (final it in _items) _lineCard(it),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Order total',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              Text('Rs ${_orderTotal.toStringAsFixed(2)}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 8),
            if (canEditOrder(_order))
              OutlinedButton.icon(
                onPressed: _busy ? null : _edit,
                icon: const Icon(Icons.edit),
                label: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('Add / Remove / Requantify')),
              )
            else
              Text(orderLockReason(_order),
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
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
            Text(
              'This lead becomes a customer on approval and is invoiced from '
              'there, so it needs: ${_missing.join(', ')}.',
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 6),
            const Text(
              'Ask the rep to add them on the lead, or edit the lead yourself.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
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

    final colour = _overLimit ? Colors.red : Colors.green;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: _overLimit ? const Color(0xFFFFEBEE) : const Color(0xFFE8F5E9),
          borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_overLimit ? Icons.warning_amber_rounded : Icons.check_circle,
              size: 18, color: colour),
          const SizedBox(width: 6),
          Text(_overLimit ? 'Over credit limit' : 'Within credit limit',
              style: TextStyle(fontWeight: FontWeight.bold, color: colour)),
        ]),
        const SizedBox(height: 6),
        _kv('Owes now', 'Rs ${_outstanding.toStringAsFixed(0)}'),
        _kv('This order', 'Rs ${_orderTotal.toStringAsFixed(0)}'),
        _kv('Would owe', 'Rs ${_projected.toStringAsFixed(0)}'),
        _kv('Credit limit',
            _limit > 0 ? 'Rs ${_limit.toStringAsFixed(0)}' : 'none set'),
      ]),
    );
  }

  Widget _lineCard(Map<String, dynamic> it) {
    final code = '${it['item_code']}';
    final s = _stock[code];
    final p = _products[code];
    final unit = p?.category.stockUnit ?? 'units';
    final mode = _modeOf(it);
    final oldest = s?.oldestOpenBatch;
    final hasOld = oldest != null && oldest.ageDays >= kSlowMovingDays;

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
            Text('Rs ${_lineAmount(it).toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 2),
          Text(
              '${it['custom_packing_note'] ?? ''}'
              '${_num(it['custom_rate_per_kg']) > 0 ? '  ·  Rs ${trimQty(_num(it['custom_rate_per_kg']))}/kg' : ''}',
              style: const TextStyle(fontSize: 11, color: Colors.black54)),
          if (_int(it['custom_rate_approved']) == 1)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Row(children: [
                Icon(Icons.lock_outline, size: 13, color: Colors.black45),
                SizedBox(width: 4),
                Text('Rate final — cannot be changed by anyone',
                    style: TextStyle(fontSize: 11, color: Colors.black45)),
              ]),
            ),
          if (s == null)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Not on the minimum stock list — made to order',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.black45,
                      fontStyle: FontStyle.italic)),
            )
          else ...[
            const Divider(height: 14),
            _stockBreakdown(s, unit),
            // Not a warning, and nothing to decide. The oldest batch goes out
            // first automatically, and the shelf life is long enough that age
            // is not a quality question. This is here so the product gets
            // pushed harder in the market before it turns into dead stock.
            if (hasOld)
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(6)),
                child: Row(children: [
                  Icon(Icons.campaign_outlined,
                      size: 14, color: Colors.orange.shade900),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                        'Worth pushing — ${trimQty(oldest.qty)} $unit have been '
                        'in stock ${oldest.ageDays} days (since '
                        '${oldest.batchDate}).',
                        style: TextStyle(
                            fontSize: 11, color: Colors.orange.shade900)),
                  ),
                ]),
              ),
            const SizedBox(height: 8),
            _modeToggle(it, mode),
          ],
        ]),
      ),
    );
  }

  /// Who is holding what. The line that matters is the middle one — a manager
  /// looking at "1 booked" needs to know that the one is this very order, or
  /// they will think somebody else is competing for stock they already have.
  Widget _stockBreakdown(MinStock s, String unit) {
    final here = _heldHere(s);
    final hereBelts = _beltsHeldHere(s);
    final elsewhere = _heldElsewhere(s);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _dot('Minimum stock held',
          s.describe(s.minimumQty, s.minimumLooseBelts, unit), Colors.black87),
      if (here > 0 || hereBelts > 0)
        _dot('Booked by THIS order', s.describe(here, hereBelts, unit),
            Colors.blue.shade700,
            bold: true),
      if (elsewhere > 0)
        _dot('Booked by other orders', s.describe(elsewhere, 0, unit),
            Colors.black54),
      _dot('Free for anyone else',
          s.describe(s.availableQty, s.availableLooseBelts, unit),
          s.availableQty <= 0 ? Colors.red : Colors.green),
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(lastSoldLabel(s),
            style: TextStyle(
                fontSize: 11,
                color:
                    s.isDeadStockRisk ? Colors.red.shade700 : Colors.black54)),
      ),
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

  Widget _modeToggle(Map<String, dynamic> it, String mode) {
    // Where an order is served from is a change to the order like any other,
    // and it stops being one at 1 pm on the delivery date. After that the
    // goods are being picked or made against whatever was decided, and moving
    // a line between stock and production would be describing a decision the
    // floor has already acted on.
    if (!orderEditWindowOpen(_order['delivery_date'])) {
      final stock = mode == kFulfilMinimumStock;
      return Row(children: [
        Icon(Icons.lock_outline,
            size: 14, color: Colors.grey.shade600),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Served from ${stock ? 'minimum stock' : 'new production'} '
            '— fixed at 1 pm on the delivery date.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
          ),
        ),
      ]);
    }
    return Row(children: [
      Expanded(
        child: _modeChip(
          label: 'Minimum stock',
          selected: mode == kFulfilMinimumStock,
          colour: Colors.blue.shade700,
          onTap: () => _setLineMode(it, kFulfilMinimumStock),
        ),
      ),
      const SizedBox(width: 6),
      Expanded(
        child: _modeChip(
          label: 'New production',
          selected: mode == kFulfilNewProduction,
          colour: Colors.deepPurple,
          onTap: () => _setLineMode(it, kFulfilNewProduction),
        ),
      ),
    ]);
  }

  Widget _modeChip({
    required String label,
    required bool selected,
    required Color colour,
    required VoidCallback onTap,
  }) =>
      InkWell(
        onTap: _busy ? null : onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          decoration: BoxDecoration(
            color: selected ? colour.withValues(alpha: 0.12) : Colors.white,
            border: Border.all(
                color: selected ? colour : const Color(0xFFDDDDDD),
                width: selected ? 1.5 : 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 14, color: selected ? colour : Colors.black38),
            const SizedBox(width: 4),
            Flexible(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      color: selected ? colour : Colors.black54,
                      fontWeight:
                          selected ? FontWeight.bold : FontWeight.normal)),
            ),
          ]),
        ),
      );

  Widget _decisionSection() {
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
              child: Text('Approved. Rates on this order are final.',
                  style: TextStyle(color: Colors.green))),
        ]),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.escalates)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(6)),
          child: const Text(
              'The rep is over their outstanding limit. Approving sends this '
              'to the General Manager rather than finalising it.',
              style: TextStyle(fontSize: 12, color: Colors.deepOrange)),
        ),
      const Text('Approving fixes every rate on this order permanently.',
          style: TextStyle(fontSize: 12, color: Colors.black54)),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
            child: FilledButton.icon(
                onPressed: _busy ? null : () => _decide(true),
                icon: const Icon(Icons.check),
                label: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(widget.escalates ? 'Send to GM' : 'Approve')))),
        const SizedBox(width: 8),
        Expanded(
            child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                onPressed: _busy ? null : () => _decide(false),
                icon: const Icon(Icons.close),
                label: const Padding(
                    padding: EdgeInsets.all(8), child: Text('Reject')))),
      ]),
    ]);
  }

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
