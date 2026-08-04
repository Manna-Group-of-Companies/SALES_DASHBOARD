// The minimum-stock list, worst-moving first.
//
// The list is not a list of old stock. It is what management has decided must
// always be on the shelf, because it sells fast or takes a long time to make.
// Most of what is on it is exactly what a rep should be pushing.
//
// The failure mode is quiet. Market trends move; a product that earned its
// place two years ago stops selling, but the rule that put it on the list keeps
// stock sitting against its name, and nobody notices until it is written off.
// So the list is sorted by how long it has been since anything sold, and the
// ones drifting towards dead stock are highlighted.
//
// Batches matter underneath — a pool of ten with two sold and two restocked is
// eight old and two new, and the old eight should leave first — so each item
// breaks down by the date its stock came in.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/offline_banner.dart';

class AgingStockScreen extends StatefulWidget {
  const AgingStockScreen({super.key});
  @override
  State<AgingStockScreen> createState() => _AgingStockScreenState();
}

class _AgingStockScreenState extends State<AgingStockScreen> {
  late Future<List<MinStockDetail>> _load;
  String _q = '';

  /// Off by default: the point of the screen is the whole list, with the
  /// problems floated to the top. The filter is for when a rep is specifically
  /// hunting things to clear.
  bool _onlyProblems = false;

  @override
  void initState() {
    super.initState();
    _load = Api.getMinimumStockDetailed();
  }

  Future<void> _refresh() async {
    setState(() => _load = Api.getMinimumStockDetailed());
    await _load;
  }

  List<MinStockDetail> _filter(List<MinStockDetail> all) {
    final qq = _q.trim().toLowerCase();
    return all.where((d) {
      if (_onlyProblems && !d.stock.isDeadStockRisk && !d.stock.isSlowMoving) {
        return false;
      }
      if (qq.isEmpty) return true;
      return '${d.name} ${d.stock.itemCode}'.toLowerCase().contains(qq);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Minimum Stock')),
      body: FutureBuilder<List<MinStockDetail>>(
        future: _load,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _message(humanError(snap.error));
          }
          final all = snap.data ?? [];
          if (all.isEmpty) {
            return _message(
                'Nothing is on the minimum stock list yet, or none of it is '
                'sold by your unit.');
          }
          final atRisk = all.where((d) => d.stock.isDeadStockRisk).length;
          final slowing = all.where((d) => d.stock.isSlowMoving).length;
          final shown = _filter(all);

          return Column(children: [
            // Matters more here than anywhere else: these figures are what a
            // rep decides whether to promise stock on, and offline they cannot
            // see bookings other reps have made since. Nothing can actually be
            // taken until the order is sent, but the rep should know that the
            // numbers in front of them are a snapshot.
            OfflineBanner.forKeys(CacheKeys.minimumStock),
            _header(all.length, atRisk, slowing),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: shown.isEmpty
                    ? _message('Nothing matches.')
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 16),
                        itemCount: shown.length,
                        itemBuilder: (_, i) => _StockCard(detail: shown[i]),
                      ),
              ),
            ),
          ]);
        },
      ),
    );
  }

  Widget _header(int total, int atRisk, int slowing) => Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(children: [
          Row(children: [
            _Stat(label: 'On list', value: '$total', colour: Colors.black87),
            _Stat(
                label: 'Slowing',
                value: '$slowing',
                colour: Colors.orange.shade800),
            _Stat(
                label: 'Dead stock risk',
                value: '$atRisk',
                colour: Colors.red.shade700),
          ]),
          const SizedBox(height: 10),
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search minimum stock…',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
          if (atRisk + slowing > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: SwitchListTile(
                value: _onlyProblems,
                onChanged: (v) => setState(() => _onlyProblems = v),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Only show what needs clearing',
                    style: TextStyle(fontSize: 13)),
              ),
            ),
        ]),
      );

  Widget _message(String m) => ListView(
        padding: const EdgeInsets.all(32),
        children: [Center(child: Text(m, textAlign: TextAlign.center))],
      );
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color colour;
  const _Stat({required this.label, required this.value, required this.colour});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Text(value,
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, color: colour)),
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ]),
      );
}

class _StockCard extends StatelessWidget {
  final MinStockDetail detail;
  const _StockCard({required this.detail});

  MinStock get s => detail.stock;

