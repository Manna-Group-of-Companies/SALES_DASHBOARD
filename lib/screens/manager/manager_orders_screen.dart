// Every order the manager's team has raised, a week at a time.
//
// The approvals queue only ever shows work outstanding, which means an order
// disappears the moment it is approved — and then there is nowhere to answer
// "what happened to that one?". This screen is the other half: decided and
// undecided together, with whatever the production manager has since put on it.
//
// A week is the unit because that is how the factory plans. Picking a month
// would bury the order somebody is asking about; picking a day would mean
// hunting through seven screens to find it.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/core/server_clock.dart';
import 'package:manna_field_sales/screens/manager/manager_order_review_screen.dart';
import 'package:manna_field_sales/services/api.dart';

/// A Monday-to-Sunday window, with a label a human recognises.
class _Week {
  final DateTime start;
  final DateTime end;
  final int offset;
  const _Week(this.start, this.end, this.offset);

  String get from => _iso(start);
  String get to => _iso(end);

  static String _iso(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static const _months = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String get label {
    final a = '${start.day} ${_months[start.month]}';
    final b = '${end.day} ${_months[end.month]}';
    switch (offset) {
      case 0:
        return 'This week  ($a – $b)';
      case -1:
        return 'Last week  ($a – $b)';
      default:
        return '$a – $b';
    }
  }
}

class ManagerOrdersScreen extends StatefulWidget {
  const ManagerOrdersScreen({super.key});
  @override
  State<ManagerOrdersScreen> createState() => _ManagerOrdersScreenState();
}

class _ManagerOrdersScreenState extends State<ManagerOrdersScreen> {
  late List<_Week> _weeks;
  late _Week _selected;
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _weeks = _buildWeeks();
    _selected = _weeks.first;
    _future = _load();
  }

  /// This week and the twelve before it. Judged against the server's clock so
  /// a phone with a wrong date does not offer the wrong weeks.
  List<_Week> _buildWeeks() {
    final now = ServerClock.I.now();
    final today = DateTime(now.year, now.month, now.day);
    final thisMonday = today.subtract(Duration(days: today.weekday - 1));
    return [
      for (var i = 0; i <= 12; i++)
        _Week(
          thisMonday.subtract(Duration(days: 7 * i)),
          thisMonday.subtract(Duration(days: 7 * i - 6)),
          -i,
        )
    ];
  }

  Future<List<Map<String, dynamic>>> _load() =>
      Api.getTeamOrders(from: _selected.from, to: _selected.to);

  void _reload() => setState(() => _future = _load());

  Future<void> _open(Map<String, dynamic> r) async {
    final decided = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) =>
              ManagerOrderReviewScreen(orderName: '${r['name']}')),
    );
    if (decided == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Team Orders'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      body: Column(children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: InputDecorator(
            decoration: const InputDecoration(
                labelText: 'Week',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<_Week>(
                value: _selected,
                isExpanded: true,
                items: [
                  for (final w in _weeks)
                    DropdownMenuItem(value: w, child: Text(w.label))
                ],
                onChanged: (w) {
                  if (w == null) return;
                  setState(() {
                    _selected = w;
                    _future = _load();
                  });
                },
              ),
            ),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _future,
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
              final rows = snap.data ?? [];
              if (rows.isEmpty) {
                return Center(
                    child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('No orders in ${_selected.label}.',
                            textAlign: TextAlign.center)));
              }
              final waiting =
                  rows.where((r) => !orderApproved(r)).length;
              return RefreshIndicator(
                onRefresh: () async {
                  _reload();
                  await _future;
                },
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  itemCount: rows.length + 1,
                  itemBuilder: (_, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                            '${rows.length} order${rows.length == 1 ? '' : 's'}'
                            '${waiting > 0 ? '  ·  $waiting waiting on you' : '  ·  all decided'}',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: waiting > 0
                                    ? Colors.orange.shade800
                                    : Colors.green)),
                      );
                    }
                    return _orderCard(rows[i - 1]);
                  },
                ),
              );
            },
          ),
        ),
      ]),
    );
  }

  Widget _orderCard(Map<String, dynamic> r) {
    final approved = orderApproved(r);
    final status = '${r['custom_po_status'] ?? ''}';
    final rejected = status == 'Rejected';
    final production = '${r['custom_production_status'] ?? ''}';
    final finish = '${r['custom_production_finish_date'] ?? ''}';

    final colour = rejected
        ? Colors.red
        : (approved ? Colors.green : Colors.orange.shade800);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _open(r),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: Text('${r['customer'] ?? r['name']}',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600))),
              Text('Rs ${_num(r['grand_total']).toStringAsFixed(0)}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 2),
            Text(
                '${r['name']}  ·  ${r['custom_sales_person'] ?? '—'}'
                '  ·  ${r['transaction_date'] ?? ''}',
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
            const SizedBox(height: 6),
            Row(children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: colour.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4)),
                child: Text(approvalLabel(status).toUpperCase(),
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: colour)),
              ),
              const Spacer(),
              if (!approved && !rejected)
                const Text('Tap to review',
                    style: TextStyle(fontSize: 11, color: Colors.black45)),
            ]),
            // What the factory has done with it since. Only meaningful once
            // approved — before that, production has never seen the order.
            if (approved) ...[
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.precision_manufacturing_outlined,
                    size: 14, color: Colors.black54),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                      'Production: '
                      '${production.isEmpty || production == 'null' ? 'Not started' : production}'
                      '${(finish.isNotEmpty && finish != 'null') ? '  ·  est. finish $finish' : ''}',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.black54)),
                ),
              ]),
            ],
            if ('${r['delivery_date'] ?? ''}'.isNotEmpty &&
                '${r['delivery_date']}' != 'null')
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Required by ${r['delivery_date']}',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.black54)),
              ),
          ]),
        ),
      ),
    );
  }

  static double _num(dynamic v) =>
      v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
}
