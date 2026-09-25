import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/core/credit.dart';
import 'package:manna_field_sales/core/credit_commitment.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/week.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/models/order_ref.dart';
import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/screens/orders/min_stock_screen.dart';
import 'package:manna_field_sales/screens/orders/order_detail_screen.dart';
import 'package:manna_field_sales/screens/orders/product_row.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/pending_orders.dart';

class OrderScreen extends StatefulWidget {
  /// Who the order is for. A lead orders on exactly the same terms as a
  /// customer — same families, same minimum stock, same edit window — so this
  /// screen does both rather than there being a second, thinner one that
  /// drifts out of step.
  final OrderParty party;

  /// An order being changed rather than raised. The same screen does both so
  /// there is only one copy of the rolls-and-belts maths and one set of
  /// product rows to keep right.
  final Map<String, dynamic>? existingOrder;

  const OrderScreen({
    super.key,
    required this.party,
    this.existingOrder,
  });
  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  late Future<void> _init;

  /// One line per sellable product, created up front and kept for the life of
  /// the screen. Reps scroll back and forth between families while the
  /// customer changes their mind, and rebuilding lines on every filter change
  /// would throw away what they had already typed.
  final List<OrderLine> _lines = [];

  /// Keyed by item code. Absent means the item is not on the minimum-stock
  /// list at all, which the row renders as "No minimum stock" rather than as
  /// zero available.
  Map<String, MinStock> _stock = {};

  String _company = '';
  String _q = '';
  DateTime? _deliveryDate;
  bool _submitting = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // The delivery date comes straight off the order that was passed in, so it
    // is set here rather than after the product list finishes loading. The
    // footer is built outside the FutureBuilder and would otherwise render
    // "Tap to pick a date" for a second on an order that already has one.
    final existing = widget.existingOrder;
    if (existing != null) {
      final d = existing['delivery_date'];
      if (d != null) _deliveryDate = DateTime.tryParse('$d');
    }
    _init = _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Minimum stock is a Treads process. For the other units the pool is never
  /// read and never shown, so their rows carry no stock line at all rather
  /// than a row of "No minimum stock" that means nothing to them.
  bool get _usesMinimumStock => Session.I.isTreadsUnit;

  bool get _isEdit => widget.existingOrder != null;

  /// What a lead is still missing before the manager can approve an order
  /// against it. Empty for a customer, and for a complete lead.
  List<String> get _leadMissing =>
      widget.party.isLead ? missingLeadDetails(widget.party.doc) : const [];

  /// Whether the order as a whole has been approved. Before that a rep changes
  /// whatever they like — the manager has not looked at it yet, so there is
  /// nothing to protect. Afterwards, every change goes back to them.
  bool get _wasApproved => _isEdit && ratesLocked(widget.existingOrder!);

  /// Item codes whose price the manager has actually signed off, taken from
  /// each line's own flag rather than from "it was on the order when I opened
  /// it" — otherwise a line the rep added last night would come back locked
  /// this morning without anyone having approved it.
  final Set<String> _approvedLines = <String>{};

