// A customer's previous orders, and starting a new one from any of them
// (19 Nov 2026, the user's request).
//
// Tapping an order does not copy it straight away. The rep is first shown
// every line on it — the confirmation the user asked for — because the
// order list shows only a number, a date and a total, and "the one from last
// month" is easy to mistake for "the one from the month before". Only
// "Copy to new order" starts anything, and what it starts is an ordinary new
// order on the order screen, with nothing sent until the rep sends it.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/models/order_ref.dart';
import 'package:manna_field_sales/screens/orders/order_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/route_required_gate.dart';
import 'package:manna_field_sales/core/sap_sent.dart';

class PreviousOrdersScreen extends StatefulWidget {
  final OrderParty party;

  const PreviousOrdersScreen({super.key, required this.party});

  @override
  State<PreviousOrdersScreen> createState() => _PreviousOrdersScreenState();
}

class _PreviousOrdersScreenState extends State<PreviousOrdersScreen> {
  late Future<List<Map<String, dynamic>>> _orders;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _orders = Api.getCustomerOrders(widget.party.name);
  }

  String _text(dynamic v) {
    final s = '${v ?? ''}'.trim();
    return s == 'null' ? '' : s;
  }

  String _date(dynamic v) {
    final d = DateTime.tryParse(_text(v));
    return d == null ? _text(v) : '${d.day}/${d.month}/${d.year}';
  }

  String _money(dynamic v) {
    final n = v is num ? v : num.tryParse(_text(v)) ?? 0;
    return 'Rs ${n.toStringAsFixed(2)}';
  }

  /// Reads the whole order, then asks before anything is copied.
  Future<void> _open(Map<String, dynamic> row) async {
    if (_opening) return;
    setState(() => _opening = true);
    Map<String, dynamic> order;
    try {
      order = await Api.getOrder('${row['name']}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
      return;
    } finally {
      if (mounted) setState(() => _opening = false);
    }
    if (!mounted) return;
    final copy = await _confirm(order);
    if (copy != true || !mounted) return;
    // The same check as the New Order button: no route, no order.
    if (!await ensureRouteSet(context, widget.party)) return;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            OrderScreen(party: widget.party, copyFrom: order)));
  }

  /// Every line of [order], and the choice to copy it.
  Future<bool?> _confirm(Map<String, dynamic> order) {
    final items = [
      for (final raw in (order['items'] as List? ?? const []))
        if (raw is Map) raw.cast<String, dynamic>(),
    ];
    final primary = Theme.of(context).colorScheme.primary;
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Copy ${order['name']}?',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                        '${_date(order['transaction_date'])}  ·  '
                        '${items.length} item${items.length == 1 ? '' : 's'}  ·  '
                        '${_money(order['grand_total'])}',
                        style: const TextStyle(
                            fontSize: 13.5, color: Colors.black54)),
                  ]),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final it = items[i];
                  final name = _text(it['item_name']).isEmpty
                      ? _text(it['item_code'])
                      : _text(it['item_name']);
                  final packing = _text(it['custom_packing_note']);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(name,
                                      style: const TextStyle(
                                          fontSize: 14.5,
                                          fontWeight: FontWeight.w600)),
                                  if (packing.isNotEmpty)
                                    Text(packing,
                                        style: const TextStyle(
                                            fontSize: 12.5,
                                            color: Colors.black54)),
                                ]),
                          ),
                          const SizedBox(width: 8),
                          Text(_money(it['amount']),
                              style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600)),
                        ]),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
              child: Text(
                  'The quantities are copied. Prices are today\'s, and you '
                  'pick a new delivery date. Nothing is sent until you send '
                  'it.',
                  style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50)),
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: primary,
                        minimumSize: const Size.fromHeight(50)),
                    onPressed: items.isEmpty
                        ? null
                        : () => Navigator.pop(ctx, true),
                    icon: const Icon(Icons.copy_all_outlined, size: 20),
                    label: const Text('Copy to new order',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Previous orders — ${widget.party.label}')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _orders,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
                child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(humanError(snap.error), textAlign: TextAlign.center),
            ));
          }
          final rows = snap.data ?? const [];
          if (rows.isEmpty) {
            return const Center(
                child: Text('No previous orders for this customer.'));
          }
          return Stack(children: [
            RefreshIndicator(
              onRefresh: () async {
                final f = Api.getCustomerOrders(widget.party.name);
                setState(() => _orders = f);
                await f;
              },
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: rows.length,
                itemBuilder: (_, i) {
                  final r = rows[i];
                  final sap = sapNumbersOf(r);
                  final status = approvalLabel(r['custom_po_status']);
                  return Card(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    child: ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                      title: Text('${r['name']}',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(
                          '${_date(r['transaction_date'])}'
                          '${status.isEmpty ? '' : '  ·  $status'}'
                          '${sap.isEmpty ? '' : '  ·  $sap'}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(_money(r['grand_total']),
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                        const Icon(Icons.chevron_right),
                      ]),
                      onTap: () => _open(r),
                    ),
                  );
                },
              ),
            ),
            if (_opening)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x33FFFFFF),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ]);
        },
      ),
    );
  }
}
