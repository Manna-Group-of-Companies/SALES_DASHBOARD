// Pick lists on the phone (3 Nov 2026): a rep makes one from an approved
// order in My Orders, ticking only what Hi-Tech has in stock; the sales
// manager sees every list for the team. The quantity rule is in
// core/pick_list.dart; the server checks it again (app/server/).

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/pick_list.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/services/api.dart';

/// Tick the products of [order] that go from Hi-Tech's stock now.
///
/// Only the order's own lines are listed, so nothing from outside it can be
/// picked. A product Hi-Tech has none of, or that earlier lists already took
/// in full, is shown greyed with the reason. Pops `true` once submitted.
class GeneratePickListScreen extends StatefulWidget {
  final Map<String, dynamic> order;
  const GeneratePickListScreen({super.key, required this.order});

  @override
  State<GeneratePickListScreen> createState() => _GeneratePickListScreenState();
}

class _PickRow {
  final Map<String, dynamic> line;
  final double already;
  final double available;
  final double max;
  final TextEditingController qty;
  bool ticked = false;

  _PickRow(this.line, this.already, this.available, this.max)
      : qty = TextEditingController(text: max > 0 ? trimQty(max) : '');

  String get id => '${line['name'] ?? ''}';
  String get title => '${line['item_name'] ?? line['item_code'] ?? ''}';
  String get unit => pickUnit(line);
  double get ordered => orderedForPick(line);
}

class _GeneratePickListScreenState extends State<GeneratePickListScreen> {
  late Future<List<_PickRow>> _future;
  bool _busy = false;

  String get _orderName => '${widget.order['name']}';

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<_PickRow>> _load() async {
    final results = await Future.wait([
      Api.getMinimumStock(),
      Api.getPickLists(salesOrder: _orderName),
    ]);
    final stock = results[0] as Map<String, MinStock>;
    final so = pickedSoFar(results[1] as List<PickList>);
    final lines = ((widget.order['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>());
    return [
      for (final l in lines)
        () {
          final already = so['${l['name']}'] ?? 0;
          final s = stock['${l['item_code']}'];
          final available = (s != null && s.weightsKnown) ? s.availableQty : 0.0;
          return _PickRow(l, already, available,
              maxPick(l, alreadyPicked: already, available: available));
        }(),
    ];
  }

  String _why(_PickRow r) {
    if (r.ordered <= 0) return 'Loose belts only — not picked';
    if (remainingToPick(r.line, r.already) <= 0) return 'Already on a pick list';
    return 'Not in Hi-Tech stock';
  }

  Future<void> _submit(List<_PickRow> rows) async {
    final picked = <Map<String, dynamic>>[];
    for (final r in rows.where((r) => r.ticked)) {
      final q = double.tryParse(r.qty.text.trim());
      if (q == null || q <= 0) {
        return _snack('Enter how much of ${r.title} to pick.');
      }
      if (q > r.max + 1e-9) {
        return _snack('${r.title}: at most ${trimQty(r.max)} ${r.unit}.');
      }
      picked.add({
        'sales_order_item': r.id,
        'picked_qty': q,
        'available_qty': r.available,
      });
    }
    if (picked.isEmpty) return _snack('Tick at least one product.');
    setState(() => _busy = true);
    try {
      final name = await Api.submitPickList(_orderName, picked);
      if (!mounted) return;
      _snack('Pick list $name submitted');
      Navigator.pop(context, true);
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Generate pick list')),
      body: FutureBuilder<List<_PickRow>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
                child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(humanError(snap.error),
                        textAlign: TextAlign.center)));
          }
          final rows = snap.data!;
          final pickable = rows.where((r) => r.max > 0).length;
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                  '$_orderName · ${widget.order['customer_name'] ?? widget.order['customer'] ?? ''}\n'
                  'Tick what goes from Hi-Tech\'s stock now. The rest stays on '
                  'the order and can be picked later.',
                  style: const TextStyle(fontSize: 13, color: Colors.black87)),
            ),
            if (pickable == 0)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Nothing on this order can be picked now.',
                    style: TextStyle(color: Colors.deepOrange)),
              ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: rows.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = rows[i];
                  final can = r.max > 0;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Checkbox(
                        value: r.ticked,
                        onChanged: can && !_busy
                            ? (v) => setState(() => r.ticked = v ?? false)
                            : null,
                      ),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r.title,
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: can ? null : Colors.black45)),
                              Text(
                                  'Ordered ${trimQty(r.ordered)} ${r.unit}'
                                  '${r.already > 0 ? ' · picked ${trimQty(r.already)}' : ''}'
                                  ' · Hi-Tech stock ${trimQty(r.available)}',
                                  style: const TextStyle(
                                      fontSize: 12, color: Colors.black54)),
                              if (!can)
                                Text(_why(r),
                                    style: const TextStyle(
                                        fontSize: 12, color: Colors.deepOrange)),
                            ]),
                      ),
                      if (can)
                        SizedBox(
                          width: 72,
                          child: TextField(
                            controller: r.qty,
                            enabled: r.ticked && !_busy,
                            textAlign: TextAlign.right,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: InputDecoration(
                              isDense: true,
                              helperText: 'max ${trimQty(r.max)}',
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                    ]),
                  );
                },
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => Navigator.pop(context, false),
                      child: const Padding(
                          padding: EdgeInsets.all(10), child: Text('Cancel')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed:
                          _busy || pickable == 0 ? null : () => _submit(rows),
                      child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Text(_busy ? 'Submitting…' : 'Submit')),
                    ),
                  ),
                ]),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

/// One submitted pick list.
class PickListCard extends StatelessWidget {
  final PickList list;
  final bool showOrder;
  const PickListCard({super.key, required this.list, this.showOrder = true});

  @override
  Widget build(BuildContext context) {
    final l = list;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.playlist_add_check, color: Color(0xFFF46A21)),
            const SizedBox(width: 8),
            Expanded(
                child: Text(
                    showOrder ? '${l.customerName} · ${l.salesOrder}' : l.name,
                    style: const TextStyle(fontWeight: FontWeight.bold))),
            if (!l.isSubmitted)
              const Text('Cancelled', style: TextStyle(color: Colors.red)),
          ]),
          Text(
              '${showOrder ? '${l.name} · ' : ''}${l.salesPerson} · '
              '${l.pickedOn.length >= 16 ? l.pickedOn.substring(0, 16) : l.pickedOn}',
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 6),
          for (final i in l.items)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(children: [
                Expanded(child: Text(i.itemName, style: const TextStyle(fontSize: 13))),
                Text('${trimQty(i.pickedQty)} of ${trimQty(i.orderedQty)} ${i.unit}',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              ]),
            ),
        ]),
      ),
    );
  }
}

/// Every pick list this login may see — a manager's whole team.
class PickListsScreen extends StatefulWidget {
  const PickListsScreen({super.key});
  @override
  State<PickListsScreen> createState() => _PickListsScreenState();
}

class _PickListsScreenState extends State<PickListsScreen> {
  late Future<List<PickList>> _future = Api.getPickLists();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pick Lists')),
      body: FutureBuilder<List<PickList>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
                child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(humanError(snap.error),
                        textAlign: TextAlign.center)));
          }
          final lists = snap.data!;
          return RefreshIndicator(
            onRefresh: () async =>
                setState(() => _future = Api.getPickLists()),
            child: lists.isEmpty
                ? ListView(children: const [
                    Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: Text('No pick lists yet.'))),
                  ])
                : ListView(
                    padding: const EdgeInsets.all(12),
                    children: [for (final l in lists) PickListCard(list: l)]),
          );
        },
      ),
    );
  }
}
