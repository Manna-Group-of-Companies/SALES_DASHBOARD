// Pick lists on the phone (3 Nov 2026): a rep makes them from approved
// orders, ticking only what Hi-Tech has in stock; the sales manager sees
// every list for the team. The quantity rule is in core/pick_list.dart; the
// server checks it again (app/server/).
//
// Since 7 Nov 2026 the rep's way in is its own page, "Pick List" on the home
// screen: one day at a time, every product ordered that day, picked from
// there, with what is already picked and what production has approved shown
// on the same row.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/pick_list.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/services/api.dart';

/// The rep's Pick List page (7 Nov 2026), the home screen's "Pick List" and
/// the only place a pick list is made (My Orders and the order's own page
/// only show them).
///
/// A date bar, every Sales Order the rep placed that day with all its
/// products, and on each product what it is waiting for - the manager's
/// approval, Hi-Tech's stock, production's approval of its pick list. Only
/// products of manager-approved orders can be ticked; the server refuses the
/// rest anyway.
///
/// Submitting makes one pick list per order that has a tick, since a list
/// belongs to one order, and the page stays open showing the new lists.
class GeneratePickListScreen extends StatefulWidget {
  const GeneratePickListScreen({super.key});

  @override
  State<GeneratePickListScreen> createState() => _GeneratePickListScreenState();
}

/// One product of a pick list already made against an order line.
class _Picked {
  final PickList list;
  final PickListItem item;
  const _Picked(this.list, this.item);
}

class _PickRow {
  final Map<String, dynamic> order;
  final Map<String, dynamic> line;
  final double already;
  final double available;
  final double max;
  final double alreadyKg;

  /// The order is manager-approved, so this line may be picked.
  final bool orderApproved;

  /// The pick lists already made for this line, oldest first.
  final List<_Picked> picks;
  final TextEditingController qty;
  bool ticked = false;

  _PickRow(this.order, this.line, this.already, this.available, this.max,
      this.alreadyKg, this.orderApproved, this.picks)
      : qty = TextEditingController(text: max > 0 ? trimQty(max) : '');

  String get orderName => '${order['name']}';
  String get id => '${line['name'] ?? ''}';
  String get itemCode => '${line['item_code'] ?? ''}';
  String get title => '${line['item_name'] ?? line['item_code'] ?? ''}';
  String get unit => pickUnit(line);
  double get ordered => orderedForPick(line);
  bool get kgIsQty => kgFollowsQty(line);

  /// Can be ticked now.
  bool get canPick => orderApproved && max > 0;

  /// Every pick list made for this line has been approved by production.
  bool get allPicksApproved =>
      picks.isNotEmpty && picks.every((p) => p.list.isApproved);

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
const Color _kOrange = Color(0xFFF46A21);
const Color _kGreen = Color(0xFF2E7D32);
const Color _kAmber = Color(0xFFB26A00);

const _kMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];
const _kDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

class _GeneratePickListScreenState extends State<GeneratePickListScreen> {
  late Future<List<_PickRow>> _future;
  bool _busy = false;
  DateTime _day = _dateOnly(DateTime.now());

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  void _reload() => setState(() => _future = _load());

  void _setDay(DateTime d) {
    _day = _dateOnly(d);
    _reload();
  }

