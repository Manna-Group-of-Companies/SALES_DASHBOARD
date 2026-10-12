// Every order the manager's team has raised, a week at a time.
//
// Decided and undecided together, so "what happened to that one?" has an
// answer after the order leaves the queue. A week is the unit because that is
// how the factory plans.
//
// Filtered the way the dashboard's Team Orders is (OrdersListPage.tsx): by
// week, by approval state with a count on each, by rep, and by a search over
// order, party and rep. The state filter opens on "To approve", because that
// is what the manager came for.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/core/sap_order_state.dart';
import 'package:manna_field_sales/core/server_clock.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/manager/manager_order_review_screen.dart';
import 'package:manna_field_sales/screens/manager/manager_ui.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/sync_all_button.dart';

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

  String get label {
    final range = '${shortDate(from)} – ${shortDate(to)}';
    switch (offset) {
      case 0:
        return 'This week · $range';
      case -1:
        return 'Last week · $range';
      default:
        return range;
    }
  }
}

const Map<OrderBucket, String> _bucketLabel = {
  OrderBucket.toApprove: 'To approve',
  OrderBucket.approved: 'Approved',
  OrderBucket.rejected: 'Rejected',
  OrderBucket.cancelled: 'Cancelled in SAP',
};

/// Which filter an order belongs under, asking each kind the right field.
OrderBucket bucketOf(Map<String, dynamic> r) {
  // A Sales Order is asked its status, never its rate flag: a rep's edit
  // after approval sends it back to "To approve" with its rates still stamped.
  final isLead = r['is_lead'] == true;
  return orderBucket(
      approved: isLead ? orderSignedOff(r, isLead: true) : orderApproved(r),
      poStatus: r['custom_po_status'],
      sap: SapOrderState.fromOrder(r));
}

/// The pill on an order card: its words and how worried to look.
(String, Tone) orderPill(Map<String, dynamic> r) {
  final b = bucketOf(r);
  final label = orderApprovalLabel(r['custom_po_status'],
      SapOrderState.fromOrder(r));
  return switch (b) {
    OrderBucket.cancelled => ('Cancelled in SAP', Tone.bad),
    OrderBucket.rejected => ('Rejected', Tone.bad),
    OrderBucket.approved => ('Approved', Tone.good),
    OrderBucket.toApprove => (label, Tone.warn),
  };
}

/// Opens an order for review; true when a decision was made.
Future<bool> openOrderReview(BuildContext context, Map<String, dynamic> r) async {
  final decided = await Navigator.push<bool>(
    context,
    MaterialPageRoute(
        builder: (_) => ManagerOrderReviewScreen(
              orderName: '${r['name']}',
              isLead: r['is_lead'] == true,
            )),
  );
  return decided == true;
}

/// One order in a list: party, amount, status, and where it has got to.
class OrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  final VoidCallback onTap;
  final Widget? trailingNote;
  const OrderCard(
      {super.key, required this.order, required this.onTap, this.trailingNote});

  @override
  Widget build(BuildContext context) {
    final r = order;
    final (pill, tone) = orderPill(r);
    final approved = bucketOf(r) == OrderBucket.approved;
    final sapNo = textOf(r['custom_sap_sales_order']);
    final production = orderProgress(
        SapOrderState.fromOrder(r), r['custom_production_status']);
    final finish = textOf(r['custom_production_finish_date']);
    return Panel(
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Text(textOf(r['customer']).isEmpty
                    ? '${r['name']}'
                    : textOf(r['customer']),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          Text(money(numOf(r['grand_total'])),
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 4),
        Text(
            [
              if (sapNo.isNotEmpty) 'SAP $sapNo' else '${r['name']}',
              textOf(r['custom_sales_person']),
              shortDate(r['transaction_date']),
            ].where((s) => s.isNotEmpty).join(' · '),
            style: const TextStyle(fontSize: 12, color: kMuted)),
        const SizedBox(height: 8),
        Row(children: [
          StatusPill(pill, tone: tone),
          if (r['is_lead'] == true) ...[
            const SizedBox(width: 6),
            const StatusPill('Lead', tone: Tone.info),
          ],
          const Spacer(),
          if (trailingNote != null) trailingNote!,
        ]),
        if (approved && r['is_lead'] != true) ...[
          const SizedBox(height: 8),
          Row(children: [
            Icon(
                Api.isOrderComplete(r)
                    ? Icons.check_circle
                    : Icons.precision_manufacturing_outlined,
                size: 15,
                color: Api.isOrderComplete(r) ? toneColor(Tone.good) : kMuted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                  Api.isOrderComplete(r)
                      ? 'Dispatched'
                      : [
                          textOf(production).isEmpty
                              ? 'Not started'
                              : production,
                          if (finish.isNotEmpty) 'finish ${shortDate(finish)}',
                        ].join(' · '),
                  style: const TextStyle(fontSize: 12, color: kMuted)),
            ),
          ]),
        ],
      ]),
    );
  }
}

