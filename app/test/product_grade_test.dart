// A product's grade, read from its name or item group, and the colour the
// order screen gives it (23 Nov 2026).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/product_grade.dart';
import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/screens/orders/product_row.dart';

void main() {
  group('the grade is read from either naming style', () {
    test("SAP's names, grade in brackets", () {
      expect(productGrade('PCTR MANNA DOUBLE BLUE MSR 140 93 (BLACK PEARL)'),
          'BLACK PEARL');
      expect(productGrade('PCTR VERDO AJAX 102 60 (POLY GOLD)'), 'POLY GOLD');
      expect(productGrade('PCTR ROX AJAX 102 60 (SILVER)'), 'SILVER');
    });

    test('the old names, grade in the middle, spelt any way', () {
      expect(productGrade('TREAD RUBBER  PRECURED BLACK PEARL 130 SL 90"'),
          'BLACK PEARL');
      expect(productGrade('TREAD RUBBER PRECURED POLYGOLD 140 MSR 93""'),
          'POLY GOLD');
      expect(productGrade('TREAD RUBBER HOT POLYCOLD 34*12'), 'POLY GOLD');
      expect(productGrade('Tread Rubber Precured Diamond 130 SL 90'), 'DIAMOND');
    });

    test('the item group is used when the name says nothing', () {
      expect(productGrade('220 MXM 128 (MANNA)', 'FG - TRP - Platinum'),
          'PLATINUM');
    });

    test('no grade, or two, is no grade: never a guess', () {
      expect(productGrade('BONDING GUM 1KG'), isNull);
      expect(productGrade('SILVER PLATINUM MIX 34 12'), isNull);
    });
  });

  testWidgets('each product card is labelled with its grade',
      (tester) async {
    Future<void> show(Map<String, dynamic> doc) => tester.pumpWidget(
        MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(
                    child: ProductRow(
                        line: OrderLine(product: Product(doc)),
                        stock: null,
                        onChanged: () {})))));

    await show({
      'name': 'PMD01003004',
      'item_name': 'PCTR MANNA DOUBLE BLUE MSR 140 93 (BLACK PEARL)',
      'item_group': 'FG - TRP - Black Pearl',
      'custom_weight_per_roll': 31.36,
      'custom_belts_per_roll': 8,
    });
    expect(find.text('BLACK PEARL'), findsOneWidget);

    await show({
      'name': 'BG-1',
      'item_name': 'Bonding gum',
      'item_group': 'Bonding Gum',
    });
    expect(find.text('BONDING GUM'), findsOneWidget);
  });
}
