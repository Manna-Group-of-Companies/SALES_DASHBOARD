import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/core/delivery_mode.dart';
import 'package:manna_field_sales/core/session.dart';

void main() {
  group('mode of delivery (14 Nov 2026)', () {
    test('only Paid and To Pay count as a choice', () {
      expect(deliveryModeOf('Paid'), kDeliveryPaid);
      expect(deliveryModeOf(' To Pay '), kDeliveryToPay);
    });

    test('an unset or unknown value asks the rep again rather than guess', () {
      for (final v in [null, '', 'null', 'paid', 'Free', 0]) {
        expect(deliveryModeOf(v), isNull, reason: '$v');
      }
    });

    test('both choices read as courier on screen', () {
      expect(deliveryModeLabel(kDeliveryPaid), 'Courier - Paid');
      expect(deliveryModeLabel(kDeliveryToPay), 'Courier - To Pay');
    });
  });

  group('whose customers a login sees', () {
    final s = Session.I;
    setUp(() {
      s.unitPeers = [];
      s.teamReps = [];
      s.managedTeam = null;
    });
    tearDown(() {
      s.unitPeers = [];
      s.teamReps = [];
      s.managedTeam = null;
    });

    test('a rep sees their own', () {
      s.unitPeers = ['Amjad Pr'];
      expect(s.visibleOwners, ['Amjad Pr']);
      expect(s.seesOthers, isFalse);
    });

    test("a manager who is a rep sees their whole team's", () {
      s.unitPeers = ['Pareeth Kb'];
      s.managedTeam = 'Pareeth';
      s.teamReps = ['Amjad Pr', 'Jaimon D', 'Pareeth Kb'];
      expect(s.visibleOwners.toSet(), {'Amjad Pr', 'Jaimon D', 'Pareeth Kb'});
      expect(s.visibleOwners.length, 3, reason: 'no one twice');
      expect(s.seesOthers, isTrue);
    });

    test('a login that is no rep sees nothing, never everyone', () {
      s.managedTeam = 'Pareeth';
      s.teamReps = ['Amjad Pr'];
      expect(s.visibleOwners, isEmpty);
    });
  });
}
