// Every read the app makes, answered from the phone when the server cannot be
// reached (13 Nov 2026).
//
// The user: "Everything in this app must work exactly the same offline ... the
// app must not show that the net is gone." Before this only the reads someone
// had remembered to wrap in `OfflineCache` survived a dead zone; every other
// screen showed "No connection". Wrapping them one by one had already been
// tried and left most of the app out, so this sits in the HTTP client instead:
// every GET that succeeds is kept, and a GET that fails for want of a network
// (or because the server itself is down) is answered with the kept copy. A new
// screen is covered without anyone having to remember.
//
// Writes are not touched here: they go through the outbox (`outbox.dart`),
// which re-runs each write's rules when it is finally sent. What the outbox is
// holding is laid over every answer, live or kept (`core/local_overlay.dart`),
// so a screen shows what the rep did and not only what the server knows.
//
// Kept per sign-in, in files rather than SharedPreferences: SharedPreferences
// loads its whole store into memory at start-up, and a copy of every list the
// app reads does not belong there. Wiped on sign-out so the next person to use
// a handset never sees the last one's customers.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/local_overlay.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/services/outbox.dart';

/// Whether the phone has a network at all, as Android reports it.
///
/// Only "none" is trusted: a Wi-Fi with no internet behind it still reports
/// Wi-Fi. So this is used to skip a request that cannot succeed — answering
/// from the phone at once instead of after a timeout — and to notice the
/// moment a network comes back, never to decide that a server is reachable.
class NetState {
  static bool _none = false;

  /// True only when Android says there is no network of any kind.
  static bool get knownOffline => _none;

  /// Called whenever a network appears after there was none.
  static final List<VoidCallback> _onBack = [];
  static void onBack(VoidCallback f) => _onBack.add(f);

  static StreamSubscription<List<ConnectivityResult>>? _sub;

  static Future<void> start() async {
    if (_sub != null) return;
    try {
      final c = Connectivity();
      _set(await c.checkConnectivity());
      _sub = c.onConnectivityChanged.listen(_set, onError: (_) {});
    } catch (_) {
      // No plugin (tests, an odd ROM): behave as if always connected, which
      // is how the app behaved before this existed.
      _none = false;
    }
  }

  static void _set(List<ConnectivityResult> r) {
    final none = r.isEmpty || r.every((x) => x == ConnectivityResult.none);
    final wasNone = _none;
    _none = none;
    if (wasNone && !none) {
      for (final f in List.of(_onBack)) {
        try {
          f();
        } catch (_) {}
      }
    }
  }

  @visibleForTesting
  static void debugSet(bool none) => _set(
      none ? [ConnectivityResult.none] : [ConnectivityResult.mobile]);
}

/// A write rehearsed with no signal (13 Nov 2026).
///
/// When a write cannot reach the server it is kept in the outbox and sent
/// later. But the screen that made it has to carry on as if it had gone: a
/// lead needs a name to open, an approved order has to leave the waiting list.
/// So the same function is run once more inside a [DryRun], where every read
/// is answered as usual (from the phone if need be) and every write is
/// answered here instead of being sent: a new document gets a [kLocalPrefix]
/// name, a change is echoed back. What each write would have done is noted as
/// a [LocalEffect], and that is what the outbox lays over the screens until the
/// real write goes.
///
/// Nothing reaches the server from inside one. The rules the function checks
/// run for real, on what the phone last saw — a refusal is shown at once,
/// exactly as with a signal — and run again, on the server's answer, when the
/// write is finally sent.
class DryRun {
  static const Symbol _key = #mannaDryRun;
  final List<LocalEffect> effects = [];

  static DryRun? get current {
    final z = Zone.current[_key];
    return z is DryRun ? z : null;
  }

  Future<T> run<T>(Future<T> Function() f) =>
      runZoned(f, zoneValues: {_key: this});

