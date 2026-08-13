// Discounts a sales manager gives at approval.
//
// This decides what a customer is invoiced, and there is no Server Script
// behind it to catch a mistake. The rules that matter: a discount always comes
// off the rep's original rate and never off an already discounted one, the
// lines always add up to the total shown under them, and once an order is
// approved nothing can move.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/discount.dart';
import 'package:manna_field_sales/core/order_rules.dart';

Map<String, dynamic> soLine({
  double qty = 8,
  double rate = 7344,
  double? priceListRate,
  double? pct,
  double? amount,
}) =>
    {
      'name': 'row1',
      'qty': qty,
      'rate': rate,
      if (priceListRate != null) 'price_list_rate': priceListRate,
      if (pct != null) 'discount_percentage': pct,
      if (amount != null) 'amount': amount,
    };

Map<String, dynamic> leadLine({
  double qty = 8,
  double rate = 7344,
  double? priceListRate,
  double? pct,
  double? amount,
}) =>
    {
      'name': 'row1',
      'qty': qty,
      'rate': rate,
      if (priceListRate != null) 'custom_price_list_rate': priceListRate,
      if (pct != null) 'custom_discount_percentage': pct,
      if (amount != null) 'amount': amount,
    };

void main() {
  group('the discounted rate', () {
    test('ten percent off comes off the quoted rate', () {
      expect(discountedRate(7344, 10), 6609.60);
    });

    test('no discount leaves the rate alone', () {
      expect(discountedRate(7344, 0), 7344);
    });

    test('a rate that will not divide evenly is held to paise', () {
      // 216 x 0.925 = 199.8 exactly, but 7344 x 0.925 = 6793.2. The point is
      // that nothing carries more precision than money has.
      expect(discountedRate(216, 7.5), 199.80);
      expect(discountedRate(1000, 33.33), 666.70);
    });
  });

  group('a line already discounted', () {
    test('a second discount still comes off the original rate', () {
      // The trap this whole design exists to avoid. Discounting the already
      // discounted rate turns 10% given twice into 19%, and the rep's quoted
      // rate is gone for good after the first save.
      final once = soLine(priceListRate: 7344, pct: 10, rate: 6609.60);
      final twice =
          discountFields(item: once, percent: 10, isLead: false);
      expect(twice['rate'], 6609.60);
      expect(twice['price_list_rate'], 7344);
    });

    test('raising the discount reprices off the original, not the discounted',
        () {
      final once = soLine(priceListRate: 7344, pct: 10, rate: 6609.60);
      final more = discountFields(item: once, percent: 20, isLead: false);
      expect(more['rate'], 5875.20);
    });

    test('removing a discount puts the original rate back', () {
      final once = soLine(priceListRate: 7344, pct: 10, rate: 6609.60);
      final off = discountFields(item: once, percent: 0, isLead: false);
      expect(off['rate'], 7344);
      expect(off['discount_percentage'], 0);
    });
  });

  group('where the two numbers live', () {
    test('a sales order line uses the standard ERPNext fields', () {
      final f = discountFields(item: soLine(), percent: 10, isLead: false);
      expect(f.containsKey('price_list_rate'), isTrue);
      expect(f.containsKey('discount_percentage'), isTrue);
      expect(f.containsKey('custom_discount_percentage'), isFalse);
    });

    test('a lead order line uses the custom ones', () {
      // `Lead Order Item` is our own child table and has no standard pricing
      // fields at all.
      final f = discountFields(item: leadLine(), percent: 10, isLead: true);
      expect(f.containsKey('custom_price_list_rate'), isTrue);
      expect(f.containsKey('custom_discount_percentage'), isTrue);
      expect(f.containsKey('discount_percentage'), isFalse);
    });

    test('both spellings read back the same way', () {
      expect(discountPercentOf(soLine(pct: 10)), 10);
      expect(discountPercentOf(leadLine(pct: 10)), 10);
      expect(rateBeforeDiscount(soLine(priceListRate: 7344, rate: 6609.6)),
          7344);
      expect(rateBeforeDiscount(leadLine(priceListRate: 7344, rate: 6609.6)),
          7344);
    });
  });

  group('an order taken before discounts existed', () {
    test('reads as full price, never as free', () {
      // Every line on the site today has price_list_rate = 0. Reading that as
      // the pre-discount rate would show every historic order as a 100%
      // discount off nothing.
      final old = soLine(rate: 7344, amount: 58752);
      expect(rateBeforeDiscount(old), 7344);
      expect(lineBeforeDiscount(old), 58752);
      expect(isDiscounted(old), isFalse);
    });

    test('its total is the same both ways', () {
      final t = discountTotals([soLine(rate: 7344, amount: 58752)]);
      expect(t.beforeDiscount, 58752);
      expect(t.afterDiscount, 58752);
      expect(t.discount, 0);
      expect(t.hasDiscount, isFalse);
    });
  });

  group('the order totals', () {
    test('the two totals and the discount between them agree', () {
      final t = discountTotals([
        soLine(qty: 8, priceListRate: 7344, pct: 10, rate: 6609.60,
            amount: 52876.80),
        soLine(qty: 2, rate: 1000, amount: 2000),
      ]);
      expect(t.beforeDiscount, 60752);
      expect(t.afterDiscount, 54876.80);
      expect(t.discount, 5875.20);
      // What the manager reads across the three rows must reconcile by eye.
      expect(t.beforeDiscount - t.discount, t.afterDiscount);
    });

    test('only the discounted lines are counted as discounted', () {
      final t = discountTotals([
        soLine(priceListRate: 7344, pct: 10, rate: 6609.60, amount: 52876.80),
        soLine(rate: 1000, qty: 2, amount: 2000),
      ]);
      expect(t.discountedLines, 1);
    });

    test('an order with nothing off reports no discount', () {
      final t = discountTotals([soLine(amount: 58752)]);
      expect(t.hasDiscount, isFalse);
    });

    test('an empty order is zero rather than an error', () {
      final t = discountTotals(const []);
      expect(t.beforeDiscount, 0);
      expect(t.afterDiscount, 0);
      expect(t.hasDiscount, isFalse);
    });
  });

  group('what will not be allowed', () {
    test('a negative discount is refused', () {
      expect(discountRefusal(-5), isNotNull);
    });

    test('more than everything is refused', () {
      expect(discountRefusal(120), isNotNull);
    });

    test('a fat finger past the cap is refused, and says so', () {
      // 100 typed into a percentage box is an order given away.
      final why = discountRefusal(100);
      expect(why, isNotNull);
      expect(why, contains('general manager'));
    });

    test('an ordinary discount is allowed', () {
      expect(discountRefusal(0), isNull);
      expect(discountRefusal(10), isNull);
      expect(discountRefusal(kMaxDiscountPercent), isNull);
    });
  });

  group('percent off a rate', () {
    test('is the inverse of applying it', () {
      expect(percentOff(7344, 6609.60), 10);
    });

    test('a rate that went up is not a negative discount', () {
      // Showing "-8% discount" would read as a discount rather than its
      // opposite.
      expect(percentOff(1000, 1080), 0);
    });

    test('nothing to discount from is zero, not infinity', () {
      expect(percentOff(0, 0), 0);
    });
  });

  group('once approved, nothing moves', () {
    test('an approved customer order is signed off', () {
      expect(
          orderSignedOff({'custom_po_status': 'PO Approved - Ready for SAP'},
              isLead: false),
          isTrue);
    });

    test('an approved lead order is signed off too', () {
      // A lead order has no custom_po_status. Asking the wrong field read every
      // lead order as still open, which would have let a discount be changed
      // after approval on exactly the orders that then become real ones.
      expect(orderSignedOff({'status': 'Approved'}, isLead: true), isTrue);
    });

    test('a pending order is not', () {
      expect(
          orderSignedOff({'custom_po_status': 'Pending Approval'},
              isLead: false),
          isFalse);
      expect(
          orderSignedOff({'status': 'Pending Approval'}, isLead: true),
          isFalse);
    });

    test('a locked rate counts as signed off whatever the status says', () {
      expect(orderSignedOff({'custom_rate_approved': 1}, isLead: false),
          isTrue);
      expect(orderSignedOff({'custom_rate_approved': 1}, isLead: true), isTrue);
    });
  });
}
