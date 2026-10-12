
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Everything needed to get the rep back onto an authenticated connection
/// without them typing anything.
class Credentials {
  const Credentials({
    required this.baseUrl,
    required this.email,
    required this.sid,
    required this.apiKey,
    required this.apiSecret,
    required this.password,
  });

  final String baseUrl;
  final String email;
  final String sid;
  final String apiKey;
  final String apiSecret;
  final String password;

  bool get hasToken => apiKey.isNotEmpty && apiSecret.isNotEmpty;
  bool get canReauth => email.isNotEmpty && password.isNotEmpty;
}

/// On-device credential storage.
///
/// The API key/secret pair is the preferred credential: Frappe never expires
/// it, so a rep holding one is never logged out. The password is kept as a
/// fallback for accounts that cannot mint a token (see [Api.provisionToken]) —
/// without it an expired `sid` would drop the rep back on the login screen,
/// which is exactly what we are trying to avoid.
///
/// The four secrets live in the platform's encrypted store (Android Keystore,
/// iOS Keychain). Until October 2026 they sat in SharedPreferences as plain
/// text; a phone still carrying them there has them moved across the first
/// time each is read, so nobody is signed out by the upgrade. If the encrypted
/// store fails on some handset, SharedPreferences is used rather than losing
/// the rep's login — the lock screen (core/app_lock.dart) still stands in front of it.
/// The base URL and email are not secret and stay in SharedPreferences, so the
/// login form can be pre-filled.
class AuthStore {
  static const _kBaseUrl = 'baseUrl';
  static const _kEmail = 'email';
  static const _kSid = 'sid';
  static const _kApiKey = 'apiKey';
  static const _kApiSecret = 'apiSecret';
  static const _kPassword = 'pwd';

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  static const _secure = FlutterSecureStorage();

  static Future<String> _read(String key) async {
    try {
      final v = await _secure.read(key: key);
      if (v != null) return v;
    } catch (_) {
      // Fall through to whatever SharedPreferences holds.
    }
    final p = await _prefs;
    final legacy = p.getString(key);
    if (legacy == null) return '';
    await _write(key, legacy);
    return legacy;
  }

  /// Encrypted when possible; the plain copy is removed only once the
  /// encrypted one is safely written.
  static Future<void> _write(String key, String value) async {
    final p = await _prefs;
    try {
      await _secure.write(key: key, value: value);
      await p.remove(key);
    } catch (_) {
      await p.setString(key, value);
    }
  }

  static Future<void> _remove(String key) async {
    try {
      await _secure.delete(key: key);
    } catch (_) {}
    await (await _prefs).remove(key);
  }

  static Future<Credentials> load() async {
    final p = await _prefs;
    return Credentials(
      baseUrl: p.getString(_kBaseUrl) ?? '',
      email: p.getString(_kEmail) ?? '',
      sid: await _read(_kSid),
      apiKey: await _read(_kApiKey),
      apiSecret: await _read(_kApiSecret),
      password: await _read(_kPassword),
    );
  }

  static Future<String> password() => _read(_kPassword);

  static Future<void> saveLogin({
    required String baseUrl,
    required String email,
    required String password,
  }) async {
    final p = await _prefs;
    await p.setString(_kBaseUrl, baseUrl);
    await p.setString(_kEmail, email);
    await _write(_kPassword, password);
  }

  static Future<void> saveSid(String sid) => _write(_kSid, sid);

  static Future<void> saveToken(String apiKey, String apiSecret) async {
    await _write(_kApiKey, apiKey);
    await _write(_kApiSecret, apiSecret);
  }

  /// Drop the long-lived token only. Used when the server rejects it, so the
  /// next call falls back to password auth instead of retrying a dead key.
  static Future<void> clearToken() async {
    await _remove(_kApiKey);
    await _remove(_kApiSecret);
  }

  /// Full sign-out. Keeps [_kBaseUrl] and [_kEmail] so the login form is
  /// pre-filled the next time round.
  static Future<void> clear() async {
    await _remove(_kSid);
    await _remove(_kApiKey);
    await _remove(_kApiSecret);
    await _remove(_kPassword);
  }
}
