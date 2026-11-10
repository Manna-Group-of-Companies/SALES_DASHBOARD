import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/widgets/gm_status.dart';

void main() {
  test('an order the manager escalated shows the rep "Sent to GM"', () {
    expect(gmStatusOf('Pending GM Approval')?.label, 'Sent to GM');
  });

  test('an order the GM approved shows the rep "GM approved"', () {
    expect(gmStatusOf('Pending Final Approval')?.label, 'GM approved');
  });

  test('no GM tag on any other status', () {
    for (final s in ['Pending Approval', 'PO Approved - Ready for SAP', 'Rejected', '']) {
      expect(gmStatusOf(s), isNull, reason: s);
    }
  });
}
