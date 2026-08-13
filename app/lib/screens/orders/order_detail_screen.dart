import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/stage_watch.dart';
import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/pdf/proforma_pdf.dart';
import 'package:manna_field_sales/screens/orders/order_screen.dart';
import 'package:manna_field_sales/models/order_ref.dart';
import 'package:manna_field_sales/services/api.dart';

class OrderDetailScreen extends StatefulWidget {
  final String orderName;
  const OrderDetailScreen({super.key, required this.orderName});
  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  late Future<void> _init;
  Map<String, dynamic> _order = {};

  /// What production moved since this phone last opened the order. Computed
  /// once per load, before the snapshot is written back.
  List<StageChange> _stageNews = const [];
  Map<String, dynamic> _customer = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init = _load();
  }

  Future<void> _load() async {
    _order = await Api.getOrder(widget.orderName);

    // Diff against what this phone last showed, then record what it is showing
    // now. Keyed on the child row name, which survives an edit to the order.
    final rows = ((_order['items'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    _stageNews = changesSince(await StageSeen.load(widget.orderName), rows);
    await StageSeen.save(widget.orderName, snapshotOf(rows));
    final cust = _order['customer'];
    if (cust != null) {
      try {
        _customer = await Api.getCustomerDoc(cust as String);
      } catch (_) {}
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  double get _outstanding => (_customer['custom_outstanding_balance'] is num)
      ? (_customer['custom_outstanding_balance'] as num).toDouble()
      : 0.0;
  double get _limit => (_customer['custom_credit_limit'] is num)
      ? (_customer['custom_credit_limit'] as num).toDouble()
      : 0.0;
  bool get _overLimit => _limit > 0 && _outstanding > _limit;

  /// True when the rep looking at this is the one who raised it.
  ///
  /// The proforma is the rep's document — they hand it to the customer. A
  /// manager opening the same order is reviewing it, not printing for anyone,
  /// so the whole section is left off rather than offering them a button that
  /// belongs to somebody else's conversation.
  bool get _isOwner =>
      Session.I.salesPerson != null &&
      '${_order['custom_sales_person'] ?? ''}' == Session.I.salesPerson;

  /// The date the customer originally asked for, set only once production has
  /// actually moved the delivery.
  String get _originalDelivery {
    final s = '${_order['custom_original_delivery_date'] ?? ''}';
    return (s.isEmpty || s == 'null') ? '' : s.substring(0, 10);
  }

  bool get _deliveryMoved {
    if (_originalDelivery.isEmpty) return false;
    final now = '${_order['delivery_date'] ?? ''}';
    return now.isNotEmpty && !now.startsWith(_originalDelivery);
  }

  /// When the order was placed, stamped by the server. This is the clock every
  /// later deadline on the order is measured against, so it is shown on the
  /// order rather than left buried in the document's metadata.
  String get _placedAt {
    final s = '${_order['custom_order_placed_at'] ?? _order['creation'] ?? ''}';
    if (s.isEmpty || s == 'null') return '—';
    // `yyyy-MM-dd HH:mm:ss(.ffffff)` -> `dd/MM/yyyy HH:mm`
    if (s.length < 16) return s;
    return '${s.substring(8, 10)}/${s.substring(5, 7)}/${s.substring(0, 4)} '
        '${s.substring(11, 16)}';
  }

  Future<void> _generateProforma({required bool asPO}) async {
    setState(() => _busy = true);
    final err = await openProformaPdf(
        order: _order, customer: _customer, isPurchaseOrder: asPO);
    if (mounted) setState(() => _busy = false);
    if (err != null && mounted) _snack('Proforma error: $err');
  }

  Future<void> _sendProforma() async {
    final released = _order['custom_proforma_status'] == 'Released';
    if (_overLimit && !released) {
      _snack('Over credit limit — request manager release first.');
      return;
    }
    await _generateProforma(asPO: false);
    try {
      await Api.setOrderField(
          _order['name'] as String, {'custom_proforma_status': 'Sent'});
      _order['custom_proforma_status'] = 'Sent';
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _requestRelease() async {
    setState(() => _busy = true);
    try {
      await Api.setOrderField(_order['name'] as String,
          {'custom_proforma_status': 'Pending Release Approval'});
      _order['custom_proforma_status'] = 'Pending Release Approval';
      _snack('Release requested — your manager will approve.');
      setState(() {});
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reopens the order for changes. Everything — adding a product, dropping
  /// one, changing quantities — happens on the order screen the rep already
  /// knows, rather than a second editor that would drift away from it.
  Future<void> _edit() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => OrderScreen(
                party: OrderParty.customer(_customer.isNotEmpty
                    ? _customer
                    : {'name': _order['customer']}),
                existingOrder: _order,
              )),
    );
    if (changed == true && mounted) setState(() => _init = _load());
  }

  /// What the rep is told about their remaining window. Spelled out rather
  /// than left implicit, because "until 1 pm on the delivery date" is the kind
  /// of rule people only learn by being caught out by it.
  String get _editDeadlineNote {
    final d = orderEditDeadline(_order['delivery_date']);
    if (d == null) {
      return 'This order has no delivery date, so nothing is holding the '
          'changes window open. Set one.';
    }
    final when = '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/${d.year}';
    return canEditOrder(_order)
        ? 'Products and quantities can be changed until 1 pm on $when.'
        : 'The changes window closed at 1 pm on $when.';
  }

  /// What production moved since this phone last had the order open.
  ///
  /// Above the items, because it is the part the rep did not know — and the
  /// rep is the one who has to ring the customer about it. Nothing is shown on
  /// a first look: that establishes the baseline rather than replaying every
  /// stage as news.
  Widget _stageNewsCard() {
    if (_stageNews.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: const Color(0xFFE3EDF9),
          borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.factory_outlined, size: 18, color: Colors.blue.shade800),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                'Production moved ${_stageNews.length} '
                '${_stageNews.length == 1 ? 'item stage' : 'item stages'} '
                'since you last looked',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.blue.shade900)),
          ),
        ]),
        const SizedBox(height: 6),
        ..._stageNews.map((c) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('• ${describeChange(c)}',
                  style: const TextStyle(fontSize: 12.5)),
            )),
      ]),
    );
  }

  /// Every item on the order, with the stage each half is on.
  ///
  /// A split line's made and shelf portions finish separately, so both stages
  /// are shown. One combined stage would be a fiction on any order that is
  /// part stock and part production.
  Widget _itemsCard(List items) {
    final moved = changedLineIds(_stageNews);

    Widget stageLine(String label, String value) => Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(children: [
        Text('$label  ',
            style: const TextStyle(fontSize: 10.5, color: Colors.black54)),
        Text(stageText(value),
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(children: [
        for (final raw in items) ...() {
          final it = (raw as Map).cast<String, dynamic>();
          final id = '${it['name'] ?? ''}';
          final made = '${it[kStageFieldMade] ?? ''}';
          final shelf = '${it[kStageFieldShelf] ?? ''}';
          final didMove = moved.contains(id);
          return [
            Container(
              color: didMove ? const Color(0xFFE3EDF9) : null,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${it['item_name'] ?? it['item_code'] ?? ''}',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                          Text('${it['custom_packing_note'] ?? ''}',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.black54)),
                          if (made.isNotEmpty || shelf.isEmpty)
                            stageLine('Being made', made),
                          if (shelf.isNotEmpty) stageLine('From stock', shelf),
                        ]),
                  ),
                  const SizedBox(width: 8),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('Rs ${((it['amount'] ?? 0) as num).toStringAsFixed(0)}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    if (didMove)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                            color: Colors.blue.shade100,
                            borderRadius: BorderRadius.circular(4)),
                        child: Text('MOVED',
                            style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: Colors.blue.shade900)),
                      ),
                  ]),
                ],
              ),
            ),
            if (raw != items.last) const Divider(height: 1),
          ];
        }(),
      ]),
    );
  }

  Widget _statusRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(label, style: const TextStyle(color: Colors.black54)),
      Flexible(
          child: Text(value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w600))),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Order ${widget.orderName}')),
      body: FutureBuilder<void>(
        future: _init,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text(humanError(snap.error)));
          final pf = '${_order['custom_proforma_status'] ?? 'Ready'}';
          final po = '${_order['custom_po_status'] ?? 'No PO Yet'}';
          final items = (_order['items'] as List?) ?? [];
          final total = items.fold<double>(
              0, (s, it) => s + (((it['amount'] ?? 0) as num).toDouble()));
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text('${_customer['customer_name'] ?? _order['customer'] ?? ''}',
                style:
                const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
                'Order total: Rs ${total.toStringAsFixed(2)}  ·  ${items.length} item(s)'),
            const SizedBox(height: 12),
            if (_overLimit)
              Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                      color: const Color(0xFFFFEBEE),
                      borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [
                    const Icon(Icons.block, color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(
                            'Over credit limit (Out: Rs ${_outstanding.toStringAsFixed(0)} / Limit: Rs ${_limit.toStringAsFixed(0)}). Proforma blocked until manager release.',
                            style: const TextStyle(color: Colors.red))),
                  ])),
            _stageNewsCard(),
            _itemsCard(items),
            _statusRow('Order placed', _placedAt),
            _statusRow('Proforma', pf),
            _statusRow('Approval', approvalLabel(po)),
            if (ratesLocked(_order)) _statusRow('Rates', 'Locked by manager'),
            if ('${_order['delivery_date'] ?? ''}'.isNotEmpty &&
                '${_order['delivery_date']}' != 'null')
              _statusRow('Required delivery', '${_order['delivery_date']}'),
            // Production can move the date, and the rep is the one who has to
            // tell the customer. Showing only the new date would hide that
            // anything happened.
            if (_deliveryMoved)
              Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  Icon(Icons.event_repeat,
                      size: 18, color: Colors.orange.shade900),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        'Production moved this delivery. The customer asked '
                        'for $_originalDelivery.',
                        style: TextStyle(
                            fontSize: 12, color: Colors.orange.shade900)),
                  ),
                ]),
              ),
            if (po == 'PO Approved - Ready for SAP')
              _statusRow(
                  'Production',
                  '${_order['custom_production_status'] ?? 'Not Started'}'
                      '${('${_order['custom_production_finish_date'] ?? ''}'.isNotEmpty && '${_order['custom_production_finish_date']}' != 'null') ? '  ·  est. finish ${_order['custom_production_finish_date']}' : ''}'),
            const Divider(height: 28),
            if (_isOwner) ...[
              const Text('1 · Proforma',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              const Text(
                  'Optional. The order is already with your manager — print '
                  'this only if the customer wants a copy.',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 8),
              if (_overLimit && pf != 'Released')
                FilledButton.icon(
                  onPressed: _busy || pf == 'Pending Release Approval'
                      ? null
                      : _requestRelease,
                  icon: const Icon(Icons.lock_clock),
                  label: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(pf == 'Pending Release Approval'
                          ? 'Release requested — awaiting manager'
                          : 'Request Manager Release')),
                )
              else
                FilledButton.icon(
                  onPressed: _busy ? null : _sendProforma,
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Text('Generate & Send Proforma')),
                ),
              const SizedBox(height: 20),
            ],
            Text(_isOwner ? '2 · Changes' : 'Changes',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
                _editDeadlineNote,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            if (canEditOrder(_order))
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.indigo),
                onPressed: _busy ? null : _edit,
                icon: const Icon(Icons.edit),
                label: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Text('Add / Remove Products')),
              )
            else
              Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: const Color(0xFFF5F5F5),
                      borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [
                    const Icon(Icons.lock_outline,
                        size: 20, color: Colors.black54),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(orderLockReason(_order),
                            style: const TextStyle(
                                fontSize: 12, color: Colors.black54))),
                  ])),
            if (_busy)
              const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: Center(child: CircularProgressIndicator())),
          ]);
        },
      ),
    );
  }
}

// -------------------- MANAGER --------------------