  @override
  Widget build(BuildContext context) {
    // The whole point of the screen is that a problem should be visible before
    // anything is read, so a flagged card is tinted rather than just badged.
    final tint = s.isDeadStockRisk
        ? const Color(0xFFFFF1F0)
        : (s.isSlowMoving ? const Color(0xFFFFF8EC) : Colors.white);
    return Card(
      color: tint,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => showMinStockDetail(context, detail),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Text(detail.name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              MovementBadge(stock: s),
            ]),
            const SizedBox(height: 4),
            Text(specLine(detail),
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.inventory_2_outlined,
                  size: 14,
                  color: s.availableQty <= 0 ? Colors.red : Colors.green),
              const SizedBox(width: 4),
              Text('${detail.availabilityLabel} available',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500)),
              if (s.minimumLooseBelts > 0)
                Text('  ·  ${s.availableLooseBelts} belts',
                    style: const TextStyle(fontSize: 12)),
            ]),
            const SizedBox(height: 2),
            Row(children: [
              Icon(Icons.schedule,
                  size: 13,
                  color: s.isDeadStockRisk
                      ? Colors.red.shade700
                      : Colors.black45),
              const SizedBox(width: 4),
              Expanded(
                child: Text(lastSoldLabel(s),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: s.isDeadStockRisk
                            ? FontWeight.w600
                            : FontWeight.normal,
                        color: s.isDeadStockRisk
                            ? Colors.red.shade700
                            : Colors.black54)),
              ),
              const Icon(Icons.chevron_right, size: 18, color: Colors.black38),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// The fixed facts about the product, so a rep can quote it without leaving
/// the screen.
String specLine(MinStockDetail d) {
  final p = d.product;
  final bits = <String>[p.category.shortLabel];
  switch (p.category) {
    case ProductCategory.pctr:
      if (p.weightPerRoll > 0) {
        bits.add('${trimQty(p.weightPerRoll)} kg/roll');
      }
      if (p.weightPerBelt > 0) {
        bits.add('${trimQty(p.weightPerBelt)} kg/belt');
      }
      if (p.beltsPerRoll > 0) bits.add('${p.beltsPerRoll} belts/roll');
      break;
    case ProductCategory.ctr:
      if (p.weightPerRoll > 0) {
        bits.add('${trimQty(p.weightPerRoll)} kg/roll exact');
      }
      break;
    case ProductCategory.bondingGum:
      bits.add('1 box = $kBgRollsPerBox rolls');
      break;
    case ProductCategory.vulcanizingSolution:
      if (p.packLitres > 0) bits.add('${trimQty(p.packLitres)} L can');
      break;
    case ProductCategory.other:
      if (p.uom.isNotEmpty) bits.add(p.uom);
      break;
  }
  return bits.join('  ·  ');
}

/// Everything known about one pooled product, for the rep who tapped it.
Future<void> showMinStockDetail(
    BuildContext context, MinStockDetail d) async {
  final s = d.stock;
  final p = d.product;
  final unit = p.category.stockUnit;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (_, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text(p.name,
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Row(children: [
            MovementBadge(stock: s),
            const SizedBox(width: 8),
            Expanded(
              child: Text(p.category.label,
                  style:
                      const TextStyle(fontSize: 12, color: Colors.black54)),
            ),
          ]),
          const Divider(height: 24),
          _kv('Item code', s.itemCode),
          _kv('Stock unit', p.uom.isEmpty ? '—' : p.uom),
          if (p.category == ProductCategory.pctr) ...[
            _kv('Weight per roll',
                p.weightPerRoll > 0 ? '${trimQty(p.weightPerRoll)} kg' : 'not set'),
            _kv('Weight per belt',
                p.weightPerBelt > 0 ? '${trimQty(p.weightPerBelt)} kg' : 'not set'),
            _kv('Belts per roll',
                p.beltsPerRoll > 0 ? '${p.beltsPerRoll}' : 'not set'),
          ],
          if (p.category == ProductCategory.ctr)
            _kv('Weight per roll',
                p.weightPerRoll > 0 ? '${trimQty(p.weightPerRoll)} kg' : 'not set'),
          if (p.category == ProductCategory.vulcanizingSolution)
            _kv('Can size',
                p.packLitres > 0 ? '${trimQty(p.packLitres)} L' : 'not set'),
          const Divider(height: 24),
          const Text('Stock details',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          // The undispatched total is deliberately not shown. What is booked is
          // on the line below, and a rep who wants some of it goes to the sales
          // manager either way — the extra figure only invited the arithmetic.
          _kv('Minimum stock',
              s.describe(s.minimumQty, s.minimumLooseBelts, unit)),
          _kv('Booked by reps',
              s.bookings.isEmpty
                  ? 'Nothing booked'
                  : s.describe(s.reservedQty, s.reservedLooseBelts, unit)),
          // Who is holding it, so a rep chasing the last few knows who to ring
          // rather than just being told the number is gone.
          for (final b in s.bookings)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text('· ${b.salesPerson}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.black87)),
                    ),
                    Text(s.describe(b.qty, b.looseBelts, unit),
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                  ]),
            ),
          _kv('Available to sell',
              s.describe(s.availableQty, s.availableLooseBelts, unit)),
          // What a rep does about a booking that is in their way. Only shown
          // when something is actually booked.
          if (s.reservedQty > 0 || s.reservedLooseBelts > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Booked stock has not shipped yet. Ask your manager if you '
                'need some of it allotted to you.',
                style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade700),
              ),
            ),
          _kv('Last sold', lastSoldLabel(s)),
          if (p.isMisconfigured)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(8)),
                child: Text(
                    'Packing details are missing on this product, so it cannot '
                    'be priced yet. Ask the office to complete the item master.',
                    style: TextStyle(
                        fontSize: 12, color: Colors.orange.shade900)),
              ),
            ),
          const Divider(height: 24),
          const Text('Stock by date received',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(batchSummary(s, unit),
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 6),
          if (s.batches.every((b) => b.qty <= 0 && b.looseBelts <= 0))
            const Text('No dated batches recorded.',
                style: TextStyle(fontSize: 12, color: Colors.black45))
          else
            for (final b in s.batches)
              if (b.qty > 0 || b.looseBelts > 0)
                AgedBatchTile(batch: b, unit: unit),
        ],
      ),
    ),
  );
}

