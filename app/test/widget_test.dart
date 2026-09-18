// What a rep sees on a product row.
//
// The distinctions these cover are the ones most easily lost. An item with no
// stock record at all must read "No minimum stock", which is a different
// statement from an item SAP holds none of; and an item whose weights are not
// set must say so rather than read as empty. Confusing any of the three would
// have reps refusing orders they could have taken.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/screens/orders/product_row.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

Product _pctr() => Product({
      'name': 'PCTR-100',
      'item_name': 'Precured 100mm',
      'item_group': 'Precured',
      'stock_uom': 'Kg',
      'custom_weight_per_roll': 22.0,
      'custom_belts_per_roll': 4,
    });

void main() {
  testWidgets('an item with no stock record at all says so', (tester) async {
    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(product: _pctr()),
      stock: null,
      onChanged: () {},
    )));

    expect(find.text('No minimum stock'), findsOneWidget);
  });

  testWidgets('the shelf reads what SAP says is available', (tester) async {
    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(product: _pctr()),
      stock: const MinStock(itemCode: 'PCTR-100', availableQty: 6),
      onChanged: () {},
    )));

    // Counted in rolls, the item's stock UOM — not the kilograms the rate is
    // quoted against.
    expect(find.textContaining('6 rolls available'), findsOneWidget);
  });

  testWidgets('nothing is said about what other reps have booked',
      (tester) async {
    /*
     * Reversed on 17 September 2026, and the reversal is the point.
     *
     * This used to assert that the row read "4 rolls booked" beside what was
     * available, because that figure explained why the number in front of the
     * rep had moved. It was ERPNext's own reservation counter.
     *
     * SAP owns the booking now, and the figure this row shows is already net
     * of every open order. Printing a "booked" figure beside it would invite
     * the rep to subtract a deduction that has already been made.
     */
    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(product: _pctr()),
      stock: const MinStock(
          itemCode: 'PCTR-100', availableQty: 6, availableLooseBelts: 2),
      onChanged: () {},
    )));

    expect(find.textContaining('booked'), findsNothing);
    expect(find.textContaining('6 rolls + 2 loose belts available'),
        findsOneWidget);
  });

  testWidgets('an item with no weights set says so, and offers no figure',
      (tester) async {
    // SAP holds this item in kilograms and nobody has said what a roll weighs,
    // so there is no honest number to print. "None left" would be a lie about
    // the warehouse; a converted figure would be a guess.
    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(product: _pctr()),
      stock: const MinStock(
          itemCode: 'PCTR-100', availableQty: 0, weightsKnown: false),
      onChanged: () {},
    )));

    expect(find.text('Stock not set up for this item'), findsOneWidget);
    expect(find.textContaining('available'), findsNothing);
    expect(find.textContaining('None left'), findsNothing);
  });

  testWidgets('an empty shelf does not read as an item with no record at all',
      (tester) async {
    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(product: _pctr()),
      stock: const MinStock(itemCode: 'PCTR-100', availableQty: 0),
      onChanged: () {},
    )));

    expect(find.textContaining('None left'), findsOneWidget);
    // "No minimum stock" means there is no record for the item at all, which
    // is a different thing from having one and being sold out.
    expect(find.text('No minimum stock'), findsNothing);
  });

  testWidgets('PCTR offers rolls and loose belts; CTR offers rolls only',
      (tester) async {
    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(product: _pctr()),
      stock: null,
      onChanged: () {},
    )));
    expect(find.text('Rolls'), findsOneWidget);
    expect(find.text('Loose belts'), findsOneWidget);

    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(
          product: Product({
        'name': 'CTR-9',
        'item_name': 'Conventional 9mm',
        'item_group': 'Hot Rubber',
        'stock_uom': 'Roll',
        'custom_weight_per_roll': 30.0,
      })),
      stock: null,
      onChanged: () {},
    )));
    expect(find.text('Rolls'), findsOneWidget);
    expect(find.text('Loose belts'), findsNothing);
  });

  testWidgets('tapping + adds a roll and reports the derived weight',
      (tester) async {
    final line = OrderLine(product: _pctr(), rate: 200);
    var changes = 0;

    await tester.pumpWidget(_host(StatefulBuilder(
      builder: (_, setState) => ProductRow(
        line: line,
        stock: null,
        onChanged: () => setState(() => changes++),
      ),
    )));

    await tester.tap(find.byIcon(Icons.add_circle_outline).first);
    await tester.pump();

    expect(changes, 1);
    expect(line.rolls, 1);
    expect(find.textContaining('22.00 kg (avg)'), findsOneWidget);
    expect(find.text('Rs 4400.00'), findsOneWidget);
  });

  group('ordering more than the pool holds', () {
    // The bug: fifteen rolls against a pool of ten was refused outright, and
    // the rep was told to reduce the order. A customer wanting more than the
    // minimum stock is a customer worth having — the pool covers what it can
    // and the rest is made.
    MinStock shelf({double available = 10}) =>
        MinStock(itemCode: 'PCTR-100', availableQty: available);

    testWidgets('a line inside the pool says nothing about splitting',
        (tester) async {
      final line = OrderLine(product: _pctr(), rate: 100)..rolls = 6;
      await tester.pumpWidget(_host(ProductRow(
          line: line, stock: shelf(available: 10), onChanged: () {})));

      expect(find.textContaining('Split:'), findsNothing);
    });

    testWidgets('a line over the pool is allowed, and the split is shown',
        (tester) async {
      final line = OrderLine(product: _pctr(), rate: 100)..rolls = 15;
      await tester.pumpWidget(_host(ProductRow(
          line: line, stock: shelf(available: 10), onChanged: () {})));

      expect(find.textContaining('Split:'), findsOneWidget);
      expect(find.textContaining('10 rolls from minimum stock'), findsOneWidget);
      expect(find.textContaining('5 rolls made to order'), findsOneWidget);
    });

    testWidgets('an empty pool makes the whole line to order', (tester) async {
      final line = OrderLine(product: _pctr(), rate: 100)..rolls = 4;
      await tester.pumpWidget(_host(ProductRow(
          line: line, stock: shelf(available: 0), onChanged: () {})));

      expect(find.textContaining('whole line will be made to order'),
          findsOneWidget);
    });

    testWidgets('the rep is never told to reduce the quantity', (tester) async {
      // The old wording, and the thing that made this a bug rather than a
      // rough edge.
      final line = OrderLine(product: _pctr(), rate: 100)..rolls = 15;
      await tester.pumpWidget(_host(ProductRow(
          line: line, stock: shelf(available: 10), onChanged: () {})));

      expect(find.textContaining('Reduce the quantity'), findsNothing);
      expect(find.textContaining('left in minimum stock.'), findsNothing);
    });

    // The claim-out-of-a-run test that stood here is gone with the feature it
    // covered. A rep no longer draws on a replenishment run at all: goods are
    // either on the shelf, or produced against their order and dispatched to
    // the customer. Removed 18 Aug 2026 with the rep-side run display.
  });

  group('what is being made', () {
    /*
     * These asserted that a *replenishment run* — the production manager's
     * "20 rolls of this are being made" figure, held on the minimum-stock
     * pool — was never shown to a rep and never counted towards what they
     * could sell. The run was intent rather than stock, and promising against
     * it at a counter was a promise nobody could keep.
     *
     * The pool and its run counter were removed on 17 September 2026 along
     * with the rest of the minimum-stock doctypes, so there is no longer a
     * figure that *could* be shown or wrongly added in. The rule these pinned
     * is now structural, and what is left is the part that can still regress:
     * the row must say nothing about anything being made, and offer no way to
     * claim it.
     *
     * Production against a specific ORDER is a different flow and is still
     * shown, on that order's own lines, with its stage.
     */
    testWidgets('a rep is never told that anything is being made',
        (tester) async {
      await tester.pumpWidget(_host(ProductRow(
        line: OrderLine(product: _pctr()),
        stock: const MinStock(itemCode: 'PCTR-100', availableQty: 6),
        onChanged: () {},
      )));

      expect(find.textContaining('being made'), findsNothing);
      expect(find.textContaining('not on the shelf yet'), findsNothing);
      // And no way to claim any of it.
      expect(find.byType(Switch), findsNothing);
      // What is available is what SAP said, and nothing has been added to it.
      expect(find.textContaining('6 rolls available'), findsOneWidget);
    });

    testWidgets('an item with no stock record says nothing about runs either',
        (tester) async {
      await tester.pumpWidget(_host(ProductRow(
        line: OrderLine(product: _pctr()),
        stock: null,
        onChanged: () {},
      )));

      expect(find.textContaining('being made'), findsNothing);
    });
  });

  testWidgets('an incomplete item offers to be completed, not just refused',
      (tester) async {
    // It must still not be orderable — the arithmetic has no answer without
    // the belt count — but the block is something the rep can clear rather
    // than a message telling them to go and ask the office.
    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(
          product: Product({
        'name': 'PCTR-BAD',
        'item_name': 'Precured, half-imported',
        'item_group': 'Precured',
        'custom_weight_per_roll': 22.0,
      })),
      stock: null,
      onChanged: () {},
    )));

    expect(find.textContaining('Packing details needed'), findsOneWidget);
    expect(find.text('Rolls'), findsNothing);
    // Names only what is actually missing — the roll weight is already set.
    expect(find.textContaining('belts per roll'), findsOneWidget);
    expect(find.textContaining('weight of one roll'), findsNothing);
  });

  testWidgets('an item missing everything asks for everything', (tester) async {
    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(
          product: Product({
        'name': 'PCTR-EMPTY',
        'item_name': 'Precured, not imported',
        'item_group': 'Precured',
      })),
      stock: null,
      onChanged: () {},
    )));

    expect(find.textContaining('weight of one roll'), findsOneWidget);
    expect(find.textContaining('belts per roll'), findsOneWidget);
  });

  testWidgets('a complete item offers no packing prompt at all', (tester) async {
    // Once set, a packing figure is not editable from the app — it decides
    // what customers are charged.
    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(product: _pctr()),
      stock: null,
      onChanged: () {},
    )));

    expect(find.textContaining('Packing details needed'), findsNothing);
    expect(find.text('Rolls'), findsOneWidget);
  });
}
