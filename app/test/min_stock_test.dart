// What a rep is shown about stock, and who is shown it at all.
//
// The dead-stock group that stood here is gone. It tested [MinStock] against a
// *minimum-stock pool*: whether an item on the fast-moving list had stopped
// selling, measured off a `last_sold_on` stamp the pool carried. That pool was
// removed on 17 September 2026 — every one of its 129 rows held a minimum of
// zero, so no alarm built on it had ever been able to fire — and the model
// now carries one figure, straight from SAP.
//
// The unit rules below are untouched by any of that: a rep must never be shown
// another business unit's catalogue, but an item nobody has assigned a unit to
// yet has to stay visible, or the product list empties the day the field is
// added.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/services/api.dart';

void main() {
  group('Availability', () {
    test('what SAP sent is what is available, with nothing taken off it', () {
      // The figure has already had every open SAP order deducted from it.
      // Anything subtracted here would deduct the same roll twice.
      final s = MinStock.fromJson({
        'item_code': 'ITEM-1',
        'available_qty': 6,
        'available_loose_belts': 5,
        'belts_per_roll': 10,
      });
      expect(s.availableQty, 6);
      expect(s.availableLooseBelts, 5);
      expect(s.weightsKnown, isTrue);
    });

    test('an item with no weights set reports nothing available', () {
      // Not a guess and not a conversion: SAP holds this in kilograms and
      // nobody has said what a roll weighs. On instruction, it reads as
      // nothing available until the weights are loaded.
      final s = MinStock.fromJson({
        'item_code': 'ITEM-1',
        'available_qty': 756,
        'available_loose_belts': 3,
        'belts_per_roll': 0,
        'weights_known': false,
      });
      expect(s.availableQty, 0);
      expect(s.availableLooseBelts, 0);
      expect(s.weightsKnown, isFalse);
    });

    test('the belt ceiling counts every belt, not just the loose ones', () {
      // Ordering belts opens a roll: the belts asked for go out and the rest
      // of that roll comes back as loose stock.
      const s = MinStock(
          itemCode: 'ITEM-1',
          availableQty: 4,
          availableLooseBelts: 2,
          beltsPerRoll: 10);
      expect(s.beltCeiling(10), 42);
    });

    test('an item not sold in belts offers only what is loose', () {
      const s =
          MinStock(itemCode: 'ITEM-1', availableQty: 4, availableLooseBelts: 0);
      expect(s.beltCeiling(0), 0);
    });
  });

  group('Opening rolls for belts', () {
    test('belts already loose open nothing', () {
      expect(MinStock.rollsToOpen(3, 5, 10), 0);
    });

    test('a shortfall rounds up to whole rolls', () {
      expect(MinStock.rollsToOpen(12, 0, 10), 2);
      expect(MinStock.rollsToOpen(11, 1, 10), 1);
    });

    test('an item that does not cut into belts opens nothing', () {
      expect(MinStock.rollsToOpen(5, 0, 0), 0);
    });
  });

  group('How quantities read', () {
    const s = MinStock(itemCode: 'ITEM-1', availableQty: 10);

    test('belts are only mentioned when there are some', () {
      // CTR, bonding gum and solution have no belts, and a permanent
      // "+ 0 belts" on every row is noise.
      expect(s.describe(200, 0, 'kg'), '200 kg');
      expect(s.describe(6, 0, 'cans'), '6 cans');
    });

    test('rolls and belts are spelled out together when both apply', () {
      expect(s.describe(10, 4, 'rolls'), '10 rolls + 4 belts');
      expect(s.describe(4, 1, 'rolls'), '4 rolls + 1 belt');
    });

    test('a fractional quantity survives, a whole one stays clean', () {
      expect(s.describe(8, 0, 'rolls'), '8 rolls');
      expect(s.describe(2.5, 0, 'kg'), '2.50 kg');
    });
  });

  group('Who sees minimum stock', () {
    // Session is a singleton, so each case sets both fields explicitly rather
    // than relying on what the previous test left behind.
    void as({String? company, String? managedTeamCompany}) {
      Session.I.company = company;
      Session.I.managedTeamCompany = managedTeamCompany;
    }

    tearDown(() => as());

    test('a Treads rep sees it', () {
      as(company: kUnitTreads);
      expect(Session.I.isTreadsUnit, isTrue);
    });

    test('Retreads and UAE reps do not', () {
      as(company: kUnitRetreads);
      expect(Session.I.isTreadsUnit, isFalse);
      as(company: kUnitUae);
      expect(Session.I.isTreadsUnit, isFalse);
    });

    test('a manager of a Treads team sees it even without a unit of their own',
        () {
      // Pareeth is himself a Sales Person so he is covered by `company`, but a
      // future manager who is not one would otherwise fall through the gate.
      as(managedTeamCompany: kUnitTreads);
      expect(Session.I.isTreadsUnit, isTrue);
    });

    test('a manager of a Retreads team does not', () {
      as(managedTeamCompany: kUnitRetreads);
      expect(Session.I.isTreadsUnit, isFalse);
    });

    test('a login with no unit at all does not', () {
      as();
      expect(Session.I.isTreadsUnit, isFalse);
    });
  });

  group('Which company an order books into', () {
    // Getting this wrong does not just misfile the order — the two companies
    // carry different currencies, so a rupee order lands in dirhams.
    test('only the UAE unit books into the dirham company', () {
      expect(companyForUnit(kUnitUae), kCompanyUae);
    });

    test('both Indian units book into the rupee company', () {
      expect(companyForUnit(kUnitTreads), kCompanyIndia);
      expect(companyForUnit(kUnitRetreads), kCompanyIndia);
    });

    test('an unknown or missing unit defaults to the Indian company', () {
      // The safer default: the bulk of the business is Indian, and a mistake
      // there does not drag an order through a currency conversion.
      expect(companyForUnit(null), kCompanyIndia);
      expect(companyForUnit(''), kCompanyIndia);
      expect(companyForUnit('Something New'), kCompanyIndia);
    });
  });

  group('Unit filtering', () {
    test('an item with no units set is visible to every unit', () {
      expect(Api.sellsInUnit(null, 'Manna Treads'), isTrue);
      expect(Api.sellsInUnit('', 'Manna Treads'), isTrue);
      // Frappe hands back the literal string for an empty Small Text.
      expect(Api.sellsInUnit('null', 'Manna Treads'), isTrue);
    });

    test('a rep only sees their own unit', () {
      const units = '|Manna Tyre Retreads|Manna Tyres UAE|';
      expect(Api.sellsInUnit(units, 'Manna Tyres UAE'), isTrue);
      expect(Api.sellsInUnit(units, 'Manna Tyre Retreads'), isTrue);
      expect(Api.sellsInUnit(units, 'Manna Treads'), isFalse);
    });

    test('matching ignores case and stray spacing', () {
      expect(Api.sellsInUnit('|manna treads|', ' Manna Treads '), isTrue);
    });

    test('a unit name that is only a prefix does not match', () {
      // The pipes are what make this safe: "Manna Tyres" must not match
      // "Manna Tyres UAE".
      expect(Api.sellsInUnit('|Manna Tyres UAE|', 'Manna Tyres'), isFalse);
    });
  });
}
