// Keeping the app usable where the signal is not.
//
// WHAT THIS DOES AND DOES NOT COVER
//
// Reads are cached. A rep who walks into a shed with no bars can still pull up
// the customer, their outstanding balance, the product list and where the
// minimum stock stood at the last sync. That is most of what a rep needs a
// phone for at a counter, and it is safe because none of it changes the world.
//
// Writes are not queued, and that is a decision rather than an omission. An
// order that draws on minimum stock is only real once the pool has been
// decremented, and the pool lives on the server. Accepting an order offline
// would mean telling a rep "saved" while another rep, in signal, takes the last
// rolls out from under them — the customer is promised stock that was gone
// before the promise was made. A refusal at the counter is recoverable; a
// confirmation that silently turns into a shortage is not. Order drafts are
// held locally instead (see `pending_orders.dart`) and marked plainly as not
// sent, so nothing is lost and nothing is claimed.
//
// EVERY CACHED READ CARRIES ITS AGE
//
// A stale figure shown as though it were live is worse than no figure. So a
// cached answer always arrives with when it was fetched, and screens say so.
// A rep quoting a credit limit needs to know whether it is from this morning
// or from Tuesday.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/utils.dart';

/// A value plus the story of where it came from.
class Cached<T> {
  final T value;

  /// When the server last answered. Null when this is a live result.
  final DateTime? fetchedAt;

  /// True when the network failed and this is the last good copy.
  final bool stale;

  const Cached(this.value, {this.fetchedAt, this.stale = false});

  /// How old the data is, in plain words, for a screen to show. Empty when
  /// live — there is nothing worth saying about fresh data.
  String get ageLabel {
    if (!stale || fetchedAt == null) return '';
    final mins = serverNow().difference(fetchedAt!).inMinutes;
    if (mins < 1) return 'Offline — showing data from a moment ago';
    if (mins < 60) return 'Offline — showing data from $mins min ago';
    final hours = mins ~/ 60;
    if (hours < 24) {
      return 'Offline — showing data from $hours hour'
          '${hours == 1 ? '' : 's'} ago';
    }
    final days = hours ~/ 24;
    return 'Offline — showing data from $days day${days == 1 ? '' : 's'} ago';
  }
}

/// Read-through cache over the JSON the API returns.
class OfflineCache {
  static const _prefix = 'cache:';

  /// Cached copies older than this are not served even when offline. A price
  /// list from last month is not a useful answer to "what does this cost" —
  /// better to say the app does not know.
  static const Duration maxAge = Duration(days: 7);

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  /// Runs [fetch], caching what comes back under [key].
  ///
  /// On a network failure the last good copy is returned instead, marked
  /// stale. Anything else — a rejected request, a permission error — is
  /// rethrown: those mean the request was wrong, and answering them from cache
  /// would hide a real problem behind old data.
  static Future<Cached<T>> read<T>(
    String key,
    Future<T> Function() fetch, {
    required T Function(dynamic json) decode,
    dynamic Function(T value)? encode,
  }) async {
    try {
      final live = await fetch();
      await write(key, encode != null ? encode(live) : live);
      return Cached(live);
    } catch (e) {
      if (!isOffline(e)) rethrow;
      final fallback = await peek<T>(key, decode);
      if (fallback == null) rethrow;
      return fallback;
    }
  }

  /// The cached copy, without touching the network. Null when there is none,
  /// or it is past [maxAge], or it cannot be decoded.
  static Future<Cached<T>?> peek<T>(
      String key, T Function(dynamic json) decode) async {
    try {
      final raw = (await _prefs).getString('$_prefix$key');
      if (raw == null || raw.isEmpty) return null;

      final envelope = jsonDecode(raw);
      if (envelope is! Map) return null;

      final at = DateTime.tryParse('${envelope['at'] ?? ''}');
      if (at == null) return null;
      if (serverNow().difference(at) > maxAge) return null;

      return Cached(decode(envelope['data']), fetchedAt: at, stale: true);
    } catch (_) {
      // A cache that cannot be read is a cache miss, never an error worth
      // showing a rep.
      return null;
    }
  }

  static Future<void> write(String key, dynamic data) async {
    try {
      final raw = jsonEncode({
        'at': serverNow().toIso8601String(),
        'data': data,
      });
      await (await _prefs).setString('$_prefix$key', raw);
    } catch (_) {
      // Not worth failing a successful fetch over. Encoding can fail on a
      // payload holding something jsonEncode does not understand.
    }
  }

  /// Drops everything cached. Called on sign-out so one rep's customers are
  /// never served to the next person to use the handset.
  static Future<void> clear() async {
    final p = await _prefs;
    for (final k in p.getKeys().where((k) => k.startsWith(_prefix)).toList()) {
      await p.remove(k);
    }
  }
}

/// Decoders for the two shapes the API returns.
List<Map<String, dynamic>> decodeRows(dynamic json) => (json as List? ?? [])
    .whereType<Map>()
    .map((e) => Map<String, dynamic>.from(e))
    .toList();

Map<String, dynamic> decodeDoc(dynamic json) =>
    json is Map ? Map<String, dynamic>.from(json) : <String, dynamic>{};
