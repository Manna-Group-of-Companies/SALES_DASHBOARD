// Pick List page: the rep's manager-approved orders, each with its ordered
// items and what became of them (picked once SAP has delivered), and one
// Generate pick list button for all of them at once.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/pick_list.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/screens/orders/pick_list_screen.dart';
import 'package:manna_field_sales/services/api.dart';

const String _kApproved = 'PO Approved - Ready for SAP';
const Color _kOrange = Color(0xFFF46A21);
const Color _kLine = Color(0xFFE5E7EB);

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// `2026-11-07…` → `07 Nov 2026`.
String _date(Object? v) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch('${v ?? ''}');
  return m == null ? '—' : '${m[3]} ${_months[int.parse(m[2]!) - 1]} ${m[1]}';
}

String _text(Object? v) {
  final s = '${v ?? ''}'.trim();
  return s == 'null' ? '' : s;
}

/// The SAP order number, or a dash. Never the ERPNext name.
String _orderNo(Map o) => _text(o['custom_sap_sales_order']).isEmpty ? '—' : _text(o['custom_sap_sales_order']);

String _customer(Map o) => _text(o['customer_name']).isNotEmpty ? _text(o['customer_name']) : _text(o['customer']);

class _OrderBlock {
  final Map<String, dynamic> order;
  final List<PickList> lists;
  _OrderBlock(this.order, this.lists);
  List<Map<String, dynamic>> get items =>
      ((order['items'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();

  /// Something on this order is not on a pick list yet.
  bool get anyLeft {
    final picked = pickedSoFar(lists);
    return items.any((l) => remainingToPick(l, picked['${l['name']}'] ?? 0) > 0);
  }
}

class PickListPage extends StatefulWidget {
  const PickListPage({super.key});
  @override
  State<PickListPage> createState() => _PickListPageState();
}

class _PickListPageState extends State<PickListPage> {
  late Future<List<_OrderBlock>> _future = _load();

  /// Filters: one customer (null = all) and an order-date range (null = all dates).
  String? _cust;
  DateTimeRange? _range;

  static String _iso(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  bool _shown(_OrderBlock b) {
    if (_cust != null && _customer(b.order) != _cust) return false;
    final r = _range;
    if (r != null) {
      final d = _text(b.order['transaction_date']);
      if (d.length < 10) return false;
      final day = d.substring(0, 10);
      if (day.compareTo(_iso(r.start)) < 0 || day.compareTo(_iso(r.end)) > 0) return false;
    }
    return true;
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: _range,
      helpText: 'Order date',
      saveText: 'Apply',
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(colorScheme: Theme.of(context).colorScheme.copyWith(primary: _kOrange)),
        child: child!,
      ),
    );
    if (r != null) setState(() => _range = r);
  }

  String get _rangeLabel {
    final r = _range;
    if (r == null) return 'All dates';
    String f(DateTime d) => '${d.day.toString().padLeft(2, '0')} ${_months[d.month - 1]}';
    return r.start == r.end ? f(r.start) : '${f(r.start)} – ${f(r.end)}';
  }

  /// Customer drop-down and the calendar button.
  Widget _filters(List<_OrderBlock> all) {
    final customers = {for (final b in all) _customer(b.order)}.where((c) => c.isNotEmpty).toList()..sort();
    if (_cust != null && !customers.contains(_cust)) _cust = null;
    const border = OutlineInputBorder(borderSide: BorderSide(color: _kLine));
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 12),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String?>(
              key: ValueKey(_cust),
              initialValue: _cust,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.store_outlined, size: 20),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                border: border,
                enabledBorder: border,
              ),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('All customers')),
                for (final c in customers)
                  DropdownMenuItem<String?>(
                    value: c,
                    child: Text(c, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _cust = v),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
              side: BorderSide(color: _range == null ? _kLine : _kOrange),
              foregroundColor: _range == null ? Colors.black87 : _kOrange,
            ),
            onPressed: _pickDates,
            icon: const Icon(Icons.calendar_month, size: 20),
            label: Text(_rangeLabel, style: const TextStyle(fontSize: 13)),
          ),
          if (_range != null)
            IconButton(
              tooltip: 'All dates',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _range = null),
              icon: const Icon(Icons.close, size: 20),
            ),
        ],
      ),
    );
  }

  Future<List<_OrderBlock>> _load() async {
    final rows = await Api.getMyOrders();
    final names = [
      for (final r in rows)
        if (r['is_combined'] != true &&
            r['is_lead'] != true &&
            '${r['custom_po_status'] ?? ''}' == _kApproved &&
            '${r['docstatus'] ?? 0}' != '2' &&
            _text(r['custom_sap_invoice']).isEmpty)
          '${r['name']}',
    ];
    final results = await Future.wait([Future.wait(names.map(Api.getOrder)), Api.getPickLists()]);
    final orders = results[0] as List<Map<String, dynamic>>;
    final lists = results[1] as List<PickList>;
    return [
      for (final o in orders)
        if ('${o['custom_po_status'] ?? ''}' == _kApproved)
          _OrderBlock(o, lists.where((l) => l.salesOrder == o['name']).toList()),
    ];
  }

  /// Every approved order with something still to pick, in one pick list screen.
  Future<void> _generate(List<_OrderBlock> blocks) async {
    final open = [
      for (final b in blocks)
        if (b.anyLeft) b.order,
    ];
    if (open.isEmpty) return;
    final done = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => GeneratePickListScreen(orders: open)),
    );
    if (done == true && mounted) setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pick List')),
      body: FutureBuilder<List<_OrderBlock>>(
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
          final all = snap.data!;
          final blocks = all.where(_shown).toList();
          final anyLeft = blocks.any((b) => b.anyLeft);
          return Column(
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async => setState(() => _future = _load()),
                  child: ListView(
                    padding: const EdgeInsets.all(10),
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(4, 2, 4, 10),
                        child: Text('Approved orders', style: TextStyle(fontSize: 13, color: Colors.black54)),
                      ),
                      if (all.isNotEmpty) _filters(all),
                      if (blocks.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Center(
                            child: Text(all.isEmpty ? 'No approved orders.' : 'No orders match these filters.'),
                          ),
                        ),
                      for (var i = 0; i < blocks.length; i++) _OrderCard(block: blocks[i], expanded: i == 0),
                    ],
                  ),
                ),
              ),
              if (blocks.isNotEmpty)
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: _kOrange),
                        onPressed: anyLeft ? () => _generate(blocks) : null,
                        icon: const Icon(Icons.playlist_add_check),
                        label: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Text(anyLeft ? 'Generate pick list' : 'All items picked'),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// What became of one ordered product.
