// How much of an approved order's line may go on a pick list.
//
// Checked against `shared/fixtures/pick_list.json`, the rule the
// manna_pick_list_submit Server Script applies again on the server.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/pick_list.dart';

void main() {
  final fixture = json.decode(
          File('../shared/fixtures/pick_list.json').readAsStringSync())
      as Map<String, dynamic>;

  group('shared/fixtures/pick_list.json', () {
    for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['why'] as String, () {
        final line = c['line'] as Map;
        final already = (c['already_picked'] as num).toDouble();
        expect(orderedForPick(line), (c['ordered'] as num).toDouble());
        expect(remainingToPick(line, already), (c['remaining'] as num).toDouble());
        expect(
            maxPick(line,
                alreadyPicked: already,
                available: (c['available'] as num).toDouble()),
            (c['max_pick'] as num).toDouble());
      });
    }
  });

  group('shared/fixtures/pick_list.json kilos', () {
    for (final c in (fixture['kg_cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['why'] as String, () {
        final line = c['line'] as Map;
        final already = (c['already_kg'] as num).toDouble();
        expect(orderedKg(line), (c['ordered_kg'] as num).toDouble());
        expect(remainingKg(line, already), (c['remaining_kg'] as num).toDouble());
        expect(maxPickKg(line, alreadyKg: already), (c['max_kg'] as num).toDouble());
        expect(kgFollowsQty(line), c['kg_follows_qty']);
      });
    }
  });

  test('a pick list reads its kilos and what SAP made from it', () {
    final l = PickList.fromJson({
      'name': 'PICK-00012',
      'status': 'Submitted',
      'sap_pick_list': '7',
      'hitech_invoice': '489',
      'items': [
        {'sales_order_item': 'a', 'picked_qty': 2, 'picked_kg': 48.6},
      ],
    });
    expect(l.items.single.pickedKg, 48.6);
    expect(l.sapPickList, '7');
    expect(l.hitechInvoice, '489');
    expect(l.mtDelivery, '');
    expect(pickedKgSoFar([l]), {'a': 48.6});
  });

  test('tread rubber is counted in rolls though its stock UOM is Kg', () {
    expect(pickUnit({'custom_rolls': 2, 'stock_uom': 'Kg', 'qty': 2}), 'rolls');
    expect(pickUnit({'custom_rolls': 0, 'stock_uom': 'Kg', 'qty': 50}), 'Kg');
    expect(pickUnit({'custom_rolls': 0, 'stock_uom': 'Nos', 'qty': 4}), 'Nos');
  });

  test('only Submitted lists count towards what is already picked', () {
    final lists = [
      PickList.fromJson({
        'name': 'PICK-00001',
        'status': 'Submitted',
        'items': [
          {'sales_order_item': 'a', 'picked_qty': 2},
          {'sales_order_item': 'b', 'picked_qty': 1},
        ],
      }),
      PickList.fromJson({
        'name': 'PICK-00002',
        'status': 'Cancelled',
        'items': [
          {'sales_order_item': 'a', 'picked_qty': 5},
        ],
      }),
      PickList.fromJson({
        'name': 'PICK-00003',
        'status': 'Submitted',
        'items': [
          {'sales_order_item': 'a', 'picked_qty': 3},
        ],
      }),
    ];
    expect(pickedSoFar(lists), {'a': 5.0, 'b': 1.0});
  });
}