Widget _kv(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: const TextStyle(color: Colors.black54, fontSize: 13)),
            const SizedBox(width: 12),
            Flexible(
                child: Text(v,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13))),
          ]),
    );

/// How an item is moving, in one word. Deliberately blunt — a rep glancing at
/// this list is deciding what to push, not reading a report.
class MovementBadge extends StatelessWidget {
  final MinStock stock;
  const MovementBadge({super.key, required this.stock});

  @override
  Widget build(BuildContext context) {
    late final String text;
    late final Color colour;
    if (stock.isDeadStockRisk) {
      text = 'DEAD STOCK RISK';
      colour = Colors.red.shade700;
    } else if (stock.isSlowMoving) {
      text = 'SLOWING';
      colour = Colors.orange.shade800;
    } else {
      text = 'MOVING';
      colour = Colors.green.shade700;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4)),
      child: Text(text,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.bold, color: colour)),
    );
  }
}

/// "Not sold in 143 days" — the number this screen exists to surface.
String lastSoldLabel(MinStock s) {
  final d = s.daysSinceSold;
  if (d < 0) return 'No sale recorded since it went on the list';
  if (d == 0) return 'Sold today';
  if (d == 1) return 'Sold yesterday';
  if (d < kSlowMovingDays) return 'Last sold $d days ago';
  return 'Not sold in $d days';
}

/// The one-line version a rep glances at before deciding what to offer —
/// "6 rolls sitting 209 days, 2 restocked 13 days ago".
String batchSummary(MinStock s, [String unit = 'rolls']) {
  final open = s.batches.where((b) => b.qty > 0 || b.looseBelts > 0).toList();
  if (open.isEmpty) return 'Nothing left in stock';
  final oldest = open.first;
  final head = '${trimQty(oldest.qty)} $unit sitting ${oldest.ageDays} days';
  if (open.length == 1) return head;
  final rest = open.skip(1).fold<double>(0, (t, b) => t + b.qty);
  return '$head, ${trimQty(rest)} restocked '
      '${open[1].ageDays} day${open[1].ageDays == 1 ? '' : 's'} ago';
}

class AgedBatchTile extends StatelessWidget {
  final StockBatch batch;

  /// What this product is counted in — rolls, kg or cans. Without it the row
  /// can only print a bare number, and a bare number next to another bare
  /// number is what made "4/14" unreadable.
  final String unit;

  const AgedBatchTile({
    super.key,
    required this.batch,
    this.unit = 'rolls',
  });

  bool get _isOld => batch.ageDays >= kSlowMovingDays;

  @override
  Widget build(BuildContext context) {
    final colour = _isOld ? Colors.orange.shade800 : Colors.black54;
    final belts = batch.looseBelts > 0
        ? ' + ${batch.looseBelts} belt${batch.looseBelts == 1 ? '' : 's'}'
        : '';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(_isOld ? Icons.hourglass_bottom : Icons.inventory_2_outlined,
          color: colour, size: 20),
      // Only what is actually left, in its own unit. The old "4/14" invited the
      // question of what 14 was.
      title: Text('${trimQty(batch.qty)} $unit$belts left',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      // Both lines show on every batch, however new — a rep should be able to
      // read the age off any of them without working out which ones are old
      // enough to have earned a note.
      subtitle: Text('In stock since ${batch.batchDate}  ·  '
          '${batch.ageDays} day${batch.ageDays == 1 ? '' : 's'} on the shelf',
          style: TextStyle(fontSize: 11, color: colour)),
    );
  }
}

// There is deliberately no batch picker here.
//
// An earlier version let a rep choose an older batch and asked them to confirm
// the substitution with the customer. That was built on a wrong assumption:
// the oldest stock of a product always goes out first anyway, and the shelf
// life is long enough that age is not a quality question a customer needs to
// agree to. Nothing about it is the rep's decision.
//
// What the ages are *for* is attention. A product whose stock has been sitting
// is a product to push harder, which is what this screen ranks and highlights.
