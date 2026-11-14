import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/core/pick_list.dart';

void main() {
  // 14 Nov 2026: the pick list is not released; the live app takes sales
  // orders only. A build made without --dart-define=PICK_LISTS=true must not
  // show it. Fails if someone flips the default without meaning to release.
  test('a build made the usual way hides pick lists', () {
    expect(kPickListsReleased, isFalse);
  });
}
