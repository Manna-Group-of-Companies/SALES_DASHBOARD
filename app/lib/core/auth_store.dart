
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
class AuthStore {
  static const _kBaseUrl = 'baseUrl';
  static const _kEmail = 'email';
  static const _kSid = 'sid';
  static const _kApiKey = 'apiKey';
  static const _kApiSecret = 'apiSecret';
  static const _kPassword = 'pwd';

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  static Future<Credentials> load() async {
    final p = await _prefs;
    return Credentials(
      baseUrl: p.getString(_kBaseUrl) ?? '',
      email: p.getString(_kEmail) ?? '',
      sid: p.getString(_kSid) ?? '',
      apiKey: p.getString(_kApiKey) ?? '',
      apiSecret: p.getString(_kApiSecret) ?? '',
      password: p.getString(_kPassword) ?? '',
    );
  }

  static Future<String> password() async =>
      (await _prefs).getString(_kPassword) ?? '';

  static Future<void> saveLogin({
    required String baseUrl,
    required String email,
    required String password,
  }) async {
    final p = await _prefs;
    await p.setString(_kBaseUrl, baseUrl);
    await p.setString(_kEmail, email);
    await p.setString(_kPassword, password);
  }

  static Future<void> saveSid(String sid) async =>
      (await _prefs).setString(_kSid, sid);

  static Future<void> saveToken(String apiKey, String apiSecret) async {
    final p = await _prefs;
    await p.setString(_kApiKey, apiKey);
    await p.setString(_kApiSecret, apiSecret);
  }

  /// Drop the long-lived token only. Used when the server rejects it, so the
  /// next call falls back to password auth instead of retrying a dead key.
  static Future<void> clearToken() async {
    final p = await _prefs;
    await p.remove(_kApiKey);
    await p.remove(_kApiSecret);
  }

  /// Full sign-out. Keeps [_kBaseUrl] and [_kEmail] so the login form is
  /// pre-filled the next time round.
  static Future<void> clear() async {
    final p = await _prefs;
    await p.remove(_kSid);
    await p.remove(_kApiKey);
    await p.remove(_kApiSecret);
    await p.remove(_kPassword);
  }
}
