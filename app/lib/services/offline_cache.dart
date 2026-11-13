// Keeping the app usable where the signal is not.
//
// WHAT THIS DOES AND DOES NOT COVER
//
// Reads are cached. A rep who walks into a shed with no bars can still pull up
// the customer, their outstanding balance, the product list and where the
// minimum stock stood at the last sync. That is most of what a rep needs a
// phone for at a counter, and it is safe because none of it changes the world.
//
// Writes are queued too, since 13 Nov 2026 (`outbox.dart`, `sync_engine.dart`).
// They were not, while an order decremented a minimum-stock pool on the server
// and a kept order could promise rolls already gone. Nothing books stock on
// the phone since 17 Sep 2026 — SAP commits it — and a kept write runs its
// rules again on the server's figures when it is sent, so the user's "the app
// must work exactly the same offline" no longer trades against that.

// SAYS NOTHING ABOUT ITS AGE (13 Nov 2026)
//
// A cached answer used to arrive with "Offline — showing data from 3 hours
// ago". The user asked for the app not to show that the network is gone, so
// [Cached.ageLabel] is empty. Every HTTP read is also kept by
// `net_cache.dart` now; this cache stays for the reads that were already
// built on it.

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

  /// What a screen says about the data's age: nothing (the user, 13 Nov
  /// 2026: "The app must not show that the net is gone; it should just work
  /// normally"). Kept as a getter so the screens that quote it need not
  /// change, and so the decision is made once, here.
  ///
  /// This reverses the rule that stood here — that a stale figure shown as
  /// live is worse than none. A kept order and a kept approval are checked
  /// again on the server's figures when they are sent (`outbox.dart`,
  /// `Api.sendPendingOrder`), which is what makes saying nothing safe.
  String get ageLabel => '';
}

/// Read-through cache over the JSON the API returns.
class OfflineCache {
  static const _prefix = 'cache:';

  // No age limit since 13 Nov 2026: an old copy beats an error screen, which
  // is what the user asked for. Anything that matters is checked again on the
  // server's own figures when it is sent.

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  /// How the most recent read of each key turned out, so a screen can say the
  /// data is old without every fetcher having to change shape to carry it.
  ///
  /// In-memory and per-run on purpose: this describes what *this* screen just
  /// got, not what is on disk. Empty for a live read.
  static final Map<String, String> _lastAge = <String, String>{};

  /// The staleness line for the last read of [key], or empty if it was live.
  /// Safe to call before anything has been read — an unknown key is not stale.
  static String ageLabel(String key) => _lastAge[key] ?? '';

  /// True when any of [keys] came from the cache. Used where one screen is
  /// built from several reads and is only as fresh as its stalest part.
  static String worstAge(List<String> keys) {
    for (final k in keys) {
      final label = _lastAge[k] ?? '';
      if (label.isNotEmpty) return label;
    }
    return '';
  }

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
      _lastAge[key] = '';
      return Cached(live);
    } catch (e) {
      // A timeout as well as no connection (11 Nov 2026): this is a read, so
      // whether the request reached the server does not matter, and on a
      // weak signal the saved copy beats an error screen.
      if (!isNetworkFailure(e)) rethrow;
      final fallback = await peek<T>(key, decode);
      if (fallback == null) rethrow;
      _lastAge[key] = fallback.ageLabel;
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

  /// Keys under this survive [clear] unless it is a sign-out: who is signed
  /// in, the open visit, today's attendance. Every write calls [clear] to
  /// drop lists it may have changed, and none of those writes changes these
  /// — but wiping them took away exactly what an app opened, or a punch
  /// taken, with no signal has to fall back on.
  static const String sessionPrefix = 'session:';

  /// Drops what is cached. [signOut] drops everything, so one rep's
  /// customers are never served to the next person to use the handset;
  /// otherwise the [sessionPrefix] keys are kept.
  static Future<void> clear({bool signOut = false}) async {
    _lastAge.clear();
    final p = await _prefs;
    final keep = '$_prefix$sessionPrefix';
    for (final k in p
        .getKeys()
        .where((k) => k.startsWith(_prefix) && (signOut || !k.startsWith(keep)))
        .toList()) {
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
