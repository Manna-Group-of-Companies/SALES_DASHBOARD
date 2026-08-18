// The stock manager's tablet view — flow A's close.
//
// A production manager raises a replenishment order (dashboard, or here, out
// of scope for this screen); this is where the stock manager marks one
// received once the goods physically reach the floor. Receiving creates
// exactly one new dated batch — never adds to an existing one — so the aging
// bands see a real arrival date. See shared/PRODUCTION_FLOWS.md.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/models/min_stock.dart' show trimQty;
import 'package:manna_field_sales/models/production_order.dart';
import 'package:manna_field_sales/services/api.dart';

class ReplenishmentReceivingScreen extends StatefulWidget {
  const ReplenishmentReceivingScreen({super.key});
  @override
  State<ReplenishmentReceivingScreen> createState() =>
      _ReplenishmentReceivingScreenState();
}

class _ReplenishmentReceivingScreenState
    extends State<ReplenishmentReceivingScreen> {
  late Future<List<ProductionOrderDetail>> _fut;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => _fut = Api.getOpenReplenishmentOrders();

  Future<void> _receive(ProductionOrderDetail d) async {
    final qtyCtrl = TextEditingController(text: trimQty(d.order.qty));
    final beltsCtrl = TextEditingController(
        text: d.order.looseBelts > 0 ? '${d.order.looseBelts}' : '');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark received'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(d.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
                textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text('Raised for ${trimQty(d.order.qty)} ${d.unit} by ${d.order.raisedBy}',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 12),
            TextField(
              controller: qtyCtrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Quantity received',
                suffixText: d.unit,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: beltsCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Loose belts (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'This adds a new dated batch to the shelf and closes the order. '
              'Enter what was actually made — it may differ from what was '
              'raised.',
              style: TextStyle(fontSize: 11.5, color: Colors.black54, height: 1.4),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Received')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final qty = double.tryParse(qtyCtrl.text.trim()) ?? -1;
    final belts = int.tryParse(beltsCtrl.text.trim()) ?? 0;
    if (qty <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a quantity greater than zero.')));
      return;
    }

    setState(() => _busy = true);
    try {
      await Api.receiveProductionOrder(
        name: d.order.name,
        itemCode: d.order.itemCode,
        qty: qty,
        looseBelts: belts,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${d.name} received — ${trimQty(qty)} ${d.unit} added to stock.')));
      setState(_reload);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Replenishment'), actions: [
        IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(_reload)),
      ]),
      body: FutureBuilder<List<ProductionOrderDetail>>(
        future: _fut,
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
          final rows = snap.data ?? const [];
          return RefreshIndicator(
            onRefresh: () async {
              setState(_reload);
              await _fut;
            },
            child: rows.isEmpty
                ? ListView(children: const [
                    Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'Nothing awaiting receipt. Runs the production '
                        'manager raises will appear here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.black54, height: 1.5),
                      ),
                    ),
                  ])
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                    itemCount: rows.length,
                    itemBuilder: (_, i) => _card(rows[i]),
                  ),
          );
        },
      ),
    );
  }

  Widget _card(ProductionOrderDetail d) {
    final o = d.order;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(d.name,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600)),
            ),
            _badge(o.status),
          ]),
          const SizedBox(height: 6),
          Text(
              'Raised for ${trimQty(o.qty)} ${d.unit}'
              '${o.looseBelts > 0 ? ' + ${o.looseBelts} belts' : ''}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Text('by ${o.raisedBy.isEmpty ? 'Unknown' : o.raisedBy}'
              '${o.raisedOn.isEmpty ? '' : ' · ${o.raisedOn}'}',
              style: const TextStyle(fontSize: 11, color: Colors.black54)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : () => _receive(d),
              icon: const Icon(Icons.inventory, size: 16),
              label: const Text('Mark received'),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _badge(String status) {
    final urgent = status == 'Open';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: (urgent ? const Color(0xFFB3261E) : const Color(0xFF1A56A8))
              .withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4)),
      child: Text(status,
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: urgent ? const Color(0xFFB3261E) : const Color(0xFF1A56A8))),
    );
  }
}
