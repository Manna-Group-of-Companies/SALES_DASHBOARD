
import 'dart:async';

import 'package:dio/dio.dart';

import 'package:manna_field_sales/core/app_bus.dart';
import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/core/server_clock.dart';

class Session {
  static final Session I = Session._();
  Session._();

  String baseUrl = 'https://mannarubber.m.frappe.cloud';
  String email = '';
  String sid = '';
  String csrfToken = '';
  // Frappe API token pair. Never expires — preferred over the session cookie.
  String apiKey = '';
  String apiSecret = '';
  String? salesPerson;
  String? salesPersonLabel;
  String? managedTeam;
  List<String> teamReps = [];

  /// The reps whose customers, leads and routes this login may see.
  ///
  /// Normally just this rep. In a pooled unit — UAE — it is everyone in the
  /// unit, because they cover each other's leave and cannot wait for records to
  /// be reassigned. Resolved once at sign-in by `Api.resolveVisibility`, and
  /// left as `[salesPerson]` if that fails: widening on an error is how one
  /// unit ends up looking at another's customers.
  ///
  /// See `core/visibility.dart` and `shared/fixtures/visibility.json`.
  List<String> unitPeers = [];

  /// True when this rep's records are shared with colleagues, so lists have to
  /// say who owns each row.
  bool get sharesUnit => unitPeers.length > 1;
  bool isGM = false;
  bool isHR = false;
  String? company;

  /// The unit the team this login manages belongs to, read off that team's own
  /// reps. A manager who is not themselves a Sales Person has no [company] of
  /// their own, and hardcoding which team belongs to which unit would go stale
  /// the first time a manager changes.
  String? managedTeamCompany;

  bool isProductionManager = false;
  String? productionCompany;
  bool get isManager => managedTeam != null && managedTeam!.isNotEmpty;

  /// True when this login is on the Manna Treads side of the business, either
  /// as a rep or as the manager of a Treads team.
  ///
  /// Everything Phase 1 added — the product families, minimum stock, the
  /// slow-mover list — is how Treads sells. Retreads and UAE work a different
  /// way, so those screens are hidden from them entirely rather than shown
  /// empty, which would only invite questions about data that will never
  /// arrive.
  bool get isTreadsUnit =>
      company == kUnitTreads || managedTeamCompany == kUnitTreads;
  bool get hasToken => apiKey.isNotEmpty && apiSecret.isNotEmpty;
  late Dio dio;

  /// Re-establishes credentials silently. Wired up by `Api` at start-up; left
  /// null the interceptor simply passes auth failures through to the caller.
  Future<bool> Function()? reauthenticate;

  // Marks a request that has already been replayed once, so a permanently
  // rejected credential cannot spin the retry loop.
  static const _kRetried = 'authRetried';
  // A spare copy of a multipart body — the original is consumed on send.
  static const _kFormCopy = 'authFormCopy';

  Future<bool>? _reauthInFlight;

  /// Opts a request out of the auto-reauth machinery. Anything called from
  /// inside [reauthenticate] must use this: it is already running under
  /// [_refresh], so triggering another refresh would await itself forever.
  static Options get noRetry => Options(extra: {_kRetried: true});

  /// Headers that authenticate a bare HTTP call. Also used by `Image.network`,
  /// which does not go through [dio].
  Map<String, String> get authHeaders {
    if (hasToken) return {'Authorization': 'token $apiKey:$apiSecret'};
    if (sid.isNotEmpty) return {'Cookie': 'sid=$sid'};
    return const {};
  }

  void clearAuth() {
    sid = '';
    csrfToken = '';
    apiKey = '';
    apiSecret = '';
  }

  // Endpoints that establish or tear down credentials. Retrying these on an
  // auth failure would be circular.
  static const _authPaths = [
    '/api/method/login',
    '/api/method/logout',
    'user.user.generate_keys',
  ];

  static bool _isAuthPath(String path) =>
      _authPaths.any((p) => path.contains(p));

  void init() {
    dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
      },
      validateStatus: (s) => s != null && s < 500,
    ));
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        // Re-stamp auth on every attempt: a replayed request must not carry
        // the stale header that got it rejected.
        options.headers.remove('Cookie');
        options.headers.remove('Authorization');
        options.headers.addAll(authHeaders);
        final m = options.method.toUpperCase();
        final isWrite = m == 'POST' || m == 'PUT' || m == 'DELETE';
        // CSRF applies to cookie auth only; Frappe exempts token requests.
        if (!hasToken && csrfToken.isNotEmpty && isWrite) {
          options.headers['X-Frappe-CSRF-Token'] = csrfToken;
        }
        // A FormData body can only be read once, so stash a clone while it is
        // still intact in case we need to replay the upload.
        final body = options.data;
        if (body is FormData && options.extra[_kRetried] != true) {
          options.extra[_kFormCopy] = body.clone();
        }
        handler.next(options);
      },
      onResponse: (response, handler) async {
        // Every response re-teaches the app what time the server thinks it is.
        ServerClock.I.syncFromHeader(response.headers.value('date'));
        if (await _needsReauth(response)) {
          final replayed = await _reauthAndReplay(response.requestOptions);
          if (replayed != null) return handler.resolve(replayed);
        }
        final m = response.requestOptions.method.toUpperCase();
        final path = response.requestOptions.path;
        final sc = response.statusCode ?? 0;
        if (sc >= 200 &&
            sc < 300 &&
            (m == 'POST' || m == 'PUT' || m == 'DELETE') &&
            path.contains('/api/resource/')) {
          AppBus.I.bump();
        }
        handler.next(response);
      },
    ));
  }

  Future<bool> _needsReauth(Response response) async {
    final o = response.requestOptions;
    if (reauthenticate == null) return false;
    if (o.extra[_kRetried] == true) return false;
    if (_isAuthPath(o.path)) return false;
    final sc = response.statusCode ?? 0;
    if (sc == 401) return true;
    // 403 is ambiguous — it covers both a dead session and a genuine
    // permission denial. Only the former is worth re-authenticating for.
    if (sc == 403) return !await _sessionAlive();
    return false;
  }

  Future<bool> _sessionAlive() async {
    try {
      final r = await dio.get('/api/method/frappe.auth.get_logged_user',
          options: noRetry);
      final u = (r.data is Map) ? r.data['message'] : null;
      return r.statusCode == 200 && u is String && u.isNotEmpty && u != 'Guest';
    } catch (_) {
      // Network trouble, not an auth problem — don't burn a re-login on it.
      return true;
    }
  }

  Future<Response?> _reauthAndReplay(RequestOptions o) async {
    if (!await _refresh()) return null;
    final spare = o.extra[_kFormCopy];
    final extra = Map<String, dynamic>.from(o.extra)
      ..remove(_kFormCopy)
      ..[_kRetried] = true;
    try {
      return await dio.fetch(o.copyWith(
        data: spare is FormData ? spare : o.data,
        extra: extra,
      ));
    } catch (_) {
      return null;
    }
  }

  /// One re-login at a time. The dashboard fires half a dozen calls in
  /// parallel; without this they would each kick off their own.
  Future<bool> _refresh() {
    return _reauthInFlight ??=
        reauthenticate!().whenComplete(() => _reauthInFlight = null);
  }
}
