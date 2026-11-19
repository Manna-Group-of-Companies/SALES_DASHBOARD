// HOT rubber with no roll weight is ordered in kilos (14 Nov 2026). 503 of
// the 507 HOT items on live had no roll weight, and each one stopped the
// order on a packing-details prompt; the user asked for that prompt to go.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/screens/orders/product_row.dart';

Product _hot({double? perRoll}) => Product({
      'name': 'HMD001110',
      'item_name': 'HOT MANNA DOUBLE BLUE 34 14 (BLACK PEARL)',
      'item_group': 'HOT',
      'stock_uom': 'Kg',
      if (perRoll != null) 'custom_weight_per_roll': perRoll,
    });

void main() {
  test('a HOT item with no roll weight is sold by the kilo, not blocked', () {
    final p = _hot();
    expect(p.category, ProductCategory.ctr);
    expect(p.soldByKg, isTrue);
    expect(p.isMisconfigured, isFalse);
  });

  test('kilos x rate per kg is the amount, and the kilos go to SAP', () {
    final line = OrderLine(product: _hot(), kilos: 125.5, rate: 210);
    expect(line.qty, 125.5);
    expect(line.lineRate, 210);
    expect(line.amount, closeTo(125.5 * 210, 0.0001));
    final item = line.toSalesOrderItem();
    // Sync-SapOrders.ps1 takes custom_total_weight as SAP's quantity in kg
    // and refuses a line where it is zero.
    expect(item['custom_total_weight'], 125.5);
    expect(item['custom_rolls'], 0);
    expect(item['custom_packing_note'], '125.5 kg');
  });

  test('no kilos is an empty line, not a free one', () {
    final line = OrderLine(product: _hot(), rate: 210);
    expect(line.isEmpty, isTrue);
  });

  test('a HOT item that has a roll weight is still counted in rolls', () {
    final p = _hot(perRoll: 30.5);
    expect(p.soldByKg, isFalse);
    final line = OrderLine(product: p, rolls: 2, rate: 200);
    expect(line.totalWeightKg, 61);
    expect(line.amount, closeTo(61 * 200, 0.0001));
  });

  // 18 Nov 2026: the rep may add the roll weight, never must.
  test('kilos typed before a roll weight become the nearest whole rolls, at least one', () {
    expect(rollsForKilos(52, 25), 2);
    expect(rollsForKilos(63, 25), 3);
    expect(rollsForKilos(10, 25), 1);
    expect(rollsForKilos(0, 25), 0);
    expect(rollsForKilos(40, 0), 0);
  });

  test('once the item has a roll weight it is counted in rolls', () {
    final p = _hot();
    expect(p.soldByKg, isTrue);
    p.doc['custom_weight_per_roll'] = 25.0;
    expect(p.soldByKg, isFalse);
    final line = OrderLine(product: p, rolls: 2, rate: 313);
    expect(line.qty, 2);
    expect(line.totalWeightKg, 50);
    expect(line.amount, closeTo(50 * 313, 0.0001));
    expect(line.toSalesOrderItem()['custom_rolls'], 2);
  });

  testWidgets('a HOT row offers Add roll weight beside the kilos, without blocking', (tester) async {
    final line = OrderLine(product: _hot());
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: ProductRow(
                    line: line, stock: null, onChanged: () {}, typedRate: true)))));
    expect(find.text('Kilos'), findsOneWidget);
    expect(find.text('Add roll weight'), findsOneWidget);
    // Kilos still order without it.
    await tester.enterText(find.widgetWithText(TextField, 'Kilos'), '52');
    expect(line.kilos, 52);
    // It asks for the roll weight only: hot rubber has no belts.
    await tester.tap(find.text('Add roll weight'));
    await tester.pumpAndSettle();
    expect(find.text('Weight of one roll'), findsOneWidget);
    expect(find.text('Belts per roll'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(line.kilos, 52);
    expect(find.text('Kilos'), findsOneWidget);
  });

  testWidgets('with a roll weight the row is a Rolls counter, the weight exact', (tester) async {
    final line = OrderLine(product: _hot(perRoll: 25));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: ProductRow(
                    line: line, stock: null, onChanged: () {}, typedRate: true)))));
    expect(find.text('Rolls'), findsOneWidget);
    expect(find.text('Kilos'), findsNothing);
    expect(find.text('Add roll weight'), findsNothing);
    expect(find.textContaining('25 kg/roll exact'), findsOneWidget);
  });

  testWidgets('the row asks for kilos, and no packing details', (tester) async {
    final line = OrderLine(product: _hot());
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: ProductRow(
                    line: line, stock: null, onChanged: () {}, typedRate: true)))));
    expect(find.textContaining('Packing details'), findsNothing);
    expect(find.text('Kilos'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Kilos'), '40.25');
    expect(line.kilos, 40.25);
  });
}