  static Map<String, dynamic> _body(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.isNotEmpty) {
      try {
        final j = jsonDecode(data);
        if (j is Map) return Map<String, dynamic>.from(j);
      } catch (_) {}
    }
    if (data is FormData) {
      return {for (final f in data.fields) f.key: f.value};
    }
    return {};
  }

  /// The answer the server would most likely have given [o], noting what it
  /// would have changed.
  Response<dynamic> answer(RequestOptions o) {
    final m = o.method.toUpperCase();
    final body = _body(o.data);
    final res = resourceOf(o.path);
    dynamic data;
    if (res != null && m == 'POST' && res.name == null) {
      final name = Outbox.newLocalName();
      effects.add(LocalEffect.create(res.doctype, name, body));
      data = {
        'data': {...body, 'name': name}
      };
    } else if (res != null && res.name != null && m == 'PUT') {
      effects.add(LocalEffect.update(res.doctype, res.name!, body));
      data = {
        'data': {...body, 'name': res.name}
      };
    } else if (res != null && res.name != null && m == 'DELETE') {
      effects.add(LocalEffect.delete(res.doctype, res.name!));
      data = {'message': 'ok'};
    } else {
      // A Server Script or an upload. Its effect is not knowable here; the
      // name is what callers of both read back.
      final name = Outbox.newLocalName();
      data = {
        'message': {'name': name, 'file_url': name, 'ok': true}
      };
    }
    return Response(
      requestOptions: o,
      data: data,
      statusCode: 200,
      extra: {'fromPhone': true},
    );
  }
}

class NetCache {
  static Directory? _dir;
  static String? _dirFor;

  /// Where tests keep the copies; path_provider has no folder under test.
  @visibleForTesting
  static Directory? debugRoot;

