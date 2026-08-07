// Collapsing a closed week into one row.
//
// The failure that matters is an order vanishing: if a grouped order is
// removed from the list but its combined row is not added, the rep's work is
// simply gone off their screen. The second failure is showing both, which
// counts the same money twice. These pin down both.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/services/api.dart';

Map<String, dynamic> order(String name, {String? group, double amount = 100}) => {
      'name': name,
      'customer': 'A M Logistics',
      'transaction_date': '2026-07-29',
      'grand_total': amount,
      if (group != null) 'custom_combined_order': group,
    };

Map<String, dynamic> head(String name, {int count = 2, double total = 200}) => {
      'name': name,
      'customer': 'A M Logistics',
      'customer_name': 'A M Logistics',
      'week_start': '2026-07-27',
      'week_end': '2026-08-02',
      'status': 'Draft',
      'order_count': count,
      'total_amount': total,
    };

void main() {
  group('collapsing', () {
    test('grouped orders are replaced by their combined order', () {
      final out = Api.collapseIntoWeeks(
        [order('SO-1', group: 'COMB-1'), order('SO-2', group: 'COMB-1')],
        [head('COMB-1')],
      );
      expect(out, hasLength(1));
      expect(out.single['is_combined'], isTrue);
      expect(out.single['name'], 'COMB-1');
      // The members must not also be listed, or the week's money is counted
      // once in the group and again underneath it.
      expect(out.any((r) => r['name'] == 'SO-1'), isFalse);
    });

    test('ungrouped orders are left exactly as they were', () {
      final loose = order('SO-3');
      final out = Api.collapseIntoWeeks(
        [order('SO-1', group: 'COMB-1'), loose],
        [head('COMB-1')],
      );
      expect(out.where((r) => r['name'] == 'SO-3'), hasLength(1));
      expect(out.firstWhere((r) => r['name'] == 'SO-3')['is_combined'], isNull);
    });

    test('nothing grouped means nothing changes', () {
      final rows = [order('SO-1'), order('SO-2')];
      expect(Api.collapseIntoWeeks(rows, const []), rows);
    });

    test('an order is never lost when its combined order cannot be read', () {
      // The degraded case: the group header is missing or unreadable. The
      // member must stay on the list — a rep seeing an ungrouped order is a
      // worse list, but a rep seeing neither has lost work off their screen.
      final out = Api.collapseIntoWeeks(
        [order('SO-1', group: 'COMB-MISSING')],
        const [],
      );
      expect(out, hasLength(1));
      expect(out.single['name'], 'SO-1');
    });

    test('only the groups that were read are collapsed', () {
      final out = Api.collapseIntoWeeks(
        [order('SO-1', group: 'COMB-1'), order('SO-2', group: 'COMB-GONE')],
        [head('COMB-1')],
      );
      expect(out.map((r) => r['name']).toSet(), {'COMB-1', 'SO-2'});
    });

    test('a combined row carries the totals from its header, not its members',
        () {
      // The header counts every order in the week, including any raised by
      // another rep. A rep looking at their customer's week sees the whole
      // week, not just their own share of it.
      final out = Api.collapseIntoWeeks(
        [order('SO-1', group: 'COMB-1', amount: 100)],
        [head('COMB-1', count: 3, total: 999)],
      );
      expect(out.single['grand_total'], 999);
      expect(out.single['order_count'], 3);
    });

    test('a combined row sorts by the week it closed', () {
      // It is mapped onto transaction_date so it sorts beside ordinary orders
      // rather than falling to the bottom with a blank date.
      final out = Api.collapseIntoWeeks(
        [order('SO-1', group: 'COMB-1')],
        [head('COMB-1')],
      );
      expect(out.single['transaction_date'], '2026-08-02');
    });

    test('a blank or null group is not a group', () {
      // Frappe writes an unset Link both ways; either must read as ungrouped
      // rather than as a group whose header will never be found.
      for (final g in ['', '   ', 'null']) {
        final out = Api.collapseIntoWeeks(
            [order('SO-1', group: g)], [head('COMB-1')]);
        final so = out.where((r) => r['name'] == 'SO-1');
        expect(so, hasLength(1), reason: 'group "$g" should stay ungrouped');
        expect(so.single['is_combined'], isNull, reason: 'group "$g"');
      }
    });

    test('lead orders are never swept into a week', () {
      final lead = {
        'name': 'LO-1',
        'is_lead': true,
        'customer': 'Some Lead',
        'transaction_date': '2026-07-29',
      };
      final out = Api.collapseIntoWeeks(
          [order('SO-1', group: 'COMB-1'), lead], [head('COMB-1')]);
      expect(out.any((r) => r['name'] == 'LO-1'), isTrue);
    });
  });
}
