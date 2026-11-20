// Starting a new order from a previous one: what carries over and what does
// not (core/order_copy.dart).

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/order_copy.dart';
import 'package:manna_field_sales/models/product_category.dart';

Product _p(String code, String group, [Map<String, dynamic>? extra]) =>
    Product({
      'name': code,
      'item_name': 'Item $code',
      'item_group': group,
      'custom_weight_per_roll': 22.0,
      'custom_belts_per_roll': 4,
      'custom_pack_litres': 5.0,
      ...?extra,
    });

List<OrderLine> _catalogue() => [
      OrderLine(product: _p('PCTR-1', 'Precured')),
      OrderLine(product: _p('BG-1', 'Bonding Gum')),
      OrderLine(product: _p('VS-1', 'Vulcanizing Solution')),
    ];

OrderLine _line(List<OrderLine> ls, String code) =>
    ls.firstWhere((l) => l.product.code == code);

void main() {
  test('the quantities are copied, in the units the rep counted', () {
    final lines = _catalogue();
    final r = copyOrderQuantities(lines, {
      'items': [
        {'item_code': 'PCTR-1', 'custom_rolls': 3, 'qty': 3},
        {'item_code': 'BG-1', 'custom_boxes': 2, 'custom_rolls': 1, 'qty': 45},
        {'item_code': 'VS-1', 'custom_cans': 4, 'qty': 4},
      ]
    });
    expect(_line(lines, 'PCTR-1').rolls, 3);
    expect(_line(lines, 'BG-1').boxes, 2);
    expect(_line(lines, 'BG-1').rolls, 1);
    expect(_line(lines, 'VS-1').cans, 4);
    expect(r.copied, ['PCTR-1', 'BG-1', 'VS-1']);
    expect(r.leftOut, isEmpty);
  });

  test('the old rate is never copied: today\'s price is filled in fresh', () {
    final lines = _catalogue();
    copyOrderQuantities(lines, {
      'items': [
        {
          'item_code': 'PCTR-1',
          'custom_rolls': 2,
          'custom_rate_per_kg': 280,
          'rate': 6160,
        },
      ]
    });
    expect(_line(lines, 'PCTR-1').rate, 0);
  });

  test('loose belts are not copied; a belts-only line is said, not hidden',
      () {
    final lines = _catalogue();
    final r = copyOrderQuantities(lines, {
      'items': [
        {
          'item_code': 'PCTR-1',
          'item_name': 'Precured 100',
          'custom_rolls': 0,
          'custom_loose_belts': 3,
          'qty': 0.75,
        },
      ]
    });
    expect(_line(lines, 'PCTR-1').looseBelts, 0);
    expect(_line(lines, 'PCTR-1').isEmpty, isTrue);
    expect(r.leftOut, ['Precured 100']);
  });

  test('an item no longer sold is named, not quietly dropped', () {
    final lines = _catalogue();
    final r = copyOrderQuantities(lines, {
      'items': [
        {'item_code': 'GONE-9', 'item_name': 'Old grade 90', 'custom_rolls': 2},
        {'item_code': 'PCTR-1', 'custom_rolls': 1},
      ]
    });
    expect(r.leftOut, ['Old grade 90']);
    expect(r.copied, ['PCTR-1']);
  });

  test('an old order with only qty is read in the item\'s own unit', () {
    final lines = _catalogue();
    copyOrderQuantities(lines, {
      'items': [
        {'item_code': 'PCTR-1', 'qty': 5},
        {'item_code': 'BG-1', 'qty': 20}, // kg: 4 rolls of 5 kg
        {'item_code': 'VS-1', 'qty': 6},
      ]
    });
    expect(_line(lines, 'PCTR-1').rolls, 5);
    expect(_line(lines, 'BG-1').rolls, 4);
    expect(_line(lines, 'VS-1').cans, 6);
  });

  test('the same item on two rows is added up, not overwritten', () {
    final lines = _catalogue();
    final r = copyOrderQuantities(lines, {
      'items': [
        {'item_code': 'PCTR-1', 'custom_rolls': 2},
        {'item_code': 'PCTR-1', 'custom_rolls': 3},
      ]
    });
    expect(_line(lines, 'PCTR-1').rolls, 5);
    expect(r.copied, ['PCTR-1']);
  });

  // 19 Nov 2026: SAL-ORD-2026-00156 named I-11689, the pre-SAP item. SAP
  // prices the same product as PMD01003004, so the copy read "No price in
  // SAP" while a fresh order showed a price.
  group('an old item SAP no longer prices', () {
    List<OrderLine> catalogue() => [
          OrderLine(
              product: Product({
            'name': 'I-11689',
            'item_name': 'TREAD RUBBER  PRECURED BLACK PEARL 140 MSR 93"',
            'item_group': 'FG - TRP - Black Pearl',
            'custom_weight_per_roll': 31.36,
            'custom_belts_per_roll': 8,
          })),
          OrderLine(
              product: Product({
            'name': 'PMD01003004',
            'item_name': 'PCTR MANNA DOUBLE BLUE MSR 140 93 (BLACK PEARL)',
            'item_group': 'FG - TRP - Black Pearl',
            'custom_weight_per_roll': 31.36,
            'custom_belts_per_roll': 8,
          })),
          OrderLine(
              product: Product({
            'name': 'PMB01003004',
            'item_name': 'PCTR MANNA BLUE MSR 140 93 (PLATINUM)',
            'item_group': 'FG - TRP - Platinum',
            'custom_weight_per_roll': 31.36,
            'custom_belts_per_roll': 8,
          })),
          OrderLine(
              product: Product({
            'name': 'I-11716',
            'item_name': 'TREAD RUBBER  PRECURED BLACK PEARL 130 SL 90"',
            'item_group': 'FG - TRP - Black Pearl',
            'custom_weight_per_roll': 36,
            'custom_belts_per_roll': 8,
          })),
        ];
    bool priced(OrderLine l) => l.product.code.startsWith('PM');

    test('is moved onto today\'s item for the same product', () {
      final lines = catalogue();
      final r = copyOrderQuantities(lines, {
        'items': [
          {
            'item_code': 'I-11689',
            'item_name': 'TREAD RUBBER  PRECURED BLACK PEARL 140 MSR 93"',
            'custom_rolls': 1,
          },
        ]
      }, sellable: priced);
      expect(r.copied, ['PMD01003004']);
      expect(r.swapped, {'I-11689': 'PMD01003004'});
      expect(_line(lines, 'PMD01003004').rolls, 1);
      expect(_line(lines, 'I-11689').rolls, 0);
      // Never onto another grade of the same size.
      expect(_line(lines, 'PMB01003004').rolls, 0);
    });

    test('with no item today for that product, it is left out and named',
        () {
      final lines = catalogue();
      final r = copyOrderQuantities(lines, {
        'items': [
          {
            'item_code': 'I-11716',
            'item_name': 'TREAD RUBBER  PRECURED BLACK PEARL 130 SL 90"',
            'custom_rolls': 2,
          },
        ]
      }, sellable: priced);
      expect(r.copied, isEmpty);
      expect(r.leftOut, ['TREAD RUBBER  PRECURED BLACK PEARL 130 SL 90"']);
      expect(_line(lines, 'I-11716').rolls, 0);
    });

    test('two items that could be it is a guess: left out, not picked', () {
      final lines = catalogue()
        ..add(OrderLine(
            product: Product({
          'name': 'PMX01003004',
          'item_name': 'PCTR OTHER MSR 140 93 (BLACK PEARL)',
          'item_group': 'FG - TRP - Black Pearl',
          'custom_weight_per_roll': 31.36,
          'custom_belts_per_roll': 8,
        })));
      final r = copyOrderQuantities(lines, {
        'items': [
          {'item_code': 'I-11689', 'custom_rolls': 1},
        ]
      }, sellable: priced);
      expect(r.copied, isEmpty);
      expect(r.leftOut, hasLength(1));
    });
  });

  test('the old and new names of one product are recognised as the same', () {
    expect(
        sameProduct('TREAD RUBBER  PRECURED BLACK PEARL 140 MSR 93"',
            'PCTR MANNA DOUBLE BLUE MSR 140 93 (BLACK PEARL)'),
        isTrue);
    expect(
        sameProduct('TREAD RUBBER PRECURED POLYGOLD 140 MSR 93""',
            'PCTR VERDO MSR 140 93 (POLY GOLD)'),
        isTrue);
    // Same size, another grade.
    expect(
        sameProduct('TREAD RUBBER  PRECURED BLACK PEARL 140 MSR 93"',
            'PCTR MANNA BLUE MSR 140 93 (PLATINUM)'),
        isFalse);
    // Same grade, another thickness.
    expect(
        sameProduct('Tread Rubber Precured Black Pearl 140 MSR 90',
            'PCTR MANNA DOUBLE BLUE MSR 140 93 (BLACK PEARL)'),
        isFalse);
    // Same numbers, another pattern.
    expect(
        sameProduct('TREAD RUBBER  PRECURED BLACK PEARL 140 SL 93"',
            'PCTR MANNA DOUBLE BLUE MSR 140 93 (BLACK PEARL)'),
        isFalse);
  });
}