  static Future<Directory?> _folder() async {
    final who = Session.I.email.toLowerCase();
    if (debugRoot != null) {
      final d = Directory('${debugRoot!.path}/${fnv(who)}');
      await d.create(recursive: true);
      return d;
    }
    if (_dir != null && _dirFor == who) return _dir;
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}/netcache/${fnv(who)}');
      await d.create(recursive: true);
      _dirFor = who;
      return _dir = d;
    } catch (_) {
      return null;
    }
  }

  /// Requests that are never answered from the phone: signing in and out,
  /// and the "who is signed in" probe, whose failure is how the app learns it
  /// was opened with no signal.
  static const _never = [
    '/api/method/login',
    '/api/method/logout',
    'generate_keys',
    'frappe.auth.get_logged_user',
  ];

  static bool isRead(RequestOptions o) {
    if (_never.any((p) => o.path.contains(p))) return false;
    if (o.responseType != ResponseType.json &&
        o.responseType != ResponseType.plain) {
      return false;
    }
    final m = o.method.toUpperCase();
    if (m == 'GET') return true;
    // Server Scripts that only read, but are called with POST.
    if (m != 'POST') return false;
    if (o.path.endsWith('_get_status')) return true;
    final d = o.data;
    return d is Map && d['action'] == 'list';
  }

  /// The key a request is kept under: its method, path, query and (for a
  /// read made with POST) body, sorted so the same read made two ways is one
  /// entry.
  static String keyOf(RequestOptions o) {
    final q = o.queryParameters.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final qs = q.map((e) => '${e.key}=${e.value}').join('&');
    final d = o.data;
    final body = d is Map ? jsonEncode(Map.fromEntries(
        d.entries.toList()..sort((a, b) => '${a.key}'.compareTo('${b.key}')))) : '';
    return '${o.method.toUpperCase()} ${o.path}?$qs $body';
  }

  /// 64-bit FNV-1a, as hex: a file name for a key, no crypto package needed.
  static String fnv(String s) {
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(s)) {
      h ^= b;
      // Dart's int is 64 bits and wraps, which is the arithmetic FNV wants.
      h = h * 0x100000001b3;
    }
    return h.toUnsigned(64).toRadixString(16);
  }

  static Future<void> put(String key, dynamic data) async {
    if (data is! Map && data is! List && data is! String && data is! num) {
      return;
    }
    final d = await _folder();
    if (d == null) return;
    try {
      await File('${d.path}/${fnv(key)}.json').writeAsString(jsonEncode({
        'at': serverNow().toIso8601String(),
        'key': key,
        'data': data,
      }));
    } catch (_) {
      // A copy that cannot be written only means one fewer answer offline.
    }
  }

  /// The kept answer for [key], or null. No age limit (13 Nov 2026): an old
  /// answer beats an error screen, which is what the user asked for.
  static Future<dynamic> get(String key) async {
    final d = await _folder();
    if (d == null) return null;
    try {
      final f = File('${d.path}/${fnv(key)}.json');
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['key'] != key) return null;
      return j['data'];
    } catch (_) {
      return null;
    }
  }

  /// Everything kept for every sign-in. Sign-out only.
  static Future<void> clear() async {
    if (debugRoot != null) {
      if (await debugRoot!.exists()) await debugRoot!.delete(recursive: true);
      return;
    }
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}/netcache');
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
    _dir = null;
    _dirFor = null;
  }

  static const Symbol _liveKey = #mannaLiveOnly;

  /// Runs [f] with every read going to the server and nothing answered from
  /// the phone. For a write being SENT: its rules are judged on what the
  /// server says now, never on a kept copy — an approval re-checked against
  /// yesterday's order is not re-checked at all. A read that fails in here
  /// fails the write, which then stays kept.
  static Future<T> liveOnly<T>(Future<T> Function() f) =>
      runZoned(f, zoneValues: {_liveKey: true});

  static bool get _live => Zone.current[_liveKey] == true;

  static Future<dynamic> _overlay(RequestOptions o, dynamic data) async {
    if (!o.path.contains('/api/resource/')) return data;
    try {
      final effects = await Outbox.effects();
      if (effects.isEmpty) return data;
      return applyEffects(o.path, o.queryParameters, data, effects);
    } catch (_) {
      return data;
    }
  }

  static Response<dynamic> _answer(RequestOptions o, dynamic data) => Response(
        requestOptions: o,
        data: data,
        statusCode: 200,
        extra: {'fromPhone': true},
      );

  /// The answer to a read of a document the phone made and has not sent —
  /// there is nothing on the server to ask.
  static Future<dynamic> _localOnly(RequestOptions o) async {
    final res = resourceOf(o.path);
    if (res?.name == null || !isLocalName(res!.name!)) return null;
    final out = await _overlay(o, null);
    return out is Map && out['data'] is Map ? out : null;
  }

  static final Interceptor interceptor = InterceptorsWrapper(
    onRequest: (o, handler) async {
      // A screen still holding the name the phone gave something, after the
      // server has given it a real one.
      if (o.path.contains(kLocalPrefix)) o.path = await Outbox.realName(o.path);
      final dry = DryRun.current;
      if (dry != null && !isRead(o)) return handler.resolve(dry.answer(o));
      if (!isRead(o) || _live) return handler.next(o);
      final local = await _localOnly(o);
      if (local != null) return handler.resolve(_answer(o, local));
      if (NetState.knownOffline) {
        final kept = await get(keyOf(o));
        if (kept != null) {
          return handler.resolve(_answer(o, await _overlay(o, kept)));
        }
      }
      handler.next(o);
    },
    onResponse: (r, handler) async {
      final o = r.requestOptions;
      if (isRead(o) && r.statusCode == 200 && r.extra['fromPhone'] != true) {
        await put(keyOf(o), r.data);
        if (!_live) r.data = await _overlay(o, r.data);
      }
      handler.next(r);
    },
    onError: (e, handler) async {
      final o = e.requestOptions;
      // A gateway with no server behind it is the server unreachable, as
      // good as no signal. A plain 500 is a real fault in the request and is
      // not hidden behind a kept copy.
      final serverDown =
          const {502, 503, 504}.contains(e.response?.statusCode ?? 0);
      if (isRead(o) && !_live && (isNetworkFailure(e) || serverDown)) {
        final kept = await get(keyOf(o));
        if (kept != null) {
          return handler.resolve(_answer(o, await _overlay(o, kept)));
        }
      }
      handler.next(e);
    },
  );
}
