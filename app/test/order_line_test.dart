// The arithmetic every Phase 1 order line depends on.
//
// The load-bearing property is that a rep quotes a rate per kilogram, the order
// stores rolls and a per-roll rate, and the two still come to the same money.
// A mistake here is a mistake on an invoice. Pure Dart: no backend, no widgets.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/models/product_category.dart';

Product _item(Map<String, dynamic> overrides) => Product({
      'name': 'ITEM-1',
      'item_name': 'Test item',
      'stock_uom': 'Roll',
      ...overrides,
    });

void main() {
  group('Which field holds which weight', () {
    // The item master calls the per-belt weight `custom_avg_weight_per_roll`.
    // The live data settles it: 174 MLG 120 reads 10.1 with 4 belts and a roll
    // weight of 40.4; 102 AJAX 60 reads 2.4 with 14 belts and 33.6. In both
    // cases field x belts = roll weight, so the field is per belt. Reading it
    // as a roll weight priced a roll at one belt's worth.
    Product product({double? perBelt, double? perRoll, int belts = 4}) =>
        Product({
          'name': 'PCTR-1',
          'item_group': 'Precured',
          if (perBelt != null) 'custom_avg_weight_per_roll': perBelt,
          if (perRoll != null) 'custom_weight_per_roll': perRoll,
          'custom_belts_per_roll': belts,
        });

    test('the misnamed field is read as the belt weight', () {
      final p = product(perBelt: 10.1, perRoll: 40.4);
      expect(p.weightPerBelt, 10.1);
      expect(p.weightPerRoll, 40.4);
      expect(p.rollWeight, 40.4, reason: 'a roll is priced by the roll weight');
    });

    test('the real numbers from the item master hold together', () {
      final p = product(perBelt: 2.4, perRoll: 33.6, belts: 14);
      expect(p.weightPerBelt * p.beltsPerRoll, closeTo(p.weightPerRoll, 0.001));
    });

    test('a roll weight is derived when only the belt weight is filled in', () {
      final p = product(perBelt: 10.1);
      expect(p.weightPerRoll, closeTo(40.4, 0.001));
      expect(p.isMisconfigured, isFalse);
    });

    test('a belt weight is derived when only the roll weight is filled in', () {
      final p = product(perRoll: 40.4);
      expect(p.weightPerBelt, closeTo(10.1, 0.001));
    });

    test('neither weight leaves the item unpriceable', () {
      expect(product().isMisconfigured, isTrue);
    });

    test('a weight with no belt count is still not orderable as PCTR', () {
      // PCTR is sold in belts as well as rolls, and the pool cuts rolls into
      // them, so the count is not optional.
      final p = Product({
        'name': 'PCTR-1',
        'item_group': 'Precured',
        'custom_weight_per_roll': 40.4,
      });
      expect(p.isMisconfigured, isTrue);
    });

    test('CTR reads the same roll-weight field', () {
      final p = Product({
        'name': 'CTR-1',
        'item_group': 'Hot Rubber',
        'custom_weight_per_roll': 30.5,
      });
      expect(p.rollWeight, 30.5);
      expect(p.isMisconfigured, isFalse);
    });
  });

  group('PCTR', () {
    // 22 kg to a roll, 4 belts to a roll, so a belt is 5.5 kg.
    final pctr = _item({
      'item_group': 'Precured',
      'custom_weight_per_roll': 22.0,
      'custom_belts_per_roll': 4,
    });

    test('whole rolls are counted in rolls and billed by weight', () {
      final line = OrderLine(product: pctr, rolls: 10, rate: 200);
      expect(line.qty, 10);
      expect(line.totalWeightKg, 220.0);
      expect(line.lineRate, 4400.0);
      expect(line.amount, 44000.0);
    });

    test('a per-kg rate and a per-roll rate reach the same amount', () {
      final line = OrderLine(product: pctr, rolls: 7, rate: 185);
      expect(line.amount, closeTo(line.totalWeightKg * 185, 0.0001));
    });

    test('loose belts are a fraction of a roll, and still priced by weight',
        () {
      final line = OrderLine(product: pctr, rolls: 2, looseBelts: 3, rate: 200);
      expect(line.qty, 2.75);
      expect(line.totalWeightKg, 60.5);
      expect(line.amount, closeTo(60.5 * 200, 0.0001));
    });

    test('the pool is booked in whole rolls and whole belts', () {
      final line = OrderLine(product: pctr, rolls: 2, looseBelts: 3);
      // Not 2.75 — minimum stock sits on a shelf as 2 rolls and 3 belts.
      expect(line.reserveQty, 2);
      expect(line.reserveBelts, 3);
    });

    test('the packing note says the weight is an average', () {
      final line = OrderLine(product: pctr, rolls: 1, looseBelts: 1);
      expect(line.packingNote, contains('avg'));
      expect(line.packingNote, contains('1 roll'));
      expect(line.packingNote, contains('1 loose belt'));
    });

    test('an item imported without a belt count is flagged, not divided by zero',
        () {
      final broken = _item({
        'item_group': 'Precured',
        'custom_weight_per_roll': 22.0,
      });
      expect(broken.isMisconfigured, isTrue);
      expect(OrderLine(product: broken, rolls: 1, looseBelts: 2).qty, 1);
    });
  });

  group('CTR', () {
    final ctr = _item({
      'item_group': 'Hot Rubber',
      'custom_weight_per_roll': 30.5,
    });

    test('rolls bill at the exact weight', () {
      final line = OrderLine(product: ctr, rolls: 4, rate: 180);
      expect(line.qty, 4);
      expect(line.totalWeightKg, 122.0);
      expect(line.amount, closeTo(122.0 * 180, 0.0001));
    });

    test('loose belts are ignored — CTR ships whole rolls only', () {
      final line = OrderLine(product: ctr, rolls: 2, looseBelts: 9);
      expect(line.qty, 2);
      expect(line.totalWeightKg, 61.0);
      expect(line.reserveBelts, 0);
    });

    test('the packing note carries the weight the proforma prints', () {
      expect(OrderLine(product: ctr, rolls: 2).packingNote,
          '2 rolls · 61.00 kg');
    });
  });

  group('Bonding gum', () {
    final bg = _item({'item_group': 'Bonding Gum', 'stock_uom': 'Kg'});

    test('a box is 4 rolls of 5 kg, priced straight off the per-kg rate', () {
      final line = OrderLine(product: bg, boxes: 1, rate: 150);
      expect(line.qty, 20.0);
      expect(line.lineRate, 150);
      expect(line.amount, 3000.0);
    });

    test('boxes and loose rolls add up', () {
      expect(OrderLine(product: bg, boxes: 3, rolls: 2).qty, 70.0);
    });

    test('every reachable quantity is a multiple of 5 kg', () {
      for (var boxes = 0; boxes < 5; boxes++) {
        for (var rolls = 0; rolls < 9; rolls++) {
          final qty = OrderLine(product: bg, boxes: boxes, rolls: rolls).qty;
          expect(qty % 5, 0, reason: '$boxes boxes + $rolls rolls gave $qty kg');
        }
      }
    });
  });

  group('Vulcanizing solution', () {
    test('the two tin sizes are separate lines with their own rates', () {
      final tenL = _item({
        'name': 'VS-10',
        'item_group': 'Vulcanizing Solution',
        'custom_pack_litres': 10.0,
        'stock_uom': 'Nos',
      });
      final thirtyL = _item({
        'name': 'VS-30',
        'item_group': 'Vulcanizing Solution',
        'custom_pack_litres': 30.0,
        'stock_uom': 'Nos',
      });

      final small = OrderLine(product: tenL, cans: 3, rate: 950);
      final large = OrderLine(product: thirtyL, cans: 2, rate: 2700);

      // Priced by the tin, not by weight.
      expect(small.qty, 3);
      expect(small.amount, 2850);
      expect(small.totalWeightKg, 0);
      expect(large.amount, 5400);
      expect(tenL.category.rateUnit, 'can');
      expect(small.packingNote, '3 x 10L cans');
    });
  });

  group('Sales Order payload', () {
    test('rolls and a per-roll rate, with the quoted per-kg rate kept beside',
        () {
      final line = OrderLine(
        product: _item({
          'item_group': 'Precured',
          'custom_weight_per_roll': 22.0,
          'custom_belts_per_roll': 4,
        }),
        rolls: 5,
        rate: 210,
      );
      final payload = line.toSalesOrderItem();
      expect(payload['qty'], 5.0);
      expect(payload['rate'], 4620.0); // 210 x 22
      expect(payload['custom_rate_per_kg'], 210);
      expect(payload['custom_total_weight'], 110.0);
      expect(payload['custom_rolls'], 5);
      expect(payload['custom_product_category'], 'PCTR');
      // qty x rate must equal weight x rate-per-kg, or the invoice is wrong.
      expect((payload['qty'] as double) * (payload['rate'] as double),
          closeTo(110.0 * 210, 0.0001));

      // Sent explicitly. ERPNext derives `amount` for a Sales Order Item but
      // not for our own `Lead Order Item`, so leaving it off made every lead
      // order worth nothing on the manager's review while the rep's own screen
      // showed the right figure.
      expect(payload['amount'], closeTo(110.0 * 210, 0.01));
    });

    test('every family sends a line amount that matches its own arithmetic',
        () {
      final cases = <String, OrderLine>{
        'PCTR': OrderLine(
            product: _item({
              'item_group': 'Precured',
              'custom_weight_per_roll': 22.0,
              'custom_belts_per_roll': 4,
            }),
            rolls: 2,
            looseBelts: 1,
            rate: 100),
        'CTR': OrderLine(
            product: _item({
              'item_group': 'Hot Rubber',
              'custom_weight_per_roll': 30.0,
            }),
            rolls: 3,
            rate: 90),
        'Bonding Gum': OrderLine(
            product: _item({'item_group': 'Bonding Gum'}), boxes: 2, rate: 80),
        'Solution': OrderLine(
            product: _item({
              'item_group': 'Vulcanizing Solution',
              'custom_pack_litres': 10.0,
            }),
            cans: 4,
            rate: 250),
      };

      cases.forEach((label, line) {
        final p = line.toSalesOrderItem();
        expect(p['amount'], closeTo(line.amount, 0.01), reason: label);
        expect((p['qty'] as double) * (p['rate'] as double),
            closeTo(line.amount, 0.01),
            reason: '$label: amount must be qty x rate');
      });
    });

    test('an aged batch is only sent when the rep chose one', () {
      final bg = _item({'item_group': 'Bonding Gum'});
      expect(OrderLine(product: bg, boxes: 1).toSalesOrderItem(),
          isNot(contains('custom_aged_batch')));
      expect(
          OrderLine(product: bg, boxes: 1, agedBatch: 'MSB-00004')
              .toSalesOrderItem()['custom_aged_batch'],
          'MSB-00004');
    });

    test('solution carries no weight', () {
      final line = OrderLine(
        product: _item({
          'item_group': 'Vulcanizing Solution',
          'custom_pack_litres': 30.0,
        }),
        cans: 2,
      );
      expect(line.toSalesOrderItem()['custom_total_weight'], 0);
    });
  });

  group('Category matching', () {
    test('matches the item groups the item master actually uses', () {
      expect(categoryOfGroup('Precured'), ProductCategory.pctr);
      expect(categoryOfGroup('Hot Rubber'), ProductCategory.ctr);
      expect(categoryOfGroup('Bonding Gum'), ProductCategory.bondingGum);
      expect(categoryOfGroup('  vulcanizing solution '),
          ProductCategory.vulcanizingSolution);
    });

    test('an unknown group still sells, on a plain row', () {
      expect(categoryOfGroup('Repair Tyres'), ProductCategory.other);
      final other = _item({'item_group': 'Repair Tyres'});
      expect(other.isMisconfigured, isFalse);
      expect(OrderLine(product: other, rolls: 7, rate: 10).amount, 70);
    });
  });

  group('Line completeness', () {
    final bg = _item({'item_group': 'Bonding Gum'});

    test('a line with quantity but no rate is unfinished, not free', () {
      final line = OrderLine(product: bg, boxes: 1);
      expect(line.isEmpty, isFalse);
      expect(line.needsRate, isTrue);
    });

    test('an untouched line is not asking for a rate', () {
      expect(OrderLine(product: bg).needsRate, isFalse);
    });
  });
}