  Future<List<_PickRow>> _load() async {
    final results = await Future.wait([
      Api.getMyOrdersOn(_ymd(_day)),
      Api.getMinimumStock(),
      Api.getPickLists(),
    ]);
    final orders = (results[0] as List<Map<String, dynamic>>)
        .where((o) => '${o['docstatus'] ?? 0}' != '2');
    final stock = results[1] as Map<String, MinStock>;
    final lists = results[2] as List<PickList>;
    final so = pickedSoFar(lists);
    final soKg = pickedKgSoFar(lists);

    // The lists already made, per order line, oldest first.
    final picksOf = <String, List<_Picked>>{};
    for (final l in lists.reversed) {
      if (!l.isSubmitted) continue;
      for (final i in l.items) {
        (picksOf[i.salesOrderItem] ??= []).add(_Picked(l, i));
      }
    }

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
            return _PickRow(
                o,
                l,
                already,
                available,
                maxPick(l, alreadyPicked: already, available: available),
                soKg['${l['name']}'] ?? 0,
                '${o['custom_po_status'] ?? ''}' == _kApproved,
                picksOf['${l['name']}'] ?? const []);
          }(),
    ];
  }

  /// Why a row cannot be ticked, in the rep's words. Null when it can be.
  String? _why(_PickRow r) {
    if (r.canPick) return null;
    if (!r.orderApproved) return 'Waiting for manager approval';
    if (r.ordered <= 0) return 'Loose belts only — not picked';
    if (remainingToPick(r.line, r.already) <= 0) {
      return r.picks.isEmpty ? 'Nothing left to pick' : null;
    }
    return 'Not in Hi-Tech stock';
  }

  Future<void> _submit(List<_PickRow> rows) async {
    final byOrder = <String, List<Map<String, dynamic>>>{};
    // Hi-Tech's stock is one pool: two orders cannot both take the last rolls.
    final perItem = <String, double>{};
    final stockOf = <String, double>{};
    for (final r in rows.where((r) => r.ticked && r.canPick)) {
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
      // The page stays and shows the new lists on their rows.
      _reload();
    } catch (e) {
      // Lists already made stay made; say so, so nothing is ticked twice.
      _snack(made.isEmpty
          ? humanError(e)
          : '${made.join(', ')} submitted; the rest failed: ${humanError(e)}');
      if (made.isNotEmpty && mounted) _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // ------------------------------------------------------------ day bar ---

  Widget _dayBar() {
    final today = _dateOnly(DateTime.now());
    final isToday = _day == today;
    final label = isToday
        ? 'Today, ${_day.day} ${_kMonths[_day.month - 1]}'
        : '${_kDays[_day.weekday - 1]}, ${_day.day} ${_kMonths[_day.month - 1]} ${_day.year}';
    return Material(
      color: const Color(0xFFFFF3EC),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(children: [
          IconButton(
            tooltip: 'Day before',
            icon: const Icon(Icons.chevron_left),
            onPressed: _busy
                ? null
                : () => _setDay(_day.subtract(const Duration(days: 1))),
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: _day,
                        firstDate: today.subtract(const Duration(days: 365)),
                        lastDate: today,
                      );
                      if (d != null) _setDay(d);
                    },
              icon: const Icon(Icons.calendar_month, size: 18, color: _kOrange),
              label: Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Colors.black87)),
            ),
          ),
          IconButton(
            tooltip: 'Next day',
            icon: const Icon(Icons.chevron_right),
            onPressed: _busy || isToday
                ? null
                : () => _setDay(_day.add(const Duration(days: 1))),
          ),
        ]),
      ),
    );
  }

  Widget _summary(List<_PickRow> rows) {
    final picked = rows.where((r) => r.picks.isNotEmpty).length;
    final approved = rows.where((r) => r.allPicksApproved).length;
    final toPick = rows.where((r) => r.canPick).length;
    Widget stat(String n, String l, Color c) => Expanded(
          child: Column(children: [
            Text(n,
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: c)),
            Text(l, style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
      child: Row(children: [
        stat('${rows.length}', 'Ordered', Colors.black87),
        stat('$toPick', 'To pick', _kOrange),
        stat('$picked', 'Picked', _kAmber),
        stat('$approved', 'Approved', _kGreen),
      ]),
    );
  }

  // --------------------------------------------------------------- rows ---

  Widget _orderHeader(_PickRow r) {
    final approved = r.orderApproved;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 2),
      child: Row(children: [
        Expanded(
          child: Text(
              '${r.order['customer_name'] ?? r.order['customer'] ?? ''}'
              '  ·  ${r.orderName}',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, color: _kOrange)),
        ),
        _Chip(
              text: approved ? 'Manager approved' : 'Awaiting manager',
              icon: approved ? Icons.check_circle : Icons.hourglass_top,
              color: approved ? _kGreen : Colors.black45),
      ]),
    );
  }

  Widget _pickedLine(_Picked p) {
    final ok = p.list.isApproved;
    final when = p.list.pickedOn.length >= 16
        ? p.list.pickedOn.substring(11, 16)
        : '';
    final kg = p.item.pickedKg > 0 && p.item.unit.toLowerCase() != 'kg'
        ? ' · ${trimQty(p.item.pickedKg)} kg'
        : '';
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(children: [
        Icon(ok ? Icons.verified : Icons.hourglass_top,
            size: 14, color: ok ? _kGreen : _kAmber),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
              '${p.list.name}${when.isEmpty ? '' : ' ($when)'}: picked '
              '${trimQty(p.item.pickedQty)} ${p.item.unit}$kg · '
              '${ok ? 'Approved by production' : 'Awaiting production approval'}',
              style: TextStyle(
                  fontSize: 12,
                  color: ok ? _kGreen : _kAmber,
                  fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }

  Widget _row(_PickRow r) {
    final can = r.canPick;
    final why = _why(r);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Checkbox(
          value: r.ticked,
          onChanged: can && !_busy
              ? (v) => setState(() => r.ticked = v ?? false)
              : null,
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.title,
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: can || r.picks.isNotEmpty ? null : Colors.black45)),
              Text(
                  'Ordered ${trimQty(r.ordered)} ${r.unit}'
                  '${r.already > 0 ? ' · picked ${trimQty(r.already)}' : ''}'
                  ' · Hi-Tech stock ${trimQty(r.available)}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
              for (final p in r.picks) _pickedLine(p),
              if (why != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(why,
                      style: TextStyle(
                          fontSize: 12,
                          color: r.orderApproved
                              ? Colors.deepOrange
                              : Colors.black45)),
                ),
            ]),
          ),
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
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                  r.kg == null ? 'by roll wt' : '${trimQty(r.kg!)} kg',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick List'),
        actions: [
          IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: _busy ? null : _reload),
        ],
      ),
      body: Column(children: [
        _dayBar(),
        Expanded(
          child: FutureBuilder<List<_PickRow>>(
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
              final pickable = rows.where((r) => r.canPick).length;
              final ticked = rows.where((r) => r.ticked).length;
              // Grouped under each order, in the order they came.
              final children = <Widget>[];
              String? current;
              for (final r in rows) {
                if (r.orderName != current) {
                  current = r.orderName;
                  children.add(_orderHeader(r));
                }
                children.add(_row(r));
              }
              return Column(children: [
                if (rows.isNotEmpty) _summary(rows),
                if (rows.isEmpty)
                  const Expanded(
                      child: Center(
                          child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No orders on this day.',
                        textAlign: TextAlign.center),
                  )))
                else ...[
                  if (pickable == 0)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text('Nothing can be picked now.',
                          style: TextStyle(color: Colors.deepOrange)),
                    ),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: () async => _reload(),
                      child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          children: children),
                    ),
                  ),
                ],
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed:
                            _busy || pickable == 0 ? null : () => _submit(rows),
                        child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Text(_busy
                                ? 'Submitting…'
                                : ticked == 0
                                    ? 'Pick'
                                    : 'Pick $ticked product${ticked == 1 ? '' : 's'}')),
                      ),
                    ),
                  ),
                ),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