class TeamOrdersView extends StatefulWidget {
  const TeamOrdersView({super.key});
  @override
  State<TeamOrdersView> createState() => _TeamOrdersViewState();
}

class _TeamOrdersViewState extends State<TeamOrdersView> {
  late final List<_Week> _weeks = _buildWeeks();
  late _Week _week = _weeks.first;
  OrderBucket _bucket = OrderBucket.toApprove;
  String? _rep;
  String _query = '';
  late Future<List<Map<String, dynamic>>> _future = _load();

  @override
  void initState() {
    super.initState();
    SapSyncAll.epoch.addListener(_reload);
  }

  @override
  void dispose() {
    SapSyncAll.epoch.removeListener(_reload);
    super.dispose();
  }

  /// This week and the twelve before it, on the server's clock so a phone
  /// with a wrong date does not offer the wrong weeks.
  List<_Week> _buildWeeks() {
    final now = ServerClock.I.now();
    final today = DateTime(now.year, now.month, now.day);
    final monday = today.subtract(Duration(days: today.weekday - 1));
    return [
      for (var i = 0; i <= 12; i++)
        _Week(monday.subtract(Duration(days: 7 * i)),
            monday.subtract(Duration(days: 7 * i - 6)), -i)
    ];
  }

  Future<List<Map<String, dynamic>>> _load() =>
      Api.getTeamOrders(from: _week.from, to: _week.to);

  void _reload() {
    if (mounted) setState(() => _future = _load());
  }

  Future<void> _open(Map<String, dynamic> r) async {
    if (await openOrderReview(context, r)) _reload();
  }

  bool _matches(Map<String, dynamic> r) {
    if (_rep != null && textOf(r['custom_sales_person']) != _rep) return false;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [r['name'], r['customer'], r['custom_sales_person'],
            r['custom_sap_sales_order']]
        .any((v) => textOf(v).toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snap) {
        final loading = snap.connectionState != ConnectionState.done;
        final all = snap.data ?? const <Map<String, dynamic>>[];
        final scoped = all.where(_matches).toList();
        final counts = {
          for (final b in OrderBucket.values)
            b: scoped.where((r) => bucketOf(r) == b).length
        };
        final rows = scoped.where((r) => bucketOf(r) == _bucket).toList();

        return RefreshIndicator(
          onRefresh: () async {
            _reload();
            await _future;
          },
          child: CustomScrollView(slivers: [
            SliverToBoxAdapter(child: _filters(counts)),
            if (loading)
              const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()))
            else if (snap.hasError)
              SliverFillRemaining(
                  hasScrollBody: false,
                  child: ErrorState(error: snap.error, onRetry: _reload))
            else if (rows.isEmpty)
              SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                      icon: _bucket == OrderBucket.toApprove
                          ? Icons.task_alt
                          : Icons.receipt_long_outlined,
                      text: _bucket == OrderBucket.toApprove
                          ? 'Nothing to approve this week.'
                          : 'No ${_bucketLabel[_bucket]!.toLowerCase()} orders this week.'))
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                sliver: SliverList.builder(
                  itemCount: rows.length,
                  itemBuilder: (_, i) =>
                      OrderCard(order: rows[i], onTap: () => _open(rows[i])),
                ),
              ),
          ]),
        );
      },
    );
  }

  Widget _filters(Map<OrderBucket, int> counts) {
    final reps = [...Session.I.teamReps]..sort();
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: _dropdown<_Week>(
              value: _week,
              items: {for (final w in _weeks) w: w.label},
              onChanged: (w) {
                _week = w;
                _reload();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _dropdown<String?>(
              value: _rep,
              items: {null: 'All reps', for (final r in reps) r: r},
              onChanged: (r) => setState(() => _rep = r),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        TextField(
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search order, party or rep',
            prefixIcon: const Icon(Icons.search, size: 20),
            filled: true,
            fillColor: const Color(0xFFF3F4F6),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none),
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final b in OrderBucket.values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text('${_bucketLabel[b]}  ${counts[b] ?? 0}'),
                  selected: _bucket == b,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _bucket = b),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _dropdown<T>(
          {required T value,
          required Map<T, String> items,
          required ValueChanged<T> onChanged}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
            border: Border.all(color: kLine),
            borderRadius: BorderRadius.circular(12)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isExpanded: true,
            style: const TextStyle(fontSize: 13, color: Colors.black87),
            items: [
              for (final e in items.entries)
                DropdownMenuItem<T>(
                    value: e.key,
                    child: Text(e.value, overflow: TextOverflow.ellipsis))
            ],
            onChanged: (v) => onChanged(v as T),
          ),
        ),
      );
}
