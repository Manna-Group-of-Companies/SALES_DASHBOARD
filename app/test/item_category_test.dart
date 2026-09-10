// Which family a product belongs to, when the item group no longer says.
//
// The SAP FG import of 10 September 2026 replaced the catalogue with 1,656
// items in groups called `FG`, `FG - TRP - Black Pearl` and `HOT`. None match
// the four group names this app knew, so every one fell to `other` — and an
// `other` product is missing from every type dropdown, prices by no rule, and
// never reaches the dialog that lets a rep fill in its weights.
//
// The names below are taken verbatim from the live master.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/models/product_category.dart';

void main() {
  ProductCategory of(String name, String group) =>
      categoryOfItem(itemName: name, itemGroup: group);

  group('the FG catalogue', () {
    test('hot-process tread rubber is conventional, not other', () {
      // 206 in the HOT group, another ~254 sitting in FG.
      expect(of('TREAD RUBBER  HOT BLACK PEARL    32*12', 'HOT'),
          ProductCategory.ctr);
      expect(of('TREAD RUBBER  HOT PLATINUM    34*14', 'FG'), ProductCategory.ctr);
      expect(of('TREAD RUBBER  HOT POLYMER 40*15', 'FG'), ProductCategory.ctr);
    });

    test('each of the six precured grade groups reads as precured', () {
      for (final g in [
        'FG - TRP - Black Pearl',
        'FG - TRP - Black Pearl B',
        'FG - TRP - Diamond',
        'FG - TRP - Platinum',
        'FG - TRP - Polygold',
        'FG - TRP - Silver',
      ]) {
        expect(of('TREAD RUBBER  PRECURED SOMETHING 215', g), ProductCategory.pctr,
            reason: g);
      }
    });

    test('precured wins when a name carries both words', () {
      // Getting this precedence backwards would reclassify 1,141 items.
      expect(of('TREAD RUBBER PRECURED HOT SOMETHING', 'FG'), ProductCategory.pctr);
    });

    test('solutions and gums are still found', () {
      expect(of('RUBBER VULCANISING SOLUTION 30LTR', 'FG'),
          ProductCategory.vulcanizingSolution);
      expect(of('VULCANISING SOLUTION  READY TO USE 10L', 'FG'),
          ProductCategory.vulcanizingSolution);
      expect(of('BONDING GUM', 'FG'), ProductCategory.bondingGum);
    });

    test('genuinely uncategorisable items stay other rather than guessing', () {
      // A wrong category prices a line by the wrong rule. Refusing is safer.
      for (final n in ['TYRE RETREADING TOOLS', 'UTS 30*6', 'RUBBER STRIPS']) {
        expect(of(n, 'FG'), ProductCategory.other, reason: n);
      }
    });
  });

  group('the word boundaries are load-bearing', () {
    test('hot does not match inside another word', () {
      // Without \b, "PHOTO" is conventional tread rubber.
      expect(of('PHOTO BOOTH SPARE', 'FG'), ProductCategory.other);
      expect(of('SHOTCRETE NOZZLE', 'FG'), ProductCategory.other);
    });

    test('ctr does not match inside another word', () {
      expect(of('SPECTRA GAUGE', 'FG'), ProductCategory.other);
    });

    test('gum does not match inside another word', () {
      expect(of('CHEWING GUMBO MIX', 'FG'), ProductCategory.other);
    });
  });

  group('the old group names still win outright', () {
    test('a known group is trusted over the name', () {
      // The 662 pre-existing items keep working exactly as before.
      expect(categoryOfItem(itemGroup: 'PRECURED', itemName: 'anything'),
          ProductCategory.pctr);
      expect(categoryOfItem(itemGroup: 'HOT RUBBER', itemName: 'anything'),
          ProductCategory.ctr);
      expect(categoryOfItem(itemGroup: 'BONDING GUM', itemName: 'x'),
          ProductCategory.bondingGum);
      expect(categoryOfItem(itemGroup: 'VULCANIZING SOLUTION', itemName: 'x'),
          ProductCategory.vulcanizingSolution);
    });
  });
}
