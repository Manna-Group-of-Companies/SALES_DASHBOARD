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
      'custom_avg_weight_per_roll': 22.0,
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

    // The pool is counted in rolls, which is the item's stock UOM — not in the
    // kilograms the rate is quoted against.
    expect(find.textContaining('6 of 10 rolls available'), findsOneWidget);
    expect(find.textContaining('4 booked'), findsOneWidget);
  });

  testWidgets('a fully booked pool does not read as an empty shelf',
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

    expect(find.textContaining('fully booked'), findsOneWidget);
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

  testWidgets('a misconfigured item is called out instead of priced at zero',
      (tester) async {
    await tester.pumpWidget(_host(ProductRow(
      line: OrderLine(
          product: Product({
        'name': 'PCTR-BAD',
        'item_name': 'Precured, half-imported',
        'item_group': 'Precured',
        'custom_avg_weight_per_roll': 22.0,
      })),
      stock: null,
      onChanged: () {},
    )));

    expect(find.textContaining('missing its packing details'), findsOneWidget);
    expect(find.text('Rolls'), findsNothing);
  });
}
