// Which syncs a login's Sync button asks for — decided 25 September 2026.
// Until then only the Manna Treads side could refresh stock and credit, so the
// GM approved on credit figures nobody he could ask had refreshed. The same
// cases as client/src/domain/__tests__/syncScope.test.ts.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/sync_scope.dart';

void main() {
  group('who refreshes what', () {
    test('a Manna Treads rep or manager refreshes everything', () {
      expect(syncsForLogin(salesCompany: 'Manna Treads'),
          [SyncKind.orders, SyncKind.stock, SyncKind.credit]);
    });

    test('the GM refreshes everything — he approves on credit and stock', () {
      expect(syncsForLogin(isGM: true),
          [SyncKind.orders, SyncKind.stock, SyncKind.credit]);
    });

    test('a Treads production login refreshes orders and stock, not credit',
        () {
      expect(syncsForLogin(productionUnit: 'Manna Treads'),
          [SyncKind.orders, SyncKind.stock]);
    });

    test("another unit's login refreshes orders only", () {
      expect(syncsForLogin(salesCompany: 'Manna Tyre Retreads'),
          [SyncKind.orders]);
      expect(syncsForLogin(productionUnit: 'Manna Tyre Retreads'),
          [SyncKind.orders]);
    });

    test("a login's own sales company outranks the unit it runs", () {
      // Renjith: production manager AND the UAE sales team's manager.
      expect(
          syncsForLogin(
              salesCompany: 'Manna Tyres UAE', productionUnit: 'Manna Treads'),
          [SyncKind.orders]);
    });
  });
}
