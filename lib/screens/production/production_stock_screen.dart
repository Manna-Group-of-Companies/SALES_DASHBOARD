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
import 'package:manna_field_sales/core/item_naming.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/services/api.dart';

/// Which slice of the pool list to show.
///
/// [belowMinimum] and [fullyBooked] are separate on purpose — they are the two
/// alarms, and they do not fire together. A pool sitting exactly at its minimum
/// can be entirely spoken for, and a pool well short of its minimum can still
/// have plenty left to sell. [needsRun] is the union, for a manager who wants
/// one list of everything that wants attention.
enum _Filter { belowMinimum, fullyBooked, needsRun, all }

class ProductionStockScreen extends StatefulWidget {
  const ProductionStockScreen({super.key});
  @override
  State<ProductionStockScreen> createState() => _ProductionStockScreenState();
}

class _ProductionStockScreenState extends State<ProductionStockScreen> {
  late Future<List<MinStockDetail>> _fut;

  /// Opens on what is short, because that is the list a production run is
  /// planned from.
  _Filter _filter = _Filter.belowMinimum;
  String _q = '';

  /// Null means "any". Both are read off the item name.
  String? _quality;
  String? _pattern;
  bool _busy = false;

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
    // Quality and pattern are read out of the item name — see core/item_naming.
    // An item whose name does not parse keeps its place under "any", and is
    // only hidden when a specific grade or pattern is asked for.
    final parts = parseItemName(d.name);
    if (_quality != null && parts.quality != _quality) return false;
    if (_pattern != null && parts.pattern != _pattern) return false;
    return switch (_filter) {
      _Filter.belowMinimum => d.stock.belowMinimum,
      _Filter.fullyBooked => d.stock.fullyBooked,
      _Filter.needsRun => d.stock.belowMinimum || d.stock.fullyBooked,
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

          final needsRun = all
              .where((d) => d.stock.belowMinimum || d.stock.fullyBooked)
              .length;

          return Column(children: [
            _summary(all.length, short, booked),
            _filters(short, booked, needsRun, all.length),
            _gradeFilters(all),
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
                          // Says which question came back empty, so an empty
                          // screen reads as an answer rather than as a fault.
                          _q.isNotEmpty
                              ? 'Nothing matches "$_q" in this filter.'
                              : switch (_filter) {
                                  _Filter.belowMinimum =>
                                    'Every pool is at or above its minimum.',
                                  _Filter.fullyBooked =>
                                    'Every pool still has something left to '
                                        'promise.',
                                  _Filter.needsRun =>
                                    'Every pool is at or above its minimum, '
                                        'and nothing is fully booked.',
                                  _Filter.all => 'No minimum stock is set up.',
                                },
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

  Widget _filters(int short, int booked, int needsRun, int total) =>
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          for (final f in _Filter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
                // Counted on every chip, so the manager can see how much each
                // filter is hiding before choosing it.
                label: Text(switch (f) {
                  _Filter.belowMinimum => 'Below minimum ($short)',
                  _Filter.fullyBooked => 'Fully booked ($booked)',
                  _Filter.needsRun => 'Needs a run ($needsRun)',
                  _Filter.all => 'All ($total)',
                }),
              ),
            ),
        ]),
      );

  /// Quality and pattern, built from whatever is actually on the list rather
  /// than from a hard-coded set — new grades and patterns are added to the
  /// catalogue without anybody being told.
  Widget _gradeFilters(List<MinStockDetail> all) {
    final names = all.map((d) => d.name);
    final qualities = qualitiesIn(names);
    final patterns = patternsIn(names);
    // A dropdown offering one choice is not a choice. Hidden until the list
    // actually holds more than one — today every pool is BLACK PEARL.
    final showQuality = qualities.length > 1;
    if (!showQuality && patterns.length <= 1) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(children: [
        if (showQuality) ...[
          Expanded(child: _dropdown('Quality', qualities, _quality,
              (v) => setState(() => _quality = v))),
          const SizedBox(width: 8),
        ],
        Expanded(
            child: _dropdown('Pattern', patterns, _pattern,
                (v) => setState(() => _pattern = v))),
      ]),
    );
  }

  Widget _dropdown(String label, List<String> values, String? selected,
          ValueChanged<String?> onChanged) =>
      DropdownButtonFormField<String?>(
        initialValue: selected,
        isDense: true,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
        items: [
          DropdownMenuItem(value: null, child: Text('Any $label'.toLowerCase())),
          for (final v in values)
            DropdownMenuItem(value: v, child: Text(v)),
        ],
        onChanged: onChanged,
      );

  /// Records what the manager has put on a run in SAP.
  Future<void> _editInProduction(MinStockDetail d) async {
    final s = d.stock;
    final unit = d.category.stockUnit;
    final qtyCtrl =
        TextEditingController(text: s.inProductionQty > 0 ? trimQty(s.inProductionQty) : '');
    final beltsCtrl = TextEditingController(
        text: s.inProductionBelts > 0 ? '${s.inProductionBelts}' : '');
    final takesBelts = s.beltsPerRoll > 0;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('On production'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(d.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
                textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text('Short by ${trimQty(s.shortfallQty)} $unit',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 12),
            TextField(
              controller: qtyCtrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Quantity on the run',
                suffixText: unit,
                border: const OutlineInputBorder(),
              ),
            ),
            if (takesBelts) ...[
              const SizedBox(height: 10),
              TextField(
                controller: beltsCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Loose belts (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 10),
            const Text(
              'Raise the order in SAP first. This only tells the reps that '
              'stock is coming — nothing can be sold against it until it '
              'arrives.\n\nSet it to 0 once the run is in.',
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
              child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final qty = double.tryParse(qtyCtrl.text.trim()) ?? 0;
    final belts = int.tryParse(beltsCtrl.text.trim()) ?? 0;
    if (qty < 0 || belts < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That is not a quantity.')));
      return;
    }

    setState(() => _busy = true);
    try {
      await Api.setInProduction(
          itemCode: d.stock.itemCode, qty: qty, belts: belts);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(qty <= 0 && belts <= 0
              ? 'Cleared — nothing recorded as on production.'
              : 'Recorded. Reps will see this is being made.')));
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

          // What has been put on a run, and what that still leaves. Shown
          // above the movement line because it is the thing the manager is
          // about to act on.
          if (s.hasProductionRun) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: const Color(0xFFE8F0FE),
                  borderRadius: BorderRadius.circular(6)),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.precision_manufacturing_outlined,
                          size: 15, color: Color(0xFF1A56A8)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                            'On production: '
                            '${s.describe(s.inProductionQty, s.inProductionBelts, unit)}',
                            style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1A56A8))),
                      ),
                    ]),
                    if (s.belowMinimum) ...[
                      const SizedBox(height: 3),
                      Text(
                          s.shortfallCovered
                              ? 'Covers the shortfall.'
                              : 'Still ${trimQty(s.uncoveredShortfallQty)} $unit short after this run.',
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF1A56A8))),
                    ],
                    if (s.inProductionUpdatedOn.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                          'Set ${s.inProductionUpdatedOn}'
                          '${s.inProductionUpdatedBy.isEmpty ? '' : ' by ${s.inProductionUpdatedBy}'}',
                          style: const TextStyle(
                              fontSize: 10, color: Colors.black45)),
                    ],
                  ]),
            ),
          ],

          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _editInProduction(d),
              icon: Icon(
                  s.hasProductionRun ? Icons.edit : Icons.add_circle_outline,
                  size: 16),
              label: Text(
                  s.hasProductionRun
                      ? 'Change what is on production'
                      : 'Record what is on production',
                  style: const TextStyle(fontSize: 12)),
            ),
          ),

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
