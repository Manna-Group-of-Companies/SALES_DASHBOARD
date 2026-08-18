// What a rep sees on a product row.
//
// The distinction these cover is the one most easily lost: an item that is not
// on the minimum-stock list must read "No minimum stock", which is a different
// statement from an item whose pool is empty. Getting those two confused would
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
  testWidgets('an item off the minimum-stock list says so', (tester) async {
    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(product: _pctr()),
      stock: null,
      onChanged: () {},
    )));

    expect(find.text('No minimum stock'), findsOneWidget);
  });

  testWidgets('a pool shows what is left after other reps have booked',
      (tester) async {
    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(product: _pctr()),
      stock: MinStock(
        itemCode: 'PCTR-100',
        minimumQty: 10,
        reservedQty: 4,
        myReservedQty: 0,
      ),
      onChanged: () {},
    )));

    // No batch rows, so this falls back to the pool arithmetic: 10 - 4.
    // Counted in rolls, the item's stock UOM — not the kilograms the rate is
    // quoted against.
    expect(find.textContaining('6 rolls available'), findsOneWidget);
    expect(find.textContaining('4 booked'), findsOneWidget);
  });

  testWidgets('a restocked shelf reads above the minimum, not pinned to it',
      (tester) async {
    // The reporting bug: restocking adds batch rows and never moves the pool,
    // so availability read off the pool stayed stuck at the threshold.
    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(product: _pctr()),
      stock: MinStock(
        itemCode: 'PCTR-100',
        minimumQty: 10,
        reservedQty: 0,
        myReservedQty: 0,
        batches: [
          StockBatch(
              name: 'MSB-1',
              itemCode: 'PCTR-100',
              batchDate: '2026-01-01',
              qty: 12,
              looseBelts: 0,
              originalQty: 12,
              ageDays: 40),
          StockBatch(
              name: 'MSB-2',
              itemCode: 'PCTR-100',
              batchDate: '2026-02-01',
              qty: 15,
              looseBelts: 0,
              originalQty: 15,
              ageDays: 5),
        ],
      ),
      onChanged: () {},
    )));

    expect(find.textContaining('27 rolls available'), findsOneWidget);
    // The threshold is not quoted when the shelf is comfortably above it.
    expect(find.textContaining('below minimum'), findsNothing);
  });

  testWidgets('a shelf under the minimum says so', (tester) async {
    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(product: _pctr()),
      stock: MinStock(
        itemCode: 'PCTR-100',
        minimumQty: 10,
        reservedQty: 0,
        myReservedQty: 0,
        batches: [
          StockBatch(
              name: 'MSB-1',
              itemCode: 'PCTR-100',
              batchDate: '2026-01-01',
              qty: 3,
              looseBelts: 0,
              originalQty: 12,
              ageDays: 40),
        ],
      ),
      onChanged: () {},
    )));

    expect(find.textContaining('3 rolls available'), findsOneWidget);
    expect(find.textContaining('below minimum 10'), findsOneWidget);
  });

  testWidgets('an empty shelf does not read as an item with no pool at all',
      (tester) async {
    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(product: _pctr()),
      stock: MinStock(
        itemCode: 'PCTR-100',
        minimumQty: 10,
        reservedQty: 10,
        myReservedQty: 0,
      ),
      onChanged: () {},
    )));

    expect(find.textContaining('None left'), findsOneWidget);
    // "No minimum stock" means the item is not on the list at all, which is a
    // different thing from being on it and sold out.
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
    MinStock shelf({double available = 10}) => MinStock(
          itemCode: 'PCTR-100',
          minimumQty: 10,
          reservedQty: 10 - available,
          myReservedQty: 0,
        );

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
    MinStock pool({double inProduction = 0, double available = 6}) => MinStock(
          itemCode: 'PCTR-100',
          minimumQty: 10,
          reservedQty: 10 - available,
          myReservedQty: 0,
          inProductionQty: inProduction,
        );

    testWidgets('a rep is never told about a replenishment run', (tester) async {
      /*
       * Reversed on 18 Aug 2026. This used to assert the opposite — that a run
       * WAS shown on the order row — on the reasoning that "none left" and
       * "none left, twenty being made" are different answers to give somebody
       * at a counter.
       *
       * That reasoning was overtaken. A replenishment run goes into COMPANY
       * stock: production make it, the stock person receives it, and it
       * reaches the shelf as a batch. Until then it is not stock anybody can
       * sell and it has no date attached, so telling a rep only invited a
       * promise nobody could keep.
       *
       * Production against a specific ORDER is a different flow and is still
       * shown, on that order's own lines, with its stage.
       */
      await tester.pumpWidget(_host(ProductRow(
        line: OrderLine(product: _pctr()),
        stock: pool(inProduction: 20),
        onChanged: () {},
      )));

      expect(find.textContaining('being made'), findsNothing);
      expect(find.textContaining('not on the shelf yet'), findsNothing);
      // And no way to claim any of it.
      expect(find.byType(Switch), findsNothing);
    });

    testWidgets('it never inflates what is available to sell', (tester) async {
      // 6 available with 20 on a run must still read 6. The run is intent,
      // not stock.
      await tester.pumpWidget(_host(ProductRow(
        line: OrderLine(product: _pctr()),
        stock: pool(inProduction: 20, available: 6),
        onChanged: () {},
      )));

      expect(find.textContaining('6 rolls available'), findsOneWidget);
      expect(find.textContaining('26'), findsNothing);
    });

    testWidgets('nothing is said when no run is on', (tester) async {
      await tester.pumpWidget(_host(ProductRow(
        line: OrderLine(product: _pctr()),
        stock: pool(),
        onChanged: () {},
      )));

      expect(find.textContaining('being made'), findsNothing);
    });

    testWidgets('an item off the minimum-stock list says nothing about runs',
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
