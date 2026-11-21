// Adding products to an order copied from a previous one (20 Nov 2026, the
// user's request): the copied order shows only what was copied, and an
// "Add product" button opens this page to search for and pick more.
//
// The rows are the order screen's own product rows, built by it
// ([rowBuilder]) and working on the same order lines — so the price, the
// stock line, the stepper and every check are exactly those of the order,
// and there is no second copy of any of it here. "Done" keeps what was
// picked and goes back to the order; the back arrow puts everything picked
// on this page back to nothing, so leaving without Done changes nothing.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/product_search.dart';
import 'package:manna_field_sales/models/product_category.dart';

class ProductPickerScreen extends StatefulWidget {
  /// The products that can be added: sellable, and not already on the order.
  final List<OrderLine> candidates;

  /// Builds the order screen's row for [line]; [onChanged] is called when its
  /// quantity changes.
  final Widget Function(OrderLine line, VoidCallback onChanged) rowBuilder;

  const ProductPickerScreen({
    super.key,
    required this.candidates,
    required this.rowBuilder,
  });

  @override
  State<ProductPickerScreen> createState() => _ProductPickerScreenState();
}

class _ProductPickerScreenState extends State<ProductPickerScreen> {
  String _q = '';

  List<OrderLine> get _picked =>
      widget.candidates.where((l) => !l.isEmpty).toList();

  /// Picked lines first, so what has been chosen stays in sight while the
  /// rep keeps searching.
  List<OrderLine> get _shown {
    final found = bestSearchMatches(_q, widget.candidates,
        name: (l) => l.product.name, code: (l) => l.product.code);
    return [
      ...found.where((l) => !l.isEmpty),
      ...found.where((l) => l.isEmpty),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final picked = _picked;
    final shown = _shown;
    final total = picked.fold<double>(0, (t, l) => t + l.amount);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: primary,
        titleTextStyle: const TextStyle(
            fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white),
        title: const Text('Add products'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: TextField(
            autofocus: true,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, size: 26),
              hintText: 'Search products… (bp 130, pl 34 12)',
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFECECEC))),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: primary, width: 1.5)),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? const Center(child: Text('No matching products.'))
              : ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: shown.length,
                  itemBuilder: (_, i) => KeyedSubtree(
                    key: ValueKey(shown[i].product.code),
                    child: widget.rowBuilder(
                        shown[i], () => setState(() {})),
                  ),
                ),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Color(0xFFECECEC))),
          ),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                        '${picked.length} product'
                        '${picked.length == 1 ? '' : 's'} selected',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                    if (total > 0)
                      Text('Rs ${total.toStringAsFixed(2)}',
                          style: const TextStyle(
                              fontSize: 13, color: Colors.black54)),
                  ]),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 50),
                padding: const EdgeInsets.symmetric(horizontal: 26),
              ),
              onPressed: picked.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Done',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      ),
    );
  }
}