enum _LineState { notPicked, onList, partPicked, picked }

const _stateText = {
  _LineState.notPicked: 'Not picked',
  _LineState.onList: 'On pick list',
  _LineState.partPicked: 'Part picked',
  _LineState.picked: 'Picked',
};
const _stateColor = {
  _LineState.notPicked: Color(0xFF6B7280),
  _LineState.onList: Color(0xFFB26A00),
  _LineState.partPicked: Color(0xFF1565C0),
  _LineState.picked: Color(0xFF2E7D32),
};
const _stateIcon = {
  _LineState.notPicked: Icons.radio_button_unchecked,
  _LineState.onList: Icons.schedule,
  _LineState.partPicked: Icons.timelapse,
  _LineState.picked: Icons.check_circle,
};

/// One ordered product: what was ordered, what SAP has delivered, and its state.
class _Line {
  final String name;
  final String ordered;
  final double delivered;
  final _LineState state;
  _Line(this.name, this.ordered, this.delivered, this.state);
}

/// Picked counts only what SAP has delivered; a product on a list SAP has not
/// delivered yet is "On pick list".
List<_Line> _lines(_OrderBlock b) {
  final delivered = pickedSoFar(b.lists.where((x) => x.isDelivered));
  final waiting = pickedSoFar(b.lists.where((x) => !x.isDelivered));
  return [
    for (final l in b.items)
      () {
        final ordered = orderedForPick(l);
        final d = delivered['${l['name']}'] ?? 0;
        final w = waiting['${l['name']}'] ?? 0;
        final unit = pickUnit(l);
        final st = (ordered > 0 && d >= ordered - 1e-9)
            ? _LineState.picked
            : w > 0
            ? _LineState.onList
            : d > 0
            ? _LineState.partPicked
            : _LineState.notPicked;
        final u = unit == 'rolls' && ordered == 1 ? 'roll' : unit;
        return _Line(
          _text(l['item_name']).isEmpty ? _text(l['item_code']) : _text(l['item_name']),
          '${trimQty(ordered)} $u'.trim(),
          d,
          st,
        );
      }(),
  ];
}

/// One order: customer and order number on top, then its products as a list.
class _OrderCard extends StatelessWidget {
  final _OrderBlock block;
  final bool expanded;
  const _OrderCard({required this.block, required this.expanded});

  @override
  Widget build(BuildContext context) {
    final o = block.order;
    final lines = _lines(block);
    int count(_LineState s) => lines.where((l) => l.state == s).length;
    final onList = count(_LineState.onList) + count(_LineState.partPicked);
    final picked = count(_LineState.picked);
    final summary = [
      '${lines.length} product${lines.length == 1 ? '' : 's'}',
      if (onList > 0) '$onList on pick list',
      if (picked > 0) '$picked picked',
    ].join('  ·  ');
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: _kLine),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: expanded,
        shape: const Border(),
        tilePadding: const EdgeInsets.fromLTRB(14, 4, 10, 4),
        title: Text(_customer(o), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            'Order ${_orderNo(o)}  ·  ${_date(o['transaction_date'])}\n$summary',
            style: const TextStyle(fontSize: 12.5, color: Colors.black54, height: 1.4),
          ),
        ),
        childrenPadding: const EdgeInsets.only(bottom: 6),
        children: [
          const Divider(height: 1, color: _kLine),
          for (var i = 0; i < lines.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 14, endIndent: 14, color: _kLine),
            _LineRow(line: lines[i]),
          ],
        ],
      ),
    );
  }
}

/// Product name with "1 roll ordered" under it, and its state on the right.
class _LineRow extends StatelessWidget {
  final _Line line;
  const _LineRow({required this.line});

  @override
  Widget build(BuildContext context) {
    final l = line;
    final color = _stateColor[l.state]!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  '${l.ordered} ordered${l.delivered > 0 && l.state != _LineState.picked ? '  ·  ${trimQty(l.delivered)} picked' : ''}',
                  style: const TextStyle(fontSize: 12.5, color: Colors.black54),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_stateIcon[l.state], size: 14, color: color),
                const SizedBox(width: 4),
                Text(
                  _stateText[l.state]!,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
