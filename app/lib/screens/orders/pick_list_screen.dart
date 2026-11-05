// Pick lists on the phone (3 Nov 2026): a rep makes them from approved
// orders in My Orders, ticking only what Hi-Tech has in stock; the sales
// manager sees every list for the team. The quantity rule is in
// core/pick_list.dart; the server checks it again (app/server/).

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/pick_list.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/services/api.dart';

/// Tick what goes from Hi-Tech's stock now, across the rep's approved orders.
///
/// One screen for every manager-approved order (4 Nov 2026: one button, not
/// one per order), or for just [orders] when given — the order's own page
/// passes its one order. Only those orders' own lines are listed, grouped by
/// order, so nothing from outside them can be picked. A product Hi-Tech has
/// none of, or that earlier lists already took in full, is greyed with the
/// reason. Submitting makes one pick list per order that has a tick, since a
/// list belongs to one order. Pops `true` once anything was submitted.
class GeneratePickListScreen extends StatefulWidget {
  /// Full Sales Order documents, with `items`. Null: the rep's approved ones.
  final List<Map<String, dynamic>>? orders;
  const GeneratePickListScreen({super.key, this.orders});

  @override
  State<GeneratePickListScreen> createState() => _GeneratePickListScreenState();
}

class _PickRow {
  final Map<String, dynamic> order;
  final Map<String, dynamic> line;
  final double already;
  final double available;
  final double max;
  final double alreadyKg;
  final TextEditingController qty;
  bool ticked = false;

  _PickRow(this.order, this.line, this.already, this.available, this.max,
      this.alreadyKg)
      : qty = TextEditingController(text: max > 0 ? trimQty(max) : '');

  String get orderName => '${order['name']}';
  String get id => '${line['name'] ?? ''}';
  String get itemCode => '${line['item_code'] ?? ''}';
  String get title => '${line['item_name'] ?? line['item_code'] ?? ''}';
  String get unit => pickUnit(line);
  double get ordered => orderedForPick(line);
  bool get kgIsQty => kgFollowsQty(line);

  /// The kilos the list will carry for what is typed, as the server works
  /// them out (5 Nov 2026: rolls x the order's weight per roll). Shown, never
  /// asked for; null on a line with loose belts, whose figure needs the item.
  double? get kg {
    final q = double.tryParse(qty.text.trim()) ?? 0;
    if (q <= 0) return 0;
    if (!kgIsQty && _int(line['custom_loose_belts']) > 0) return null;
    return pickKg(line, q, alreadyPicked: already, alreadyKg: alreadyKg);
  }
}

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

const String _kApproved = 'PO Approved - Ready for SAP';

class _GeneratePickListScreenState extends State<GeneratePickListScreen> {
  late Future<List<_PickRow>> _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// The rep's approved Sales Orders that are not cancelled and not yet
  /// invoiced in full, read whole because the list rows carry no lines.
  Future<List<Map<String, dynamic>>> _approvedOrders() async {
    final rows = await Api.getMyOrders();
    final names = [
      for (final r in rows)
        if (r['is_combined'] != true &&
            r['is_lead'] != true &&
            '${r['custom_po_status'] ?? ''}' == _kApproved &&
            '${r['docstatus'] ?? 0}' != '2' &&
            '${r['custom_sap_invoice'] ?? ''}'.trim().isEmpty)
          '${r['name']}',
    ];
    return Future.wait(names.map(Api.getOrder));
  }

