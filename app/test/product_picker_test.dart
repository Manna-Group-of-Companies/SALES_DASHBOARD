// The Add products page of a copied order (20 Nov 2026).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/screens/orders/product_picker_screen.dart';
import 'package:manna_field_sales/screens/orders/product_row.dart';

OrderLine _l(String code, String name) => OrderLine(
    product: Product({
      'name': code,
      'item_name': name,
      'item_group': 'Precured',
      'custom_weight_per_roll': 22.0,
      'custom_belts_per_roll': 4,
    }),
    rate: 300);

void main() {
  late List<OrderLine> lines;
  bool? result;

  Future<void> open(WidgetTester tester) async {
    lines = [
      _l('PMD-1', 'PCTR MANNA DOUBLE BLUE MSR 140 93 (BLACK PEARL)'),
      _l('PMB-1', 'PCTR MANNA BLUE AJAX 102 60 (PLATINUM)'),
    ];
    result = null;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                result = await Navigator.of(ctx).push<bool>(
                    MaterialPageRoute(
                        builder: (_) => ProductPickerScreen(
                              candidates: lines,
                              rowBuilder: (line, changed) => ProductRow(
                                key: ValueKey(line.product.code),
                                line: line,
                                stock: null,
                                showMinimumStock: false,
                                onChanged: changed,
                              ),
                            )));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Done stays off until something is picked', (tester) async {
    await open(tester);
    final done = find.widgetWithText(FilledButton, 'Done');
    expect(tester.widget<FilledButton>(done).onPressed, isNull);
    expect(find.text('0 products selected'), findsOneWidget);
  });

  testWidgets('search finds the product; ADD picks it; Done goes back',
      (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'bp 140');
    await tester.pumpAndSettle();
    expect(find.textContaining('AJAX'), findsNothing);
    expect(find.textContaining('MSR 140 93'), findsOneWidget);

    await tester.tap(find.text('ADD'));
    await tester.pumpAndSettle();
    expect(lines.first.rolls, 1);
    expect(find.text('1 product selected'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
