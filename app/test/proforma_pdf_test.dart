// The proforma actually renders, QR and all.
//
// `buildProformaPdf` wraps the real layout in a try/catch and falls back to a
// plain one-page invoice on any exception. That is the right behaviour — a
// rep in a shop needs *a* document — but it means a broken widget produces a
// silently degraded PDF rather than a failure anybody notices. The UPI QR is
// exactly the kind of thing that could throw and never be seen to.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/pdf/proforma_pdf.dart';

void main() {
  final order = {
    'name': 'SAL-ORD-2026-00999',
    'transaction_date': '2026-09-11',
    'customer': 'TEST - Alpha Retreads',
    'items': [
      {
        'item_code': 'I-11672',
        'item_name': 'TREAD RUBBER PRECURED BLACK PEARL 205 SR 130',
        'qty': 3,
        'rate': 570.0,
        'amount': 1710.0,
      }
    ],
  };
  final customer = {
    'customer_name': 'TEST - Alpha Retreads',
    'custom_address': 'Kakkanad, Ernakulam',
    'custom_gstin': '32AAAAA0000A1Z5',
    'territory': 'India',
  };

  test('the full proforma renders rather than falling back', () async {
    final bytes = await buildProformaPdf(
        order: order, customer: customer, isPurchaseOrder: false);

    expect(bytes.isNotEmpty, isTrue);
    // Every PDF starts %PDF-.
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');

    // The fallback page is a fraction of the real one. A QR alone is several
    // kilobytes of vector, so a rich render cannot be this small — this is
    // what catches a silent fall back to the plain layout.
    expect(bytes.length, greaterThan(6000),
        reason: 'looks like the simple fallback, not the full proforma');
  });

  test('a purchase order renders too', () async {
    final bytes = await buildProformaPdf(
        order: order, customer: customer, isPurchaseOrder: true);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('the UPI address is a well-formed VPA', () {
    // Not a validation of WHOSE address it is — that has to be checked against
    // the bank card by a human. This only catches a mangled constant.
    expect(kUpiVpa, matches(RegExp(r'^[\w.\-]+@[A-Za-z]+$')));
    expect(kUpiVpa, 'pos.5126391@indus');
  });
}
