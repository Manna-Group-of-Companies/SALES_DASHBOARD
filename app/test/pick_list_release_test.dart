import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/core/pick_list.dart';

void main() {
  // 16 Nov 2026: the pick list is released in the live app (hidden 14-16 Nov).
  // A build made the usual way shows it; --dart-define=PICK_LISTS=false hides
  // it again. Fails if the default is flipped back without meaning to.
  test('a build made the usual way shows pick lists', () {
    expect(kPickListsReleased, isTrue);
  });
}