/// A small coloured status label.
class _Chip extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color color;
  const _Chip({required this.text, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(text,
            style: TextStyle(
                fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
      ]),
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
            const Icon(Icons.playlist_add_check, color: _kOrange),
            const SizedBox(width: 8),
            Expanded(
                child: Text(
                    showOrder ? '${l.customerName} · ${l.salesOrder}' : l.name,
                    style: const TextStyle(fontWeight: FontWeight.bold))),
            if (!l.isSubmitted)
              const Text('Cancelled', style: TextStyle(color: Colors.red))
            else
              _ApprovalChip(approved: l.isApproved),
          ]),
          Text(
              '${showOrder ? '${l.name} · ' : ''}${l.salesPerson} · '
              '${l.pickedOn.length >= 16 ? l.pickedOn.substring(0, 16) : l.pickedOn}',
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          if (l.isApproved)
            Text(
                'Approved by production'
                '${l.approvedByName.isNotEmpty ? ' (${l.approvedByName})' : ''}'
                '${l.approvedOn.length >= 16 ? ' · ${l.approvedOn.substring(0, 16)}' : ''}',
                style: const TextStyle(fontSize: 12, color: _kGreen)),
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

/// Whether production has approved a pick list (5 Nov 2026).
class _ApprovalChip extends StatelessWidget {
  final bool approved;
  const _ApprovalChip({required this.approved});

  @override
  Widget build(BuildContext context) => _Chip(
      text: approved ? 'Approved' : 'Awaiting approval',
      icon: approved ? Icons.verified : Icons.hourglass_top,
      color: approved ? _kGreen : _kAmber);
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
