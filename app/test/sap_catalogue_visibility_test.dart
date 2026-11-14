// Which items a Manna Treads order screen offers at all.
// `shared/fixtures/sap_catalogue_visibility.json` states the rule; this file
// asserts the same cases against `sapCatalogueVisible`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/order_rules.dart';

void main() {
  final raw = File('../shared/fixtures/sap_catalogue_visibility.json')
      .readAsStringSync();
  final doc = json.decode(raw) as Map<String, dynamic>;
  final cases = doc['cases'] as List;

  group('shared/fixtures/sap_catalogue_visibility.json', () {
    for (final c in cases) {
      final m = c as Map<String, dynamic>;
      test(m['why'], () {
        final visible = sapCatalogueVisible(
          isTreadsUnit: m['is_treads_unit'] as bool,
          rateUnit: m['rate_unit'] as String,
          ratesAnswered: m['rates_answered'] as bool,
          ratesOffline: m['rates_offline'] as bool,
          anySapRates: m['any_sap_rates'] as bool,
          alreadyOnOrder: m['already_on_order'] as bool,
          hasSapRate: m['has_sap_rate'] as bool,
        );
        expect(visible, m['visible'], reason: m['why'] as String);
      });
    }
  });
}