  /// Copies an existing order's quantities onto the freshly built line list.
  /// Matching is by item code, so a product that has since been disabled
  /// simply drops off rather than breaking the screen.
  void _applyExistingOrder() {
    final byCode = {for (final l in _lines) l.product.code: l};
    for (final raw in (widget.existingOrder!['items'] as List? ?? [])) {
      final it = (raw as Map).cast<String, dynamic>();
      final line = byCode['${it['item_code']}'];
      if (line == null) continue;
      int asInt(dynamic v) =>
          v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);
      line.rolls = asInt(it['custom_rolls']);
      line.looseBelts = asInt(it['custom_loose_belts']);
      line.boxes = asInt(it['custom_boxes']);
      line.cans = asInt(it['custom_cans']);
      final perKg = it['custom_rate_per_kg'];
      line.rate = perKg is num
          ? perKg.toDouble()
          : (double.tryParse('${perKg ?? ''}') ?? 0);
      final batch = it['custom_aged_batch'];
      if (batch is String && batch.isNotEmpty) line.agedBatch = batch;
      // Whether the manager has already signed off *this* line's price. A line
      // added since is not approved just because it is now on the order.
      if ((it['custom_rate_approved'] ?? 0) == 1) {
        _approvedLines.add(line.product.code);
      }
      _openedWith.add(line.product.code);
    }
  }

  Future<void> _load() async {
    final results = await Future.wait([
      Api.getItems(),
      Api.getCompany(),
      if (_usesMinimumStock) Api.getMinimumStock(),
    ]);
    _lines
      ..clear()
      ..addAll((results[0] as List<Map<String, dynamic>>)
          .map((doc) => OrderLine(product: Product(doc))));
    _company = results[1] as String;
    if (_usesMinimumStock) {
      _stock = results[2] as Map<String, MinStock>;
      _startPolling();
    }
    if (_isEdit) _applyExistingOrder();
  }

  /// Minimum stock is shared with every other rep in the field, so what this
  /// screen showed when it opened goes stale the moment someone else commits.
  /// Re-reading on a timer is what keeps a row from offering rolls that are
  /// already gone. The server still has the final say at submit time.
  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(kStockRefreshInterval, (_) async {
      if (!mounted || _submitting) return;
      try {
        final fresh = await Api.getMinimumStock();
        if (mounted) setState(() => _stock = fresh);
      } catch (_) {
        // A rep in a basement should not get an error banner every ten
        // seconds. The next tick tries again.
      }
    });
  }

  // ------------------------------------------------------------ filter ---

  /// Narrows the catalogue to one product family. Null means all of them.
  ///
  /// A rep walking into a shop is usually selling one family — a tread rubber
  /// call is not a bonding gum call — and scrolling past two hundred products
  /// of the wrong kind to reach them is the slowest part of taking an order.
  ProductCategory? _categoryFilter;

  /// Whether to show only items on the minimum-stock list, only items off it,
  /// or everything. Null means everything.
  ///
  /// Minimum stock is what a rep can promise today; everything else is made to
  /// order. Being able to see just the first is how a rep answers "what can you
  /// give me this week" without reading every row.
  bool? _stockFilter;

  /// The families offered in the picker.
  ///
  /// Fixed, not derived from the loaded catalogue. Deriving it meant the
  /// dropdown appeared blank and then popped into existence a second later when
  /// the products arrived, which read as the screen still loading. A family
  /// with nothing in it simply filters to an empty list, and the empty state
  /// says so.
  static const List<ProductCategory> _categories = [
    ProductCategory.pctr,
    ProductCategory.ctr,
    ProductCategory.bondingGum,
    ProductCategory.vulcanizingSolution,
  ];

  List<OrderLine> get _filtered {
    final qq = _q.trim().toLowerCase();
    return _lines.where((l) {
      if (_categoryFilter != null && l.product.category != _categoryFilter) {
        return false;
      }
      if (_stockFilter != null) {
        final onList = _stock.containsKey(l.product.code);
        if (onList != _stockFilter) return false;
      }
      if (qq.isEmpty) return true;
      return '${l.product.name} ${l.product.code}'.toLowerCase().contains(qq);
    }).toList();
  }

  /// Item codes that were on the order when this edit began.
  ///
  /// Fixed at open rather than recomputed as the user types: a manager who
  /// zeroes a line should see it stay where it is so they can put it back,
  /// not watch it jump down into the catalogue mid-edit.
  final Set<String> _openedWith = <String>{};

  /// The lines already on the order, so a manager opening an edit sees what
  /// they came to change before several hundred products they did not.
  List<OrderLine> get _onOrder => _filtered
      .where((l) => _openedWith.contains(l.product.code))
      .toList();

  /// Grouped for display, in the order the families are normally sold. Lines
  /// already on the order are pulled out into their own section above.
  Map<ProductCategory, List<OrderLine>> get _grouped {
    const order = [
      ProductCategory.pctr,
      ProductCategory.ctr,
      ProductCategory.bondingGum,
      ProductCategory.vulcanizingSolution,
      ProductCategory.other,
    ];
    final out = <ProductCategory, List<OrderLine>>{};
    for (final c in order) {
      final rows = _filtered
          .where((l) =>
              l.product.category == c && !_openedWith.contains(l.product.code))
          .toList();
      if (rows.isNotEmpty) out[c] = rows;
    }
    return out;
  }

  List<OrderLine> get _picked => _lines.where((l) => !l.isEmpty).toList();

  double get _total => _picked.fold<double>(0, (t, l) => t + l.amount);

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  // ------------------------------------------------------------ submit ---

  /// Everything that has to be true before an order can leave the phone.
  /// Returned as a message rather than a bool so the rep is told which one
  /// they tripped.
  String? _validate() {
    if (_picked.isEmpty) return 'Add at least one product.';
    if (_deliveryDate == null) return 'Pick a required delivery date.';
    final unpriced = _picked.where((l) => l.needsRate).toList();
    if (unpriced.isNotEmpty) {
      return 'Enter a rate for ${unpriced.first.product.name}.';
    }
    final broken = _picked.where((l) => l.product.isMisconfigured).toList();
    if (broken.isNotEmpty) {
      return '${broken.first.product.name} is missing its packing details.';
    }
    // Wanting more than the shelf holds is not an error, and refusing it here
    // would be wrong. Fifteen rolls against eight available is an order for
    // fifteen: eight come off the shelf and seven are made. The order is
    // placed in full and SAP decides what it can ship.
    return null;
  }

  /// Whether this order needs the customer's commitment before it may go.
  ///
  /// Exactly when it will escalate to the GM — the same test the manager's
  /// review uses (credit_commitment.json). An edit to an order that already
  /// carries one keeps it. A manager editing from their review is not the
  /// person who heard the customer's promise, so they are not asked to invent
  /// one; the GM sees "no commitment" and asks the rep.
  bool get _needsCommitment {
    if (widget.party.isLead) return false;
    if (!commitmentRequired(widget.party.doc, _total)) return false;
    if (_isEdit) {
      if (hasCommitment(widget.existingOrder!['custom_credit_commitment'])) {
        return false;
      }
      if (Session.I.isManager || Session.I.isGM) return false;
    }
    return true;
  }

  /// Asks the rep what the customer has committed to.
  ///
  /// Asked at the moment of sending, with the credit figures in front of
  /// them, because that is when the customer is still at the counter and the
  /// promise is still fresh. The date is optional: plenty of promises are
  /// "with the next order", and the GM sets one on approval anyway.
  Future<({String text, String? due})?> _askCommitment() async {
    final ctrl = TextEditingController();
    DateTime? due;
    String? problem;
    final a = agingOf(widget.party.doc);
    String rs(double v) => 'Rs ${v.toStringAsFixed(0)}';

    return showDialog<({String text, String? due})?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Over the credit limit'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Owes ${rs(a.total)} · this order ${rs(_total)} · '
                  'limit ${rs(a.creditLimit)}.',
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Your manager cannot approve this order on their own. They '
                  'send it to the general manager, who decides it on what you '
                  'write here — and once approved, it becomes your condition.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'What has the customer committed to?',
                    hintText:
                        'Cheque for 50,000 on Friday, balance with the next order',
                    border: const OutlineInputBorder(),
                    errorText: problem,
                    errorMaxLines: 3,
                  ),
                  onChanged: (_) {
                    if (problem != null) setLocal(() => problem = null);
                  },
                ),
                const SizedBox(height: 8),
                Row(children: [
                  const Text('By when', style: TextStyle(fontSize: 13)),
                  const Spacer(),
                  TextButton(
                    onPressed: () async {
                      final now = DateTime.now();
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: due ?? now.add(const Duration(days: 7)),
                        firstDate: now,
                        lastDate: now.add(const Duration(days: 365)),
                      );
                      if (picked != null) setLocal(() => due = picked);
                    },
                    child: Text(due == null ? 'Optional' : isoDate(due!)),
                  ),
                  if (due != null)
                    IconButton(
                      tooltip: 'No date',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setLocal(() => due = null),
                    ),
                ]),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Back to the order')),
            FilledButton(
              onPressed: () {
                final p = commitmentProblem(ctrl.text);
                if (p != null) {
                  setLocal(() => problem = p);
                  return;
                }
                Navigator.pop(ctx, (
                  text: ctrl.text.trim(),
                  due: due == null ? null : isoDate(due!),
                ));
              },
              child: const Text('Send for approval'),
            ),
          ],
        ),
      ),
    );
  }

  /// Offers to hold an order that could not be sent for want of signal.
  ///
  /// The wording is careful on purpose. No order number exists and no stock is
  /// held — stock is committed in SAP, which this order has not reached — so
  /// the rep must not walk away believing the customer is covered. Another rep
  /// in signal can take the same rolls before this draft is ever sent.
  Future<void> _offerDraft(String deliveryDate,
      {({String text, String? due})? commitment}) async {
    if (!mounted) return;
    setState(() => _submitting = false);

    final keep = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('No signal'),
        content: const Text(
          'This order has not been sent, so no stock on it is held for you. '
          'Another rep with signal can still take it.\n\n'
          'Keep the order on the phone and send it when you have signal?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Discard')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Keep it')),
        ],
      ),
    );

    if (keep != true) return;

    await PendingOrders.save(
      customer: widget.party.name,
      customerName: widget.party.label,
      deliveryDate: deliveryDate,
      items: [for (final l in _picked) l.toSalesOrderItem()],
      isLead: widget.party.isLead,
      commitment: commitment?.text,
      commitmentDue: commitment?.due,
    );
    if (!mounted) return;
    _snack('Saved on your phone — not sent yet. Send it from Unsent Orders.');
    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _submit() async {
    final problem = _validate();
    if (problem != null) return _snack(problem);

    // Before anything is sent, so backing out of the dialog leaves the order
    // on screen exactly as the rep built it.
    ({String text, String? due})? commitment;
    if (_needsCommitment) {
      commitment = await _askCommitment();
      if (commitment == null || !mounted) return;
    }

    setState(() => _submitting = true);

    final d = _deliveryDate!;
    final dd = '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';

    try {
      final String name;
      if (_isEdit) {
        name = '${widget.existingOrder!['name']}';
        await Api.updateOrderLines(
          orderName: name,
          items: [
            for (final l in _picked)
              l.toSalesOrderItem()
                ..['custom_rate_approved'] =
                    _approvedLines.contains(l.product.code) ? 1 : 0
          ],
          deliveryDate: dd,
          // Nothing has been signed off yet on an unapproved order, so the rep
          // simply saves. Once it has been approved, any change at all — a
          // quantity, a new product, even the delivery date — goes back to the
          // manager, because what they approved is no longer what will ship.
          returnForApproval: _wasApproved,
          isLead: widget.party.isLead,
          commitment: commitment?.text,
          commitmentDue: commitment?.due,
        );
        _snack(_wasApproved
            ? 'Order updated ✓ — sent back to your manager'
            : 'Order updated ✓  $name');
        // Back where the edit started, rather than onward into the rep's order
        // screen. A manager who edits from the review is not being sent to a
        // page offering to print a proforma.
        await Future.delayed(const Duration(milliseconds: 400));
        if (mounted) Navigator.pop(context, true);
        return;
      } else if (widget.party.isLead) {
        name = await Api.placeLeadOrder(
          lead: widget.party.name,
          items: [for (final l in _picked) l.toSalesOrderItem()],
          deliveryDate: dd,
          total: _total,
        );
        _snack('Order sent for approval ✓  $name');
        // A lead order has no proforma screen to go on to — it becomes a real
        // Sales Order only once the manager approves and the lead converts.
        await Future.delayed(const Duration(milliseconds: 400));
        if (mounted) Navigator.pop(context, true);
        return;
      } else {
        name = await Api.placeOrder(
          customer: widget.party.name,
          company: _company,
          items: [for (final l in _picked) l.toSalesOrderItem()],
          deliveryDate: dd,
          commitment: commitment?.text,
          commitmentDue: commitment?.due,
        );
        _snack(commitment != null
            ? 'Order sent with your commitment ✓  $name'
            : 'Order sent for approval ✓  $name');
      }

      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) {
        Navigator.pushReplacement(
            context,
            MaterialPageRoute(
                builder: (_) => OrderDetailScreen(orderName: name)));
      }
    } catch (e) {
      // No signal is the one failure worth offering a way out of: the rep is
      // standing in front of the customer and the order is already typed.
      // Every other failure means the server considered this order and said no,
      // so a draft would only defer the same answer.
      if (isOffline(e) && !_isEdit) {
        await _offerDraft(dd, commitment: commitment);
        return;
      }
      // The most likely failure is someone else getting there first, so the
      // screen refreshes before the rep looks at it again.
      _snack(humanError(e));
      try {
        final fresh = await Api.getMinimumStock();
        if (mounted) setState(() => _stock = fresh);
      } catch (_) {}
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// The family filter. Built from a fixed list so it is on screen from the
  /// first frame rather than arriving with the catalogue.
  Widget _categoryPicker() => DropdownButtonHideUnderline(
        child: DropdownButton<ProductCategory?>(
          value: _categoryFilter,
          isDense: true,
          borderRadius: BorderRadius.circular(12),
          // The collapsed label stays short so the search field keeps its
          // width; the full family name is on each menu entry.
          selectedItemBuilder: (_) => [
            _pickerLabel('All'),
            for (final c in _categories) _pickerLabel(c.shortLabel),
          ],
          items: [
            const DropdownMenuItem<ProductCategory?>(
                value: null, child: Text('All products')),
            for (final c in _categories)
              DropdownMenuItem<ProductCategory?>(
                  value: c, child: Text(c.label)),
          ],
          onChanged: (v) => setState(() => _categoryFilter = v),
        ),
      );

  /// The minimum-stock filter. Only offered to units that keep a pool at all —
  /// for the others every product would be "no minimum stock" and the control
  /// would sort nothing.
  Widget _stockPicker() {
    if (!_usesMinimumStock) return const SizedBox.shrink();
    return DropdownButtonHideUnderline(
      child: DropdownButton<bool?>(
        value: _stockFilter,
        isDense: true,
        borderRadius: BorderRadius.circular(12),
        selectedItemBuilder: (_) => [
          _pickerLabel('Any stock'),
          _pickerLabel('Min stock'),
          _pickerLabel('Made to order'),
        ],
        items: const [
          DropdownMenuItem<bool?>(value: null, child: Text('Any stock')),
          DropdownMenuItem<bool?>(
              value: true, child: Text('On minimum stock')),
          DropdownMenuItem<bool?>(
              value: false, child: Text('Made to order only')),
        ],
        onChanged: (v) => setState(() => _stockFilter = v),
      ),
    );
  }

  Widget _pickerLabel(String text) => Align(
        alignment: Alignment.centerLeft,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.filter_list, size: 16),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 13)),
        ]),
      );

  // ------------------------------------------------------------- build ---

  @override
  Widget build(BuildContext context) {
    final name = widget.party.label;
    return Scaffold(
      appBar: AppBar(
        // The rep is told which kind of party this is up front. A lead order
        // follows the same path but has to be complete enough to invoice
        // before the manager can approve it, and finding that out at the
        // counter is better than finding out at approval.
        title: Text(_isEdit
            ? 'Edit ${widget.existingOrder!['name']}'
            : widget.party.isLead
                ? 'Lead order — $name'
                : 'Order — $name'),
        actions: [
          if (_usesMinimumStock)
            IconButton(
              tooltip: 'Slow movers',
              icon: const Icon(Icons.trending_down),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const MinimumStockScreen())),
            ),
        ],
      ),
      body: Column(children: [
        // Said before the rep starts typing, not after they have built the
        // order. It does not block: the order is still worth taking, and the
        // rep may well be standing in front of the person who can supply the
        // GST number.
        if (_leadMissing.isNotEmpty)
          Container(
            width: double.infinity,
            color: const Color(0xFFFFF1F0),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.report_problem_outlined,
                  size: 16, color: Color(0xFFB3261E)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'This lead is missing its ${_leadMissing.join(', ').toLowerCase()}. '
                  'You can take the order, but your manager cannot approve it '
                  'until that is filled in.',
                  style: const TextStyle(fontSize: 12.5, height: 1.35),
                ),
              ),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Column(children: [
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search products…',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
            const SizedBox(height: 4),
            Row(children: [
              _categoryPicker(),
              const SizedBox(width: 12),
              _stockPicker(),
            ]),
          ]),
        ),
        Expanded(
          child: FutureBuilder<void>(
            future: _init,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(child: Text(humanError(snap.error)));
              }
              if (_lines.isEmpty) {
                return const Center(child: Text('No sellable items found.'));
              }
              final groups = _grouped;
              if (groups.isEmpty) {
                return const Center(child: Text('No matching products.'));
              }
              final onOrder = _onOrder;
              return ListView(
                children: [
                  if (onOrder.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      color: const Color(0xFFFFF3E0),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Text('ALREADY ON THIS ORDER  (${onOrder.length})',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.4,
                              color: Colors.orange.shade900)),
                    ),
                    for (final line in onOrder)
                      ProductRow(
                        key: ValueKey(line.product.code),
                        line: line,
                        stock: _stock[line.product.code],
                        showMinimumStock: _usesMinimumStock,
                        rateLocked: _approvedLines.contains(line.product.code),
                        onChanged: () => setState(() {}),
                      ),
                  ],
                  for (final entry in groups.entries) ...[
                    _sectionHeader(entry.key, entry.value.length),
                    for (final line in entry.value)
                      ProductRow(
                        // Keyed by item so a filter change re-uses the same
                        // row state instead of resetting the typed rate.
                        key: ValueKey(line.product.code),
                        line: line,
                        stock: _stock[line.product.code],
                        showMinimumStock: _usesMinimumStock,
                        // Only the lines the manager actually signed off are
                        // frozen. A product added since still needs pricing.
                        rateLocked: _approvedLines.contains(line.product.code),
                        onChanged: () => setState(() {}),
                      ),
                  ],
                  const SizedBox(height: 12),
                ],
              );
            },
          ),
        ),
      ]),
      bottomNavigationBar: _footer(),
    );
  }

  Widget _sectionHeader(ProductCategory c, int count) => Container(
        width: double.infinity,
        color: const Color(0xFFF5F5F5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text('${c.label}  ($count)',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.4,
                color: Colors.black54)),
      );

  Widget _footer() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          InkWell(
            onTap: _submitting
                ? null
                : () async {
                    final now = DateTime.now();
                    final d = await showDatePicker(
                      context: context,
                      initialDate:
                          _deliveryDate ?? now.add(const Duration(days: 7)),
                      firstDate: now,
                      lastDate: now.add(const Duration(days: 365)),
                    );
                    if (d != null) setState(() => _deliveryDate = d);
                  },
            child: InputDecorator(
              decoration: const InputDecoration(
                  labelText: 'Required delivery date',
                  border: OutlineInputBorder(),
                  isDense: true),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_deliveryDate == null
                        ? 'Tap to pick a date'
                        : '${_deliveryDate!.day}/${_deliveryDate!.month}/${_deliveryDate!.year}'),
                    const Icon(Icons.event, size: 18),
                  ]),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: Text('Total: Rs ${_total.toStringAsFixed(2)}',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold))),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: _submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(_isEdit ? 'Save Changes' : 'Send for Approval'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

// -------------------- COLLECTION --------------------