  Future<List<_PickRow>> _load() async {
    final results = await Future.wait([
      widget.orders != null ? Future.value(widget.orders!) : _approvedOrders(),
      Api.getMinimumStock(),
      Api.getPickLists(),
    ]);
    final orders = (results[0] as List<Map<String, dynamic>>)
        .where((o) => '${o['custom_po_status'] ?? ''}' == _kApproved);
    final stock = results[1] as Map<String, MinStock>;
    final so = pickedSoFar(results[2] as List<PickList>);
    final soKg = pickedKgSoFar(results[2] as List<PickList>);
    return [
      for (final o in orders)
        for (final l in ((o['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>()))
          () {
            final already = so['${l['name']}'] ?? 0;
            final s = stock['${l['item_code']}'];
            final available =
                (s != null && s.weightsKnown) ? s.availableQty : 0.0;
            return _PickRow(o, l, already, available,
                maxPick(l, alreadyPicked: already, available: available),
                soKg['${l['name']}'] ?? 0);
          }(),
    ];
  }

  String _why(_PickRow r) {
    if (r.ordered <= 0) return 'Loose belts only — not picked';
    if (remainingToPick(r.line, r.already) <= 0) return 'Already on a pick list';
    return 'Not in Hi-Tech stock';
  }

  Future<void> _submit(List<_PickRow> rows) async {
    final byOrder = <String, List<Map<String, dynamic>>>{};
    // Hi-Tech's stock is one pool: two orders cannot both take the last rolls.
    final perItem = <String, double>{};
    final stockOf = <String, double>{};
    for (final r in rows.where((r) => r.ticked)) {
      final q = double.tryParse(r.qty.text.trim());
      if (q == null || q <= 0) {
        return _snack('Enter how much of ${r.title} to pick.');
      }
      if (q > r.max + 1e-9) {
        return _snack('${r.title}: at most ${trimQty(r.max)} ${r.unit}.');
      }
      perItem[r.itemCode] = (perItem[r.itemCode] ?? 0) + q;
      stockOf[r.itemCode] = r.available;
      (byOrder[r.orderName] ??= []).add({
        'sales_order_item': r.id,
        'picked_qty': q,
        'available_qty': r.available,
      });
    }
    if (byOrder.isEmpty) return _snack('Tick at least one product.');
    for (final e in perItem.entries) {
      if (e.value > (stockOf[e.key] ?? 0) + 1e-9) {
        final name = rows.firstWhere((r) => r.itemCode == e.key).title;
        return _snack('$name: ${trimQty(e.value)} ticked across orders, '
            'Hi-Tech has ${trimQty(stockOf[e.key] ?? 0)}.');
      }
    }
    setState(() => _busy = true);
    final made = <String>[];
    try {
      for (final e in byOrder.entries) {
        made.add(await Api.submitPickList(e.key, e.value));
      }
      if (!mounted) return;
      _snack(
          'Pick list${made.length == 1 ? '' : 's'} ${made.join(', ')} submitted');
      Navigator.pop(context, true);
    } catch (e) {
      // Lists already made stay made; say so, so nothing is ticked twice.
      _snack(made.isEmpty
          ? humanError(e)
          : '${made.join(', ')} submitted; the rest failed: ${humanError(e)}');
      if (made.isNotEmpty && mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Widget _row(_PickRow r) {
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
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.title,
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: can ? null : Colors.black45)),
            Text(
                'Ordered ${trimQty(r.ordered)} ${r.unit}'
                '${r.already > 0 ? ' · picked ${trimQty(r.already)}' : ''}'
                ' · Hi-Tech stock ${trimQty(r.available)}',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            if (!can)
              Text(_why(r),
                  style:
                      const TextStyle(fontSize: 12, color: Colors.deepOrange)),
          ]),
        ),
        if (can)
          SizedBox(
            width: 72,
            child: TextField(
              controller: r.qty,
              enabled: r.ticked && !_busy,
              onChanged: (_) => setState(() {}),
              textAlign: TextAlign.right,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                isDense: true,
                helperText: 'max ${trimQty(r.max)}',
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        if (can && !r.kgIsQty)
          SizedBox(
            width: 64,
            child: Text(
                r.kg == null ? 'by roll wt' : '${trimQty(r.kg!)} kg',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ),
      ]),
    );
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
          // Grouped under each order, in the order they came.
          final children = <Widget>[];
          String? current;
          for (final r in rows) {
            if (r.orderName != current) {
              current = r.orderName;
              children.add(Padding(
                padding: const EdgeInsets.fromLTRB(8, 14, 8, 2),
                child: Text(
                    '${r.order['customer_name'] ?? r.order['customer'] ?? ''}'
                    '  ·  ${r.orderName}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: Color(0xFFF46A21))),
              ));
            }
            children.add(_row(r));
          }
          return Column(children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                  "Manager-approved products. Tick what goes from Hi-Tech's "
                  'stock now; the kilos follow from the rolls. The rest stays '
                  'on the order to pick later.',
                  style: TextStyle(fontSize: 13, color: Colors.black87)),
            ),
            if (rows.isEmpty)
              const Expanded(
                  child: Center(
                      child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No manager-approved orders to pick from.',
                    textAlign: TextAlign.center),
              )))
            else ...[
              if (pickable == 0)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Nothing can be picked now.',
                      style: TextStyle(color: Colors.deepOrange)),
                ),
              Expanded(
                child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: children),
              ),
            ],
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                          _busy ? null : () => Navigator.pop(context, false),
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
                Text('${trimQty(i.pickedQty)} of ${trimQty(i.orderedQty)} ${i.unit}'
                    '${i.pickedKg > 0 && i.unit.toLowerCase() != 'kg' ? ' · ${trimQty(i.pickedKg)} kg' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              ]),
            ),
          if (l.sapError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('SAP: ${l.sapError}',
                  style: const TextStyle(fontSize: 12, color: Colors.deepOrange)),
            )
          else if (l.sapPickList.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  'SAP pick list ${l.sapPickList}'
                  '${l.hitechInvoice.isNotEmpty ? ' · Hi-Tech invoice ${l.hitechInvoice}' : ''}'
                  '${l.mtDelivery.isNotEmpty ? ' · delivery ${l.mtDelivery}' : ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
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
