// Pick lists on the phone. Step 1: a table of manager-approved orders to tick.
// Step 2: a table of their products — tick what goes from Hi-Tech's stock now.
// The quantity rule is in core/pick_list.dart; the server checks it again.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/pick_list.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/services/api.dart';

const String _kApproved = 'PO Approved - Ready for SAP';
const Color _kOrange = Color(0xFFF46A21);
const Color _kHead = Color(0xFFF3F4F6);
const Color _kLine = Color(0xFFE5E7EB);

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// `2026-11-07…` → `07 Nov`.
String _day(Object? v) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch('${v ?? ''}');
  return m == null ? '' : '${m[3]} ${_months[int.parse(m[2]!) - 1]}';
}

/// The order's SAP number, or a dash. Never the ERPNext name.
String _orderNo(Map o) {
  final s = '${o['custom_sap_sales_order'] ?? ''}'.trim();
  return s.isEmpty || s == 'null' ? '—' : s;
}

String _customer(Map o) => '${o['customer_name'] ?? o['customer'] ?? ''}';

/// A header cell / body cell for the tables below.
Widget _cell(String text, {bool head = false, TextAlign align = TextAlign.left, Color? color, bool bold = false}) =>
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      child: Text(
        text,
        textAlign: align,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: head ? 11 : 13,
          fontWeight: head || bold ? FontWeight.w600 : FontWeight.normal,
          color: color ?? (head ? Colors.black54 : Colors.black87),
        ),
      ),
    );

Widget _box(bool value, ValueChanged<bool>? onChanged) => SizedBox(
  height: 36,
  child: Checkbox(
    value: value,
    visualDensity: VisualDensity.compact,
    activeColor: _kOrange,
    onChanged: onChanged == null ? null : (v) => onChanged(v ?? false),
  ),
);

/// The two buttons along the bottom.
Widget _bottomBar({
  required String back,
  required VoidCallback? onBack,
  required String go,
  required VoidCallback? onGo,
}) => SafeArea(
  child: Padding(
    padding: const EdgeInsets.all(12),
    child: Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: onBack,
            child: Padding(padding: const EdgeInsets.all(10), child: Text(back)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kOrange),
            onPressed: onGo,
            child: Padding(padding: const EdgeInsets.all(10), child: Text(go)),
          ),
        ),
      ],
    ),
  ),
);

/// Generate pick list. With [orders] (the order's own page passes its one
/// order) it opens straight on the products; otherwise it first lists the
/// rep's manager-approved orders. Pops `true` once anything was submitted.
class GeneratePickListScreen extends StatefulWidget {
  /// Full Sales Order documents, with `items`. Null: choose from the approved ones.
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
  final TextEditingController qty;
  bool ticked;

  _PickRow(this.order, this.line, this.already, this.available, this.max, double give)
    : qty = TextEditingController(text: give > 0 ? trimQty(give) : ''),
      ticked = give > 0;

  String get orderName => '${order['name']}';
  String get id => '${line['name'] ?? ''}';
  String get itemCode => '${line['item_code'] ?? ''}';
  String get title => '${line['item_name'] ?? line['item_code'] ?? ''}';
  String get unit => pickUnit(line);
  double get ordered => orderedForPick(line);
  bool get can => max > 0;

  /// Short, so it fits the Pick column.
  String get why {
    if (ordered <= 0) return 'Belts only';
    if (remainingToPick(line, already) <= 0) return 'Picked';
    return 'No stock';
  }
}

class _GeneratePickListScreenState extends State<GeneratePickListScreen> {
  /// Step 1: the approved orders. Null when [widget.orders] was given.
  Future<List<Map<String, dynamic>>>? _ordersFuture;
  final Set<String> _ticked = {};

