import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/core/credit.dart';

void main() {
  group('total outstanding on the customer list (14 Nov 2026)', () {
    test('adds each customer as their own page counts them', () {
      final customers = [
        {kFieldOutstandingTotal: 15868},
        // Buckets arrived but the total did not: the buckets count.
        {kFieldOutstandingTotal: 0, kFieldOutstanding0_30: 263, kFieldOutstanding60_90: 149036},
        {kFieldOutstandingTotal: 0},
      ];
      expect(totalOutstanding(customers), 15868 + 263 + 149036);
    });

    test('a customer in credit takes off what they hold', () {
      expect(
          totalOutstanding([
            {kFieldOutstandingTotal: 1000},
            {kFieldOutstandingTotal: -250},
          ]),
          750);
    });

    test('no customers owe nothing', () {
      expect(totalOutstanding(const []), 0);
    });
  });

  group('rupees with Indian grouping', () {
    test('lakhs and crores group in twos after the first three', () {
      expect(inr(0), '₹0');
      expect(inr(530), '₹530');
      expect(inr(15868), '₹15,868');
      expect(inr(149645), '₹1,49,645');
      expect(inr(12345678), '₹1,23,45,678');
    });

    test('whole rupees, and a credit keeps its sign', () {
      expect(inr(1999.6), '₹2,000');
      expect(inr(-47144), '-₹47,144');
    });
  });
}
