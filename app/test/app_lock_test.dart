// The fingerprint / screen-lock gate in front of the saved ERPNext login, and
// the encrypted store that login now lives in.
//
// The properties that matter: a rep already signed in is never logged out by
// the upgrade, the plain-text password does not survive it, and the lock
// comes back after a long absence but not a quick trip to the camera.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/app_lock.dart';
import 'package:manna_field_sales/core/auth_store.dart';
import 'package:manna_field_sales/core/session.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppLock.resetForTest();
    Session.I.clearAuth();
  });

  group('AuthStore', () {
    test('a login saved by an older build carries over, and leaves plain text',
        () async {
      SharedPreferences.setMockInitialValues({
        'baseUrl': 'https://mannarubber.m.frappe.cloud',
        'email': 'rep@mannarubber.com',
        'sid': 'abc123',
        'pwd': 'old-password',
      });

      final c = await AuthStore.load();
      expect(c.email, 'rep@mannarubber.com');
      expect(c.sid, 'abc123');
      expect(c.password, 'old-password');
      expect(c.canReauth, isTrue);

      final p = await SharedPreferences.getInstance();
      expect(p.getString('pwd'), isNull);
      expect(p.getString('sid'), isNull);
      // Not secret; still there to pre-fill the login form.
      expect(p.getString('email'), 'rep@mannarubber.com');

      const secure = FlutterSecureStorage();
      expect(await secure.read(key: 'pwd'), 'old-password');
      expect(await AuthStore.password(), 'old-password');
    });

    test('a fresh login is written encrypted, never as plain text', () async {
      await AuthStore.saveLogin(
          baseUrl: 'https://x', email: 'a@b.c', password: 'secret');
      await AuthStore.saveToken('key', 'sec');

      final p = await SharedPreferences.getInstance();
      expect(p.getString('pwd'), isNull);
      expect(p.getString('apiSecret'), isNull);
      final c = await AuthStore.load();
      expect(c.password, 'secret');
      expect(c.hasToken, isTrue);
    });

    test('sign-out removes every secret but keeps the email', () async {
      await AuthStore.saveLogin(
          baseUrl: 'https://x', email: 'a@b.c', password: 'secret');
      await AuthStore.saveSid('s');
      await AuthStore.clear();

      final c = await AuthStore.load();
      expect(c.password, isEmpty);
      expect(c.sid, isEmpty);
      expect(c.canReauth, isFalse);
      expect(c.email, 'a@b.c');
    });
  });

  group('AppLock', () {
    test('a short absence does not re-lock; a long one does', () {
      expect(AppLock.shouldRelock(const Duration(seconds: 30)), isFalse);
      expect(AppLock.shouldRelock(const Duration(minutes: 4)), isFalse);
      expect(AppLock.shouldRelock(AppLock.relockAfter), isTrue);
      expect(AppLock.shouldRelock(const Duration(hours: 3)), isTrue);
    });

    test('coming straight back to a signed-in app leaves it open', () {
      Session.I.sid = 'abc';
      AppLock.onBackgrounded();
      AppLock.onResumed();
      expect(AppLock.locked.value, isFalse);
    });

    test('a resume with nothing recorded in the background does not lock', () {
      Session.I.sid = 'abc';
      AppLock.onResumed();
      expect(AppLock.locked.value, isFalse);
    });

    test('the stored ERPNext password unlocks; anything else does not',
        () async {
      await AuthStore.saveLogin(
          baseUrl: 'https://x', email: 'a@b.c', password: 'right');
      AppLock.lock();

      expect(await AppLock.unlockWithPassword('wrong'), isFalse);
      expect(AppLock.locked.value, isTrue);
      expect(await AppLock.unlockWithPassword(''), isFalse);

      expect(await AppLock.unlockWithPassword('right'), isTrue);
      expect(AppLock.locked.value, isFalse);
    });

    test('with no stored password, the password route is shut', () async {
      AppLock.lock();
      expect(await AppLock.unlockWithPassword(''), isFalse);
      expect(AppLock.locked.value, isTrue);
    });
  });
}
