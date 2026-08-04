import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/screens/orders/aging_stock_screen.dart';
import 'package:manna_field_sales/screens/orders/order_detail_screen.dart';
import 'package:manna_field_sales/screens/orders/product_row.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/pending_orders.dart';

class OrderScreen extends StatefulWidget {
  final Map<String, dynamic> customer;

  /// An order being changed rather than raised. The same screen does both so
  /// there is only one copy of the rolls-and-belts maths and one set of
  /// product rows to keep right.
  final Map<String, dynamic>? existingOrder;

  const OrderScreen({
    super.key,
    required this.customer,
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

  List<OrderLine> get _filtered {
    final qq = _q.trim().toLowerCase();
    if (qq.isEmpty) return _lines;
    return _lines
        .where((l) =>
            '${l.product.name} ${l.product.code}'.toLowerCase().contains(qq))
        .toList();
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
    for (final l in _picked) {
      final s = _stock[l.product.code];
      if (s == null) continue;
      if (l.reserveQty > s.availableQty + s.myReservedQty + 0.0001) {
        return 'Only ${trimQty(s.availableQty)} ${l.product.category.stockUnit} '
            'of ${l.product.name} left in minimum stock.';
      }
      if (l.reserveBelts > s.availableLooseBelts + s.myReservedLooseBelts) {
        return 'Only ${s.availableLooseBelts} loose belts of '
            '${l.product.name} left in minimum stock.';
      }
    }
    return null;
  }

  /// Offers to hold an order that could not be sent for want of signal.
  ///
  /// The wording is careful on purpose. Nothing has been reserved and no order
  /// number exists, so the rep must not walk away believing the customer is
  /// covered — particularly on minimum-stock lines, where another rep in signal
  /// can take the same rolls before this draft is ever sent.
  Future<void> _offerDraft(
      String deliveryDate, List<Map<String, dynamic>> reservations) async {
    if (!mounted) return;
    setState(() => _submitting = false);

    final keep = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('No signal'),
        content: Text(
          reservations.isEmpty
              ? 'This order has not been sent. Keep it on the phone and send it '
                  'when you have signal?'
              : 'This order has not been sent, and the minimum stock on it is '
                  'not held for you. Another rep with signal can still take it.\n\n'
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
      customer: widget.customer['name'] as String,
      customerName: '${widget.customer['customer_name'] ?? ''}',
      deliveryDate: deliveryDate,
      items: [for (final l in _picked) l.toSalesOrderItem()],
      reservations: reservations,
    );
    if (!mounted) return;
    _snack('Saved on your phone — not sent yet. Send it from Unsent Orders.');
    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _submit() async {
    final problem = _validate();
    if (problem != null) return _snack(problem);

    setState(() => _submitting = true);

    final d = _deliveryDate!;
    final dd = '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';

    // Only lines that draw on the shared pool need booking. Everything else
    // is made to order and has nothing to race over.
    // Booked in the pool's own units — whole rolls and whole belts, not the
    // fractional roll the order line carries.
    // Built outside the try so the offline path can still hand them to a draft.
    final reservations = <Map<String, dynamic>>[
      for (final l in _picked)
        if (_stock.containsKey(l.product.code))
          {
            'item_code': l.product.code,
            'qty': double.parse(l.reserveQty.toStringAsFixed(3)),
            'loose_belts': l.reserveBelts,
            if (l.agedBatch != null) 'batch': l.agedBatch,
          }
    ];

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
          reservations: reservations,
          // Nothing has been signed off yet on an unapproved order, so the rep
          // simply saves. Once it has been approved, any change at all — a
          // quantity, a new product, even the delivery date — goes back to the
          // manager, because what they approved is no longer what will ship.
          returnForApproval: _wasApproved,
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
      } else {
        name = await Api.placeOrder(
          customer: widget.customer['name'] as String,
          company: _company,
          items: [for (final l in _picked) l.toSalesOrderItem()],
          deliveryDate: dd,
          reservations: reservations,
        );
        _snack('Order sent for approval ✓  $name');
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
        await _offerDraft(dd, reservations);
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

  // ------------------------------------------------------------- build ---

  @override
  Widget build(BuildContext context) {
    final name =
        widget.customer['customer_name'] ?? widget.customer['name'] ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit
            ? 'Edit ${widget.existingOrder!['name']}'
            : 'Order — $name'),
        actions: [
          if (_usesMinimumStock)
            IconButton(
              tooltip: 'Slow movers',
              icon: const Icon(Icons.trending_down),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const AgingStockScreen())),
            ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search products…',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
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