  /// Step 2: the products. Null while choosing orders.
  Future<List<_PickRow>>? _rowsFuture;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.orders != null) {
      _rowsFuture = _loadRows(widget.orders!);
    } else {
      _ordersFuture = _approvedOrders();
    }
  }

  /// The rep's manager-approved orders, not cancelled and not yet invoiced.
  Future<List<Map<String, dynamic>>> _approvedOrders() async {
    final rows = await Api.getMyOrders();
    return [
      for (final r in rows)
        if (r['is_combined'] != true &&
            r['is_lead'] != true &&
            '${r['custom_po_status'] ?? ''}' == _kApproved &&
            '${r['docstatus'] ?? 0}' != '2' &&
            '${r['custom_sap_invoice'] ?? ''}'.trim().isEmpty)
          r,
    ];
  }

  Future<List<_PickRow>> _loadRows(List<Map<String, dynamic>> given) async {
    final results = await Future.wait([
      widget.orders != null ? Future.value(given) : Future.wait(given.map((o) => Api.getOrder('${o['name']}'))),
      Api.getMinimumStock(),
      Api.getPickLists(),
    ]);
    final orders = (results[0] as List<Map<String, dynamic>>).where(
      (o) => '${o['custom_po_status'] ?? ''}' == _kApproved,
    );
    final stock = results[1] as Map<String, MinStock>;
    final so = pickedSoFar(results[2] as List<PickList>);
    // Hi-Tech's stock is one pool: share it out across the ticked orders.
    final left = <String, double>{};
    final out = <_PickRow>[];
    for (final o in orders) {
      final named = {
        ...o,
        'customer_name':
            o['customer_name'] ?? given.firstWhere((g) => g['name'] == o['name'], orElse: () => o)['customer_name'],
      };
      for (final l in ((o['items'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>())) {
        final code = '${l['item_code']}';
        final already = so['${l['name']}'] ?? 0;
        final s = stock[code];
        final available = (s != null && s.weightsKnown) ? s.availableQty : 0.0;
        final max = maxPick(l, alreadyPicked: already, available: available);
        final pool = left[code] ?? available;
        final give = max < pool ? max : pool;
        left[code] = pool - (give > 0 ? give : 0);
        out.add(_PickRow(named, l, already, available, max, give > 0 ? give : 0));
      }
    }
    return out;
  }

  void _generate(List<Map<String, dynamic>> orders) {
    final chosen = orders.where((o) => _ticked.contains('${o['name']}')).toList();
    setState(() => _rowsFuture = _loadRows(chosen));
  }

  Future<void> _submit(List<_PickRow> rows) async {
    final byOrder = <String, List<Map<String, dynamic>>>{};
    final perItem = <String, double>{};
    final stockOf = <String, double>{};
    for (final r in rows.where((r) => r.ticked)) {
      final q = double.tryParse(r.qty.text.trim());
      if (q == null || q <= 0) return _snack('Enter how much of ${r.title} to pick.');
      if (q > r.max + 1e-9) return _snack('${r.title}: at most ${trimQty(r.max)} ${r.unit}.');
      perItem[r.itemCode] = (perItem[r.itemCode] ?? 0) + q;
      stockOf[r.itemCode] = r.available;
      (byOrder[r.orderName] ??= []).add({'sales_order_item': r.id, 'picked_qty': q, 'available_qty': r.available});
    }
    if (byOrder.isEmpty) return _snack('Tick at least one product.');
    for (final e in perItem.entries) {
      if (e.value > (stockOf[e.key] ?? 0) + 1e-9) {
        final name = rows.firstWhere((r) => r.itemCode == e.key).title;
        return _snack('$name: ${trimQty(e.value)} ticked, only ${trimQty(stockOf[e.key] ?? 0)} in stock.');
      }
    }
    setState(() => _busy = true);
    var made = 0;
    try {
      for (final e in byOrder.entries) {
        await Api.submitPickList(e.key, e.value);
        made++;
      }
      if (!mounted) return;
      _snack(made == 1 ? 'Pick list made.' : '$made pick lists made.');
      Navigator.pop(context, true);
    } catch (e) {
      // Lists already made stay made; say so, so nothing is ticked twice.
      _snack(made == 0 ? humanError(e) : '$made sent; the rest failed: ${humanError(e)}');
      if (made > 0 && mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Widget _waiting<T>(Future<T> f, Widget Function(T) done) => FutureBuilder<T>(
    future: f,
    builder: (context, snap) {
      if (snap.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snap.hasError) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(humanError(snap.error), textAlign: TextAlign.center),
          ),
        );
      }
      return done(snap.data as T);
    },
  );

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Text(text, style: const TextStyle(fontSize: 13, color: Colors.black54)),
  );

  // ------------------------------------------------------------ step 1 ---
  Widget _ordersStep(List<Map<String, dynamic>> orders) {
    final all = orders.isNotEmpty && orders.every((o) => _ticked.contains('${o['name']}'));
    return Column(
      children: [
        _note('Approved orders'),
        Expanded(
          child: orders.isEmpty
              ? const Center(child: Text('No approved orders.'))
              : SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Table(
                    columnWidths: const {
                      0: FixedColumnWidth(44),
                      1: FixedColumnWidth(72),
                      2: FlexColumnWidth(),
                      3: FixedColumnWidth(64),
                    },
                    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                    border: const TableBorder(horizontalInside: BorderSide(color: _kLine)),
                    children: [
                      TableRow(
                        decoration: const BoxDecoration(color: _kHead),
                        children: [
                          _box(
                            all,
                            (v) => setState(() {
                              _ticked.clear();
                              if (v) _ticked.addAll(orders.map((o) => '${o['name']}'));
                            }),
                          ),
                          _cell('ORDER NO.', head: true),
                          _cell('CUSTOMER', head: true),
                          _cell('DATE', head: true),
                        ],
                      ),
                      for (final o in orders)
                        TableRow(
                          children: [
                            _box(
                              _ticked.contains('${o['name']}'),
                              (v) => setState(() {
                                if (v) {
                                  _ticked.add('${o['name']}');
                                } else {
                                  _ticked.remove('${o['name']}');
                                }
                              }),
                            ),
                            _cell(_orderNo(o), bold: true),
                            _cell(_customer(o)),
                            _cell(_day(o['transaction_date'])),
                          ],
                        ),
                    ],
                  ),
                ),
        ),
        _bottomBar(
          back: 'Cancel',
          onBack: () => Navigator.pop(context, false),
          go: _ticked.isEmpty ? 'Generate pick list' : 'Generate (${_ticked.length})',
          onGo: _ticked.isEmpty ? null : () => _generate(orders),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ step 2 ---
  Widget _productsStep(List<_PickRow> rows) {
    final pickable = rows.where((r) => r.can).length;
    final table = <TableRow>[
      TableRow(
        decoration: const BoxDecoration(color: _kHead),
        children: [
          const SizedBox(),
          _cell('PRODUCT', head: true),
          _cell('ORDERED', head: true, align: TextAlign.right),
          _cell('STOCK', head: true, align: TextAlign.right),
          _cell('PICK', head: true, align: TextAlign.right),
        ],
      ),
    ];
    String? current;
    for (final r in rows) {
      if (r.orderName != current) {
        current = r.orderName;
        // The order these products belong to, as a band across the table.
        final label = '${_orderNo(r.order)}  ·  ${_customer(r.order)}';
        table.add(
          TableRow(
            decoration: const BoxDecoration(color: Color(0xFFFFF1E8)),
            children: [
              const SizedBox(),
              _cell(label, color: _kOrange, bold: true),
              const SizedBox(),
              const SizedBox(),
              const SizedBox(),
            ],
          ),
        );
      }
      final dim = r.can ? null : Colors.black38;
      table.add(
        TableRow(
          children: [
            _box(r.ticked, r.can && !_busy ? (v) => setState(() => r.ticked = v) : null),
            _cell(r.title, color: dim),
            _cell('${trimQty(r.ordered)}${r.unit == 'rolls' ? '' : ' ${r.unit}'}', align: TextAlign.right, color: dim),
            _cell(trimQty(r.available), align: TextAlign.right, color: dim),
            r.can
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    child: TextField(
                      controller: r.qty,
                      enabled: r.ticked && !_busy,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 13),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  )
                : _cell(r.why, align: TextAlign.right, color: Colors.deepOrange),
          ],
        ),
      );
    }

    return Column(
      children: [
        _note(
          rows.isEmpty
              ? 'Nothing on these orders.'
              : pickable == 0
              ? 'Nothing can be picked now.'
              : 'Tick what to pick now',
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Table(
              columnWidths: const {
                0: FixedColumnWidth(40),
                1: FlexColumnWidth(),
                2: FixedColumnWidth(62),
                3: FixedColumnWidth(52),
                4: FixedColumnWidth(68),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              border: const TableBorder(horizontalInside: BorderSide(color: _kLine)),
              children: table,
            ),
          ),
        ),
        _bottomBar(
          back: widget.orders != null ? 'Cancel' : 'Back',
          onBack: _busy
              ? null
              : () {
                  if (widget.orders != null) {
                    Navigator.pop(context, false);
                  } else {
                    setState(() => _rowsFuture = null);
                  }
                },
          go: _busy ? 'Sending…' : 'Submit pick list',
          onGo: _busy || !rows.any((r) => r.ticked) ? null : () => _submit(rows),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rowsFuture;
    return Scaffold(
      appBar: AppBar(title: const Text('Generate pick list')),
      body: rows != null ? _waiting(rows, _productsStep) : _waiting(_ordersFuture!, _ordersStep),
    );
  }
}

/// One submitted pick list: its order, date and status, then its products
/// in two columns.
class PickListCard extends StatelessWidget {
  final PickList list;
  final bool showOrder;
  const PickListCard({super.key, required this.list, this.showOrder = true});

  @override
  Widget build(BuildContext context) {
    final l = list;
    final sap = l.sapSalesOrder.trim();
    final title = showOrder
        ? [if (sap.isNotEmpty) sap, if (l.customerName.isNotEmpty) l.customerName].join('  ·  ')
        : 'Pick list';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title.isEmpty ? 'Pick list' : title, style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                if (!l.isSubmitted)
                  const Text('Cancelled', style: TextStyle(color: Colors.red))
                else
                  _PickedChip(picked: l.isDelivered),
              ],
            ),
            Text(
              '${l.salesPerson}  ·  ${_day(l.pickedOn)}',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 6),
            for (final i in l.items)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: _kLine)),
                ),
                child: Row(
                  children: [
                    Expanded(child: Text(i.itemName, style: const TextStyle(fontSize: 13))),
                    Text(
                      '${trimQty(i.pickedQty)} ${i.pickedQty == 1 && i.unit == 'rolls' ? 'roll' : i.unit}',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Picked once SAP has made the delivery for the list; until then on the pick list.
class _PickedChip extends StatelessWidget {
  final bool picked;
  const _PickedChip({required this.picked});

  @override
  Widget build(BuildContext context) {
    final color = picked ? const Color(0xFF2E7D32) : const Color(0xFFB26A00);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
      child: Text(
        picked ? 'Picked' : 'On pick list',
        style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
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
                child: Text(humanError(snap.error), textAlign: TextAlign.center),
              ),
            );
          }
          final lists = snap.data!;
          return RefreshIndicator(
            onRefresh: () async => setState(() => _future = Api.getPickLists()),
            child: lists.isEmpty
                ? ListView(
                    children: const [
                      Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: Text('No pick lists yet.')),
                      ),
                    ],
                  )
                : ListView(
                    padding: const EdgeInsets.all(12),
                    children: [for (final l in lists) PickListCard(list: l)],
                  ),
          );
        },
      ),
    );
  }
}
