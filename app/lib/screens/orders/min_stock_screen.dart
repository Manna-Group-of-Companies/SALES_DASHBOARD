// The minimum-stock list, as a rep needs to read it: what is on the shelf.
//
// This screen used to be the aging list. It sorted by how long it had been
// since anything sold, highlighted items drifting towards dead stock, and broke
// every pool down into the dated batches it was made up of. All of that was
// removed on 21 August 2026 — the business does not want the floor or the field
// making decisions about stock age, and a rep hunting "things to clear" was
// answering a question nobody had asked them.
//
// **The dated batches still exist**, in ERPNext and in the model: `availableQty`
// is summed from them, so they are the live record of what is on the shelf. They
// are simply never shown. Nothing here should reintroduce a date, an age, or a
// batch breakdown.
//
// **The minimum held back is not shown either.** That figure is what management
// has decided to keep against an item's name, and it is theirs — a rep quoting
// it to a customer describes how the company runs its shelf rather than what
// they can sell. Reps get the available number and nothing else. The production
// and stock screens still show it, because deciding it is their job.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/offline_banner.dart';

class MinimumStockScreen extends StatefulWidget {
  const MinimumStockScreen({super.key});
  @override
  State<MinimumStockScreen> createState() => _MinimumStockScreenState();
}

class _MinimumStockScreenState extends State<MinimumStockScreen> {
  late Future<List<MinStockDetail>> _load;
  String _q = '';

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
    if (qq.isEmpty) return all;
    return all
        .where((d) => '${d.name} ${d.stock.itemCode}'.toLowerCase().contains(qq))
        .toList();
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
          if (snap.hasError) return _message(humanError(snap.error));

          // Items with no roll weight are left off — see shownAsRollsAndBelts.
          final all = shownAsRollsAndBelts(snap.data ?? const []);
          if (all.isEmpty) {
            return _message(
                'Nothing is on the stock list yet, or none of it is '
                'sold by your unit.');
          }
          final shown = _filter(all);

          return Column(children: [
            // Matters more here than anywhere else: these figures are what a
            // rep decides whether to promise stock on, and offline they cannot
            // see bookings other reps have made since. Nothing can actually be
            // taken until the order is sent, but the rep should know that the
            // numbers in front of them are a snapshot.
            OfflineBanner.forKeys(CacheKeys.minimumStock),
            _search(),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: shown.isEmpty
                    ? _message('Nothing matches.')
                    : ListView.separated(
                        padding: const EdgeInsets.only(bottom: 16),
                        itemCount: shown.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) => _StockRow(detail: shown[i]),
                      ),
              ),
            ),
          ]);
        },
      ),
    );
  }

  Widget _search() => Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Search minimum stock…',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => _q = v),
        ),
      );

  Widget _message(String text) => Center(
      child: Padding(padding: const EdgeInsets.all(24), child: Text(text)));
}

/// One item and what is free to sell of it. Nothing else belongs on this row.
class _StockRow extends StatelessWidget {
  final MinStockDetail detail;
  const _StockRow({required this.detail});

  @override
  Widget build(BuildContext context) {
    final s = detail.stock;
    final unit = detail.category.stockUnit;
    final belts = s.availableLooseBelts;

    // Only items with both weights reach here — the screen drops the rest, so
    // every row has a real roll count and an empty one means "none left".

    // Empty is worth colouring because it changes what the rep can promise.
    // "Below the minimum" is deliberately not a state here any more — the rep
    // is not shown the minimum, so a colour keyed to it would be unreadable.
    final empty = s.availableQty <= 0 && belts <= 0;

    return ListTile(
      leading: Icon(Icons.inventory_2_outlined,
          color: empty ? Colors.red : Colors.green),
      title: Text(detail.name,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text(
        empty
            ? 'None left'
            // Belts are only mentioned when there are some — on CTR, bonding
            // gum and solution the counter is always zero and saying so would
            // be noise.
            : '${trimQty(s.availableQty)} $unit available'
                '${belts > 0 ? '  ·  $belts loose belt${belts == 1 ? '' : 's'}' : ''}',
        style: TextStyle(
            fontSize: 12,
            color: empty ? Colors.red : Colors.black87,
            fontWeight: FontWeight.w500),
      ),
    );
  }
}
