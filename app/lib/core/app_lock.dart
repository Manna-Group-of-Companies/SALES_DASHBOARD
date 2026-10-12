import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

import 'package:manna_field_sales/core/auth_store.dart';
import 'package:manna_field_sales/core/session.dart';

/// What came of one attempt to unlock.
enum UnlockOutcome {
  /// The phone confirmed it is the owner.
  unlocked,

  /// The rep dismissed the prompt or the finger did not match. Ask again.
  declined,

  /// Too many failed attempts; the phone will refuse for a while.
  lockedOut,

  /// The phone has no screen lock and no fingerprint, so there is nothing to
  /// check against. The app is let through rather than shutting the rep out.
  unavailable,
}

/// The phone's own fingerprint, face or screen lock standing in front of the
/// app, in place of typing the ERPNext password.
///
/// The password itself has not gone away. It is still what signs the app in
/// to ERPNext, silently, from the encrypted store (see [AuthStore]); this only
/// decides whether the person holding the phone may use that stored login.
///
/// Caveat worth knowing: Android cannot say *whose* finger it was, only that
/// it is one enrolled on this phone. It stops a passer-by or a lost phone, not
/// a rep who lets someone else enrol a finger.
class AppLock {
  AppLock._();

  /// How long the app may sit in the background before it asks again. Short
  /// trips out — the camera for an odometer photo, a phone call — do not.
  static const relockAfter = Duration(minutes: 5);

  /// True while the lock screen should cover the app.
  static final locked = ValueNotifier<bool>(false);

  static final _auth = LocalAuthentication();
  static DateTime? _backgroundedAt;
  static bool _authenticating = false;

  static bool shouldRelock(Duration away) => away >= relockAfter;

  /// Only a phone that is signed in has anything to protect.
  static bool get _signedIn => Session.I.hasToken || Session.I.sid.isNotEmpty;

  /// Cover the app. Called at start-up when a saved login is about to be used.
  static void lock() => locked.value = true;

  /// Uncover without asking — after a typed password, or when the saved login
  /// turned out to be dead and the login form is what comes next anyway.
  static void release() {
    locked.value = false;
    _backgroundedAt = null;
  }

  static void onBackgrounded() {
    // The PIN/pattern screen is its own Android activity, so asking for it
    // sends the app to the background. That must not count.
    if (_authenticating || locked.value) return;
    _backgroundedAt = DateTime.now();
  }

  static void onResumed() {
    final at = _backgroundedAt;
    _backgroundedAt = null;
    if (at == null || _authenticating || !_signedIn) return;
    if (shouldRelock(DateTime.now().difference(at))) lock();
  }

  /// Ask the phone. Falls back to its PIN, pattern or password on its own if
  /// there is no fingerprint, or the rep prefers it.
  static Future<UnlockOutcome> unlock() async {
    if (_authenticating) return UnlockOutcome.declined;
    _authenticating = true;
    try {
      if (!await _auth.isDeviceSupported()) {
        release();
        return UnlockOutcome.unavailable;
      }
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock Manna Field Sales',
        persistAcrossBackgrounding: true,
      );
      if (ok) release();
      return ok ? UnlockOutcome.unlocked : UnlockOutcome.declined;
    } on LocalAuthException catch (e) {
      switch (e.code) {
        case LocalAuthExceptionCode.noCredentialsSet:
        case LocalAuthExceptionCode.noBiometricHardware:
        case LocalAuthExceptionCode.noBiometricsEnrolled:
          release();
          return UnlockOutcome.unavailable;
        case LocalAuthExceptionCode.temporaryLockout:
        case LocalAuthExceptionCode.biometricLockout:
          return UnlockOutcome.lockedOut;
        default:
          return UnlockOutcome.declined;
      }
    } catch (_) {
      return UnlockOutcome.declined;
    } finally {
      _authenticating = false;
    }
  }

  /// The way in when the phone's own check will not do: the ERPNext password,
  /// compared against the one already stored. Works offline.
  static Future<bool> unlockWithPassword(String typed) async {
    final saved = await AuthStore.password();
    if (saved.isEmpty || typed != saved) return false;
    release();
    return true;
  }

  @visibleForTesting
  static void resetForTest() {
    locked.value = false;
    _backgroundedAt = null;
    _authenticating = false;
  }
}
