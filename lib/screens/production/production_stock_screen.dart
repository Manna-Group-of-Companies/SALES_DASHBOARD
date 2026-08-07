// The minimum-stock pool, as the person who has to refill it sees it.
//
// The rep's version of this list answers "what should I push". This one answers
// a different question — "what do I have to make" — so it is ordered by how
// badly each pool needs a run rather than by how long the stock has sat.
//
// Two things bring an item to the top, and they are not the same alarm:
//
//   - the shelf has fallen below the level management set, so a run is owed;
//   - everything on the shelf is already booked, so the next rep to ask gets
//     turned away — which happens at exactly the minimum, before the shelf
//     looks short at all.
//
// The production order itself is raised in SAP. Nothing here writes one; this
// screen exists so the manager knows which ones to raise, and sees the pool
// move as reps book against it.
//
// Booking attribution is deliberately absent. Production is never told which
// customer an order is for, and a booking names its Sales Order — so the
// numbers are shown as counts and the orders behind them are not.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/services/api.dart';

enum _Filter { needsRun, fullyBooked, all }

class ProductionStockScreen extends StatefulWidget {
  const ProductionStockScreen({super.key});
  @override
  State<ProductionStockScreen> createState() => _ProductionStockScreenState();
}

class _ProductionStockScreenState extends State<ProductionStockScreen> {
  late Future<List<MinStockDetail>> _fut;
  _Filter _filter = _Filter.needsRun;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => _fut = Api.getMinimumStockDetailed();

  /// Worst first: fully booked *and* short, then fully booked, then short, then
  /// the rest. Within a band, the biggest shortfall leads.
  List<MinStockDetail> _ordered(List<MinStockDetail> rows) {
    final out = [...rows];
    out.sort((a, b) {
      final u = b.stock.productionUrgency.compareTo(a.stock.productionUrgency);
      if (u != 0) return u;
      final s = b.stock.shortfallQty.compareTo(a.stock.shortfallQty);
      if (s != 0) return s;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  bool _matches(MinStockDetail d) {
    if (_q.isNotEmpty && !d.name.toLowerCase().contains(_q.toLowerCase())) {
      return false;
    }
    return switch (_filter) {
      _Filter.needsRun => d.stock.belowMinimum || d.stock.fullyBooked,
      _Filter.fullyBooked => d.stock.fullyBooked,
      _Filter.all => true,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Minimum Stock'), actions: [
        IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(_reload)),
      ]),
      body: FutureBuilder<List<MinStockDetail>>(
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
          final all = _ordered(snap.data ?? const []);
          final short = all.where((d) => d.stock.belowMinimum).length;
          final booked = all.where((d) => d.stock.fullyBooked).length;
          final rows = all.where(_matches).toList();

          return Column(children: [
            _summary(all.length, short, booked),
            _filters(short, booked, all.length),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search product…',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _filter == _Filter.needsRun
                              ? 'Every pool is at or above its minimum, and '
                                  'nothing is fully booked.'
                              : 'Nothing matches.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.black54, height: 1.5),
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: () async {
                        setState(_reload);
                        await _fut;
                      },
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                        itemCount: rows.length,
                        itemBuilder: (_, i) => _card(rows[i]),
                      ),
                    ),
            ),
          ]);
        },
      ),
    );
  }

  Widget _summary(int total, int short, int booked) => Container(
        width: double.infinity,
        color: (short > 0 || booked > 0)
            ? const Color(0xFFFFF3E0)
            : const Color(0xFFE8F5E9),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(children: [
          Icon(
              (short > 0 || booked > 0)
                  ? Icons.warning_amber_rounded
                  : Icons.check_circle_outline,
              color: (short > 0 || booked > 0)
                  ? Colors.orange.shade800
                  : Colors.green.shade700),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      (short > 0 || booked > 0)
                          ? '$short below minimum · $booked fully booked'
                          : 'All $total pools are healthy',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  const Text(
                      'Raise the production run in SAP. This list only tells '
                      'you which, and shows the pool moving as reps book.',
                      style: TextStyle(fontSize: 11, color: Colors.black54)),
                ]),
          ),
        ]),
      );

  Widget _filters(int short, int booked, int total) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          for (final f in _Filter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
                label: Text(switch (f) {
                  _Filter.needsRun => 'Needs a run',
                  _Filter.fullyBooked => 'Fully booked ($booked)',
                  _Filter.all => 'All ($total)',
                }),
              ),
            ),
        ]),
      );

  Widget _card(MinStockDetail d) {
    final s = d.stock;
    final unit = d.category.stockUnit;
    final urgent = s.fullyBooked;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(d.name,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600)),
            ),
            if (s.belowMinimum)
              _badge('MAKE ${trimQty(s.shortfallQty)} $unit',
                  const Color(0xFFB3261E)),
          ]),
          const SizedBox(height: 2),
          Text(d.category.label,
              style: const TextStyle(fontSize: 11, color: Colors.black45)),
          const Divider(height: 16),

          // The four numbers, in the order the question is asked: what should
          // be here, what is here, what is spoken for, what is left.
          _row('Minimum to hold', '${trimQty(s.minimumQty)} $unit'),
          _row('On the shelf', '${trimQty(s.shelfQty)} $unit',
              bold: true,
              colour: s.belowMinimum ? const Color(0xFFB3261E) : null),
          _row('Booked by reps', '${trimQty(s.reservedQty)} $unit'
              '${s.reservedLooseBelts > 0 ? ' + ${s.reservedLooseBelts} belts' : ''}'),
          _row('Left to sell', '${trimQty(s.availableQty)} $unit'
              '${s.availableLooseBelts > 0 ? ' + ${s.availableLooseBelts} belts' : ''}',
              bold: true,
              colour: urgent ? const Color(0xFFB3261E) : null),

          if (urgent) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: const Color(0xFFFFF1F0),
                  borderRadius: BorderRadius.circular(6)),
              child: Row(children: [
                const Icon(Icons.block, size: 15, color: Color(0xFFB3261E)),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                      'Nothing left to promise — the next rep to ask will be '
                      'refused.',
                      style: TextStyle(fontSize: 11, color: Color(0xFFB3261E))),
                ),
              ]),
            ),
          ],

          // Movement. Oldest stock first tells the manager whether a pool is
          // turning over or quietly sitting.
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.history, size: 14, color: Colors.black45),
            const SizedBox(width: 6),
            Expanded(
              child: Text(_movementLabel(s),
                  style:
                      const TextStyle(fontSize: 11, color: Colors.black54)),
            ),
          ]),
        ]),
      ),
    );
  }

  /// How this pool is moving, in one line.
  String _movementLabel(MinStock s) {
    final parts = <String>[];
    final days = s.daysSinceSold;
    parts.add(days < 0
        ? 'never sold'
        : days == 0
            ? 'sold today'
            : 'last sold $days ${days == 1 ? 'day' : 'days'} ago');
    final oldest = s.oldestOpenBatch;
    if (oldest != null) {
      parts.add('oldest stock ${oldest.ageDays} days '
          '(since ${oldest.batchDate})');
    }
    if (s.batches.isEmpty) parts.add('no batch record');
    return parts.join('  ·  ');
  }

  Widget _badge(String text, Color colour) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4)),
        child: Text(text,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.bold, color: colour)),
      );

  Widget _row(String k, String v, {bool bold = false, Color? colour}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k, style: const TextStyle(fontSize: 12)),
          Text(v,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: bold ? FontWeight.bold : FontWeight.w600,
                  color: colour)),
        ]),
      );
}
