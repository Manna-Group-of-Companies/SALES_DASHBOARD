// Two rules that decide what a rep is shown, and that are easy to get backwards.
//
//  - The minimum-stock list is a *fast-moving* list. Being on it is not a
//    warning; having stopped selling while on it is.
//  - A rep must never be shown another business unit's catalogue, but an item
//    nobody has assigned a unit to yet has to stay visible, or the product list
//    empties the day the field is added.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/services/api.dart';

String _daysAgo(int days) => DateTime.now()
    .subtract(Duration(days: days))
    .toIso8601String()
    .substring(0, 10);

MinStock _pool({required String lastSold, double qty = 10}) => MinStock(
      itemCode: 'ITEM-1',
      minimumQty: qty,
      reservedQty: 0,
      myReservedQty: 0,
      lastSoldOn: lastSold,
    );

void main() {
  group('Dead stock', () {
    test('an item selling this week is just moving', () {
      final s = _pool(lastSold: _daysAgo(3));
      expect(s.daysSinceSold, 3);
      expect(s.isSlowMoving, isFalse);
      expect(s.isDeadStockRisk, isFalse);
    });

    test('a gap past the slow threshold is a nudge, not an alarm', () {
      final s = _pool(lastSold: _daysAgo(kSlowMovingDays + 5));
      expect(s.isSlowMoving, isTrue);
      expect(s.isDeadStockRisk, isFalse);
    });

    test('a gap past the dead threshold is the alarm', () {
      final s = _pool(lastSold: _daysAgo(kDeadStockDays + 1));
      expect(s.isDeadStockRisk, isTrue);
      // Only one badge should ever apply, or the UI shows two states at once.
      expect(s.isSlowMoving, isFalse);
    });

    test('never sold is treated as the worst case, not the best', () {
      final s = _pool(lastSold: '');
      expect(s.daysSinceSold, -1);
      expect(s.isDeadStockRisk, isTrue);
    });

    test('an item with no pool cannot be dead stock', () {
      // Nothing is sitting on the shelf, so there is nothing to write off.
      final s = _pool(lastSold: '', qty: 0);
      expect(s.isDeadStockRisk, isFalse);
    });

    test('a null date from Frappe reads as never sold, not as 1970', () {
      final s = MinStock.fromJson({
        'item_code': 'ITEM-1',
        'minimum_qty': 5,
        'reserved_qty': 0,
        'my_reserved_qty': 0,
        'last_sold_on': null,
      });
      expect(s.lastSoldOn, '');
      expect(s.daysSinceSold, -1);
    });
  });

  group('Availability', () {
    test('what is left is the pool less everyone else booked', () {
      final s = MinStock(
        itemCode: 'ITEM-1',
        minimumQty: 10,
        reservedQty: 4,
        myReservedQty: 1,
        minimumLooseBelts: 8,
        reservedLooseBelts: 3,
      );
      expect(s.availableQty, 6);
      expect(s.availableLooseBelts, 5);
    });

    test('an over-reserved pool reads as empty, never as negative', () {
      final s = MinStock(
        itemCode: 'ITEM-1',
        minimumQty: 10,
        reservedQty: 14,
        myReservedQty: 0,
        minimumLooseBelts: 2,
        reservedLooseBelts: 9,
      );
      expect(s.availableQty, 0);
      expect(s.availableLooseBelts, 0);
    });
  });

  group('How quantities read', () {
    final s = _pool(lastSold: _daysAgo(1));

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
