// An order cannot be taken without a delivery route.
//
// Production is never told who a customer is — the route stands in for the
// destination entirely. These pin down what counts as "has a route", because
// Frappe writes an unset Link as null on one path and '' on another, and a
// check that recognised only one of them would let half the routeless orders
// through.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/models/order_ref.dart';
import 'package:manna_field_sales/services/api.dart';

void main() {
  group('a party has a route', () {
    test('a customer on a route can be ordered from', () {
      final p = OrderParty.customer(
          {'name': 'A M Logistics', 'custom_sales_route': 'Jaimon D - Aluva'});
      expect(p.hasRoute, isTrue);
      expect(p.salesRoute, 'Jaimon D - Aluva');
    });

    test('a lead on a route can be ordered from', () {
      final p = OrderParty.lead(
          {'name': 'CRM-LEAD-1', 'custom_sales_route': 'Bibin Balaravi - Idukki'});
      expect(p.hasRoute, isTrue);
    });
  });

  group('a party has no route', () {
    test('a missing field is no route', () {
      expect(OrderParty.customer({'name': 'Aaliya Trans'}).hasRoute, isFalse);
    });

    test('null is no route', () {
      // What the REST API actually returns for an unset Link.
      expect(
          OrderParty.customer(
              {'name': 'X', 'custom_sales_route': null}).hasRoute,
          isFalse);
    });

    test('the string "null" is no route', () {
      // What string interpolation of a null makes of it, and the reason this
      // check exists as one function rather than being retyped per screen.
      expect(
          OrderParty.customer(
              {'name': 'X', 'custom_sales_route': 'null'}).hasRoute,
          isFalse);
    });

    test('empty and whitespace are no route', () {
      expect(
          OrderParty.customer({'name': 'X', 'custom_sales_route': ''}).hasRoute,
          isFalse);
      expect(
          OrderParty.customer(
              {'name': 'X', 'custom_sales_route': '   '}).hasRoute,
          isFalse);
    });

    test('a territory is not a route', () {
      // The bug this rule came from: every customer sits in the territory
      // "India", and the floor was shown "India (no route set)" as though it
      // were somewhere to drive.
      final p = OrderParty.customer({'name': 'X', 'territory': 'India'});
      expect(p.hasRoute, isFalse);
    });
  });

  group('what production is told', () {
    test('a route is passed through as the destination', () {
      expect(Api.destinationOf({'custom_sales_route': 'Jaimon D - Aluva'}),
          'Jaimon D - Aluva');
    });

    test('territory never stands in for a route', () {
      // A plausible wrong answer is worse than a blank: "India" reads like a
      // destination and sorts like one, but no van can be sent to it.
      final d = Api.destinationOf({'territory': 'India'});
      expect(d, 'No route set');
      expect(d, isNot(contains('India')));
    });

    test('an unset route reads as unset however it was stored', () {
      for (final v in [null, '', '   ', 'null']) {
        expect(Api.destinationOf({'custom_sales_route': v}), 'No route set',
            reason: 'stored as ${v.runtimeType} "$v"');
      }
    });
  });
}
