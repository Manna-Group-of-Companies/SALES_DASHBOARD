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

    test('the freight reads as chosen', () {
      expect(deliveryModeLabel(kDeliveryPaid), 'Paid');
      expect(deliveryModeLabel(kDeliveryToPay), 'To Pay');
    });

    test('mode of delivery is By Road, By KSRTC or By Railway', () {
      expect(kTransportModes, ['By Road', 'By KSRTC', 'By Railway']);
      expect(transportModeOf('By KSRTC'), kByKsrtc);
      expect(transportModeOf(' By Railway '), kByRailway);
    });

    test('an unknown mode of delivery asks again rather than guess', () {
      for (final v in [null, '', 'null', 'by road', 'Courier', 'Paid']) {
        expect(transportModeOf(v), isNull, reason: '$v');
      }
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
