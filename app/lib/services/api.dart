import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:manna_field_sales/core/app_version.dart';
import 'package:manna_field_sales/core/attendance_rules.dart';
import 'package:manna_field_sales/core/auth_store.dart';
import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/core/credit.dart';
import 'package:manna_field_sales/core/expenses.dart';
import 'package:manna_field_sales/core/lead_delete.dart';
import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/core/duplicate_order.dart';
import 'package:manna_field_sales/core/leave_balance.dart';
import 'package:manna_field_sales/core/trip_totals.dart';
import 'package:manna_field_sales/core/production_stages.dart';
import 'package:manna_field_sales/core/proximity.dart';
import 'package:manna_field_sales/core/server_clock.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/core/visibility.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/models/order_ref.dart';
import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/services/offline_cache.dart';
import 'package:manna_field_sales/services/pending_orders.dart';
import 'package:manna_field_sales/services/stock_service.dart';
import 'package:manna_field_sales/services/trip_points.dart';

/// Builds the REST path for an ERPNext doctype. Private to this library —
/// only [Api] ever needs it.
String _res(String doctype) => '/api/resource/${Uri.encodeComponent(doctype)}';

/// Cache keys for the lists a rep opens in the field.
///
/// Every one of these used to fail with a raw Dio exception the moment the
/// signal went, on screens whose whole job is to show what already happened —
/// visits made, orders placed, leave taken. None of that needs a network to be
/// worth reading, so all of it is served from the last sync when there is no
/// connection. Screens quote [OfflineCache.ageLabel] so nobody mistakes an old
/// figure for a current one.
///
/// Keyed per rep, because handsets get shared.
class CacheKeys {
  static String get _me => Session.I.salesPerson ?? 'all';

  static String get leads => 'leads:$_me';
  static String get visits => 'visits:$_me';
  static String get orders => 'orders:$_me';
  static String get collections => 'collections:$_me';
  static String get trips => 'trips:$_me';
  static String get leaves => 'leaves:$_me';
  static String get leaveBalance => 'leaveBalance:$_me';
  static String get items => 'items';

  /// Stock is composed from the warehouse read, the weights, and the item
  /// list, so it is only as fresh as its stalest part.
  static List<String> get minimumStock =>
      [kStockBinsKey, kStockWeightsKey, items];
}

/// Outcome of a silent authentication attempt.
enum AuthState {
  /// Authenticated — carry on.
  ok,

  /// The server rejected the credentials (password changed, user disabled,
  /// no Sales Person link). The only outcome that justifies the login form.
  rejected,

  /// The server could not be reached. The credentials may well be fine, so
  /// this is a reason to wait and retry — never to sign the rep out.
  unreachable,
}

class Api {
  static Future<bool> testAuth() async {
    final r = await Session.I.dio.get('/api/method/frappe.auth.get_logged_user');
    final u = (r.data is Map) ? r.data['message'] : null;
    return r.statusCode == 200 && u is String && u.isNotEmpty && u != 'Guest';
  }

  // ---------------------------------------------------------------- auth ---
  //
  // Reps used to be logged out whenever Frappe expired the `sid` cookie
  // (6 hours by default). Auth now prefers an API key/secret pair, which
  // Frappe never expires, and falls back to a silent password re-login for
  // accounts that cannot mint one. Either way the login screen only ever
  // reappears if the credentials are genuinely rejected.

  /// Interactive login. Establishes a session, remembers the credentials, then
  /// tries to upgrade to a permanent token.
  static Future<void> login(String email, String password) async {
    await _passwordLogin(email, password);
    await AuthStore.saveLogin(
        baseUrl: Session.I.baseUrl, email: email, password: password);
    await provisionToken(email);
  }

  /// True when we hold something we can authenticate with, so the rep should
  /// not be asked to type anything. False only before the first login and
  /// after an explicit logout.
  static Future<bool> get canResume async {
    final c = await AuthStore.load();
    return c.hasToken || c.canReauth;
  }

  /// Restore the last session at app start without prompting the rep.
  static Future<AuthState> restore() async {
    final c = await AuthStore.load();
    if (!c.hasToken && !c.canReauth) return AuthState.rejected;
    if (c.baseUrl.isNotEmpty) Session.I.baseUrl = c.baseUrl;
    Session.I.email = c.email;
    Session.I.sid = c.sid;
    Session.I.apiKey = c.apiKey;
    Session.I.apiSecret = c.apiSecret;
    Session.I.init();
    attachAutoReauth();
    try {
      if (!Session.I.hasToken && c.sid.isNotEmpty) await fetchCsrf();
      // A stale sid is repaired by the interceptor mid-flight, so this usually
      // succeeds on the first try even after days of idle.
      if (await testAuth()) return AuthState.ok;
    } on DioException {
      return AuthState.unreachable;
    }
    if (!c.canReauth) return AuthState.rejected;
    return _authenticate(c.email, c.password);
  }

  /// Lets the Dio interceptor recover from an expired credential on its own.
  static void attachAutoReauth() {
    Session.I.reauthenticate = _reauthenticate;
  }

  /// Password login that reports *why* it failed, so callers can tell a flat
  /// network apart from a credential the server actually refused.
  static Future<AuthState> _authenticate(String email, String password) async {
    try {
      await _passwordLogin(email, password);
      return AuthState.ok;
    } on DioException {
      return AuthState.unreachable;
    } catch (_) {
      return AuthState.rejected;
    }
  }

  /// Silent re-authentication. Never shows UI, never throws.
  static Future<bool> _reauthenticate() async {
    final email = Session.I.email;
    final password = await AuthStore.password();
    if (email.isEmpty || password.isEmpty) return false;
    return await _authenticate(email, password) == AuthState.ok;
  }

  // Log in with email + password. Captures the session cookie (sid) returned
  // by Frappe, then fetches a CSRF token so writes are allowed.
  static Future<void> _passwordLogin(String email, String password) async {
    // Getting here means any token we held was rejected; drop it so the
    // request below (and everything after) authenticates by cookie.
    Session.I.clearAuth();
    await AuthStore.clearToken();
    final r = await Session.I.dio.post(
      '/api/method/login',
      data: {'usr': email, 'pwd': password},
      options: Options(
          contentType: Headers.formUrlEncodedContentType,
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (s) => s != null && s < 500),
    );
    if (r.statusCode != 200) {
      throw Exception('Invalid email or password.');
    }
    // Extract sid from the Set-Cookie header(s).
    final setCookies = r.headers.map['set-cookie'] ?? const <String>[];
    String sid = '';
    for (final c in setCookies) {
      final m = RegExp(r'sid=([^;]+)').firstMatch(c);
      if (m != null) sid = m.group(1) ?? '';
    }
    if (sid.isEmpty || sid == 'Guest') {
      throw Exception('Invalid email or password.');
    }
    Session.I.sid = sid;
    Session.I.email = email;
    await AuthStore.saveSid(sid);
    await fetchCsrf();
  }

  /// Best effort upgrade from cookie auth to a permanent API token.
  ///
  /// Frappe's stock `generate_keys` is System Manager only, so managers and
  /// admins get a token while ordinary reps quietly stay on the cookie +
  /// silent-re-login path. To give reps tokens too, expose a whitelisted
  /// server method that calls `generate_keys` on the caller's own user and
  /// point [_tokenMethod] at it.
  static const _tokenMethod =
      '/api/method/frappe.core.doctype.user.user.generate_keys';

  static Future<bool> provisionToken(String email) async {
    if (Session.I.hasToken) return true;
    try {
      final r = await Session.I.dio.post(_tokenMethod,
          data: {'user': email},
          options: Options(contentType: Headers.formUrlEncodedContentType));
      final m = (r.data is Map) ? r.data['message'] : null;
      final secret = (m is Map) ? '${m['api_secret'] ?? ''}' : '';
      if (secret.isEmpty) return false;
      final key = await _fetchApiKey(email);
      if (key.isEmpty) return false;
      Session.I.apiKey = key;
      Session.I.apiSecret = secret;
      await AuthStore.saveToken(key, secret);
      return true;
    } catch (_) {
      return false;
    }
  }

  // generate_keys returns only the secret; the key itself lives on the User.
  static Future<String> _fetchApiKey(String email) async {
    final r = await Session.I.dio.get(
        '${_res('User')}/${Uri.encodeComponent(email)}',
        queryParameters: {'fields': '["api_key"]'});
    final d = (r.data is Map) ? r.data['data'] : null;
    return (d is Map) ? '${d['api_key'] ?? ''}' : '';
  }

  // Best-effort CSRF token retrieval. Frappe embeds it in the desk boot.
  static Future<void> fetchCsrf() async {
    try {
      // noRetry: fetchCsrf runs inside the re-auth flow itself.
      final r = await Session.I.dio.get('/app',
          options: Session.noRetry.copyWith(
              responseType: ResponseType.plain,
              validateStatus: (s) => s != null && s < 500));
      final html = '${r.data}';
      final m = RegExp(r'"csrf_token":\s*"([0-9a-zA-Z]+)"').firstMatch(html) ??
          RegExp(r'csrf_token\s*=\s*"([0-9a-zA-Z]+)"').firstMatch(html);
      Session.I.csrfToken = m?.group(1) ?? '';
    } catch (_) {
      Session.I.csrfToken = '';
    }
  }

  static Future<void> logout() async {
    Session.I.reauthenticate = null;
    try {
      await Session.I.dio.get('/api/method/logout');
    } catch (_) {}
    Session.I.clearAuth();
    await AuthStore.clear();
    // Handsets get shared and reassigned. Cached customers and unsent orders
    // belong to whoever was signed in, so they go with the session rather than
    // sitting there for the next person.
    await OfflineCache.clear();
    await PendingOrders.clear();
  }

  static Future<List<Map<String, dynamic>>> _list(String doctype,
      {required String fields,
        String? filters,
        String orderBy = 'creation desc',
        int limit = 0}) async {
    final qp = <String, dynamic>{
      'fields': fields,
      'order_by': orderBy,
      'limit_page_length': limit,
    };
    if (filters != null) qp['filters'] = filters;
    final r = await Session.I.dio.get(_res(doctype), queryParameters: qp);
    final data = (r.data is Map) ? r.data['data'] : null;
    if (data is List) return data.cast<Map<String, dynamic>>();
    throw Exception(_frappeError(r));
  }

  /// Asks the backend whether this build is still allowed to write.
  ///
  /// Answers [VersionVerdict.unknown] on any failure — a missing settings row,
  /// no permission, no signal — because a rep in a shop must not be locked out
  /// of the app by a settings lookup. See `app_version.dart` for why the gate
  /// only ever closes on a definite answer.
  static Future<VersionGate> appVersionGate() async {
    try {
      final r = await Session.I.dio
          .get('${_res('Manna App Settings')}/Manna App Settings');
      final d = (r.data is Map) ? r.data['data'] : null;
      if (d is! Map) return const VersionGate(VersionVerdict.unknown);
      return checkVersion(kAppVersion, d['minimum_app_version'],
          messageRaw: d['update_message']);
    } catch (_) {
      return const VersionGate(VersionVerdict.unknown);
    }
  }

  /// A read that falls back to the last sync when the network is down.
  ///
  /// For lists a rep needs to *look at* — what they visited, what they
  /// ordered, what leave they have left. None of it changes the world, so
  /// serving yesterday's copy beats an error screen. Anything that writes goes
  /// straight to the server, always.
  static Future<List<Map<String, dynamic>>> _cachedRows(
          String key, Future<List<Map<String, dynamic>>> Function() fetch) =>
      OfflineCache.read<List<Map<String, dynamic>>>(key, fetch,
              decode: decodeRows)
          .then((c) => c.value);

  static Future<int> getCount(String doctype, String filters) async {
    final r = await Session.I.dio.get('/api/method/frappe.client.get_count',
        queryParameters: {'doctype': doctype, 'filters': filters});
    final m = r.data is Map ? r.data['message'] : null;
    return (m is num) ? m.toInt() : 0;
  }

  static Future<List<Map<String, dynamic>>> getCustomers() async =>
      (await getCustomersCached()).value;

  /// The rep's customers, falling back to the last synced copy when the
  /// network is down.
  ///
  /// A rep standing in a shop needs the phone number, the route and the
  /// outstanding balance whether or not there is signal, and none of those
  /// move much between visits. The result carries when it was fetched so the
  /// list can say so — an outstanding balance quoted to a customer is exactly
  /// the sort of figure nobody should read off a stale screen unknowingly.
  static Future<Cached<List<Map<String, dynamic>>>> getCustomersCached() {
    final rep = Session.I.salesPerson;
    // `custom_assigned_reps` is a Link to Sales Person now, holding a bare
    // name. It used to be free text wrapped in pipes — "|Subhash|" — matched
    // with a LIKE. That match cannot succeed against a Link value, so the
    // customer list came back empty for every rep.
    // In a pooled unit this is every rep in the unit, not just this one — see
    // core/visibility.dart. Ownership is untouched; only the filter widens.
    return OfflineCache.read<List<Map<String, dynamic>>>(
      'customers:${rep ?? 'all'}',
      () => _visibleRows(
          'Customer', kFieldCustomerOwner,
          // The outstanding fields come from `kOutstandingFields` rather than
          // being spelled out here, so a screen cannot end up fetching three
          // of SAP's four aging buckets and quietly showing the fourth as
          // zero — which would read as "nothing is that old".
          fields: jsonEncode([
            'name',
            'customer_name',
            'customer_group',
            'territory',
            'custom_sales_route',
            'custom_latitude',
            'custom_longitude',
            'custom_location_status',
            'custom_verified_latitude',
            'custom_verified_longitude',
            'custom_phone',
            ...kOutstandingFields,
          ]),
          orderBy: 'customer_name asc'),
      decode: decodeRows,
    );
  }

  /// Sets who a customer belongs to. UAE only (see `core/visibility.dart`) —
  /// callers must check `canAssignOwner` first; this does not re-check it.
  /// Any pool member may assign any pool member, including themselves, which
  /// is what lets a freshly imported, unowned customer be claimed by
  /// whoever gets to it first.
  static Future<void> assignCustomerOwner(String customerName, String rep) async {
    await _put('Customer', customerName, {kFieldCustomerOwner: rep});
    await OfflineCache.clear();
  }

  static Future<String?> _loggedUser() async {
    try {
      final r =
      await Session.I.dio.get('/api/method/frappe.auth.get_logged_user');
      final m = (r.data is Map) ? r.data['message'] : null;
      return (m is String && m.isNotEmpty) ? m : null;
    } catch (_) {
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>> getSalesPersons() async {
    final user = await _loggedUser();
    if (user == null) return [];
    return _list('Sales Person',
        fields: '["name","sales_person_name","custom_company",'
            '"custom_team_manager"]',
        filters: '[["is_group","=",0],["custom_user","=","$user"]]');
  }

  static Future<void> resolveMySalesPerson() async {
    final list = await getSalesPersons();
    if (list.isNotEmpty) {
      Session.I.salesPerson = list.first['name'] as String;
      Session.I.salesPersonLabel =
      (list.first['sales_person_name'] ?? list.first['name']) as String;
      Session.I.company = list.first['custom_company'] as String?;
      Session.I.teamManager = list.first['custom_team_manager'] as String?;
    } else {
      Session.I.salesPerson = null;
      Session.I.salesPersonLabel = null;
      Session.I.company = null;
      Session.I.teamManager = null;
    }
    await resolveVisibility();
  }

  /// Works out whose records this rep may see.
  ///
  /// Only a pooled unit needs the roster, so an Indian rep pays for nothing:
  /// they are their own pool and the call returns immediately. On any failure
  /// the pool stays as just this rep — visibility must never widen because a
  /// request did not come back.
  static Future<void> resolveVisibility() async {
    final me = Session.I.salesPerson;
    if (me == null || me.isEmpty) {
      Session.I.unitPeers = [];
      return;
    }
    Session.I.unitPeers = [me];
    if (!isPooledUnit(Session.I.company)) return;
    try {
      final rows = await _list('Sales Person',
          fields: '["name","$kFieldUnit","enabled","is_group"]',
          filters: '[["$kFieldUnit","=","${Session.I.company}"]]',
          orderBy: 'name asc');
      final peers = visibleReps(
          rows.map(VisPerson.fromRow).toList(), me);
      if (peers.isNotEmpty) Session.I.unitPeers = peers;
    } catch (_) {
      // Leave it at [me]. A pooled rep briefly seeing only their own is a
      // smaller problem than a failure that widens the list.
    }
  }

  /// The filter clause for "records this rep may see", by owner field, or
  /// null when there is nothing to scope by. Peers only — no widening for an
  /// unassigned record, because a route is never unassigned in the first
  /// place (it is named `<Rep> - <Place>`, one owner by construction), unlike
  /// a customer or lead. See [_visibleRows] for that case.
  static String? _visibleFilter(String field) {
    final peers = Session.I.unitPeers;
    if (peers.isEmpty) return null;
    return peers.length == 1
        ? '["$field","=","${peers.first}"]'
        : '["$field","in",${_inList(peers)}]';
  }

  /// The territories this rep's unit covers — its root and everything under
  /// it. Empty when the unit has no configured root, or on any failure, which
  /// callers must read as "widen to nothing" rather than "widen to all".
  static Future<List<String>> _poolTerritories() async {
    final root = kUnitTerritoryRoot[Session.I.company ?? ''];
    if (root == null || root.isEmpty) return const [];
    try {
      final rows = await _list('Territory',
          fields: '["name","parent_territory"]', orderBy: 'name asc');
      return territorySubtree(
          rows.map(TerritoryNode.fromRow).toList(), root);
    } catch (_) {
      return const [];
    }
  }

  /// Records this rep may SEE, by owner field — the pool's own rows plus, in
  /// a pool, the unclaimed records ON THAT POOL'S OWN ROUTES. Empty when
  /// nothing can be scoped by, which callers must treat as "show nothing",
  /// never everyone.
  ///
  /// Two queries, not one: Frappe stores an omitted Link/Data field as SQL
  /// `NULL`, not `''` — verified live on 18 Aug 2026 by inserting a Customer
  /// with the field untouched and reading it back. `field IN (...)` can never
  /// match `NULL`, in any SQL, whatever is in the list — there is no way to
  /// fold "unassigned" into a single `in` filter. `is not set` is what
  /// actually catches it, and empty string too, which Frappe treats the same
  /// way there.
  ///
  /// **The second query is scoped by territory, and that scoping is the
  /// point.** Without it `is not set` answers with every unowned record in
  /// the company, so a UAE rep was shown India's unassigned customers and
  /// leads — exactly the cross-unit leak `visibleReps` exists to prevent,
  /// walked straight around by the widening that was meant to help.
  ///
  /// Territory rather than route, because the UAE parties were imported with
  /// no rep *and* no route: the territory is the only thing on such a record
  /// that says which side of the business it belongs to. A unit with no
  /// configured territory root widens to nothing rather than to everything.
  static Future<List<Map<String, dynamic>>> _visibleRows(
    String doctype,
    String field, {
    required String fields,
    String orderBy = 'creation desc',
  }) async {
    final peers = Session.I.unitPeers;
    if (peers.isEmpty) return const [];

    final owned = await _list(doctype,
        fields: fields,
        filters: peers.length == 1
            ? '[["$field","=","${peers.first}"]]'
            : '[["$field","in",${_inList(peers)}]]',
        orderBy: orderBy);

    if (!isPooledUnit(Session.I.company)) return owned;

    final territories = await _poolTerritories();
    if (territories.isEmpty) return owned;

    final unclaimed = await _list(doctype,
        fields: fields,
        filters: '[["$field","is","not set"],'
            '["$kFieldPartyTerritory","in",${_inList(territories)}]]',
        orderBy: orderBy);

    final seen = owned.map((r) => '${r['name']}').toSet();
    return [...owned, ...unclaimed.where((r) => !seen.contains('${r['name']}'))];
  }

  // -------- Manager context --------
  static Future<void> resolveManagerContext() async {
    Session.I.managedTeam = null;
    Session.I.managedTeamCompany = null;
    Session.I.teamReps = [];
    Session.I.isGM = false;
    Session.I.isHR = false;
    Session.I.isProductionManager = false;
    Session.I.isStockManager = false;
    Session.I.productionCompany = null;
    final user = await _loggedUser();
    if (user == null) return;
    try {
      final r = await Session.I.dio.get(_res('User') + '/$user',
          queryParameters: {
            'fields': '["custom_managed_team","custom_is_general_manager","custom_is_hr_manager","custom_is_production_manager","custom_is_stock_manager","custom_production_company"]'
          });
      final data = (r.data is Map && r.data['data'] is Map)
          ? r.data['data'] as Map
          : const {};
      final team = data['custom_managed_team'];
      Session.I.isGM = (data['custom_is_general_manager'] ?? 0) == 1;
      Session.I.isHR = (data['custom_is_hr_manager'] ?? 0) == 1;
      Session.I.isProductionManager =
          (data['custom_is_production_manager'] ?? 0) == 1;
      Session.I.isStockManager = (data['custom_is_stock_manager'] ?? 0) == 1;
      final pc = data['custom_production_company'];
      if (pc is String && pc.isNotEmpty) Session.I.productionCompany = pc;
      if (team is String && team.isNotEmpty) {
        Session.I.managedTeam = team;
        final reps = await _list('Sales Person',
            fields: '["name","custom_company"]',
            filters: '[["custom_team_manager","=","$team"]]',
            orderBy: 'name asc');
        Session.I.teamReps = reps.map((e) => e['name'] as String).toList();
        // Which unit this manager belongs to, taken from their own team rather
        // than from a hardcoded list that would go stale the first time a
        // manager moves. A manager who is also a Sales Person already has a
        // company of their own; this covers the ones who are not.
        for (final r in reps) {
          final c = r['custom_company'];
          if (c is String && c.isNotEmpty) {
            Session.I.managedTeamCompany = c;
            break;
          }
        }
      }
    } catch (_) {}
  }

  static String _inList(List<String> xs) =>
      '[${xs.map((e) => '"${e.replaceAll('"', '')}"').join(',')}]';

  // -------- Approvals (team-scoped) --------
  static Future<List<Map<String, dynamic>>> getPendingLeadOrderApprovals() {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    return _list('Lead Order',
        fields:
        '["name","lead_name","sales_person","order_date","total_amount","status"]',
        filters:
        '[["status","=","Pending Approval"],["sales_person","in",${_inList(team)}]]',
        orderBy: 'creation desc');
  }

  static Future<List<Map<String, dynamic>>> getPendingLeadOrderPOs() {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    return _list('Lead Order',
        fields:
        '["name","lead_name","sales_person","order_date","total_amount","status","po_number"]',
        filters:
        '[["status","=","PO Uploaded"],["sales_person","in",${_inList(team)}]]',
        orderBy: 'creation desc');
  }

  /// Orders waiting on this manager.
  ///
  /// Reps no longer scan a signed purchase order, so an order lands here the
  /// moment it is raised. `PO Uploaded - Pending Approval` is still matched so
  /// that anything raised under the old flow, before the scan step was removed,
  /// does not get stranded in a queue nobody reads.
  static Future<List<Map<String, dynamic>>> getPendingSalesOrderPOs() {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    const waiting =
        '["Pending Approval","Pending Rate Approval","PO Uploaded - Pending Approval"]';
    return _list('Sales Order',
        fields:
        '["name","customer","custom_sales_person","grand_total","custom_po_status","custom_po_number"]',
        filters:
        '[["custom_po_status","in",$waiting],["custom_sales_person","in",${_inList(team)}]]',
        orderBy: 'creation desc');
  }

  /// Every order this manager's team raised in a date range, whatever its
  /// state.
  ///
  /// The approvals queue only ever shows work outstanding, so an order used to
  /// vanish the moment it was approved and there was nowhere to see what had
  /// happened to it. This is that view: decided and undecided together, with
  /// the production status the factory has since put on it.
  /// Every order the team raised in a week — against customers and leads.
  ///
  /// Lead orders were missing here, and this is the screen a manager actually
  /// uses to approve: they only appeared in the general approvals inbox, so a
  /// lead order sat waiting where nobody was looking for it.
  ///
  /// Mapped onto the Sales Order shape, because the card and the "waiting on
  /// you" count both read `custom_po_status`. A Lead Order's `status` carries
  /// the same three states under different names.
  static Future<List<Map<String, dynamic>>> getTeamOrders({
    required String from,
    required String to,
  }) async {
    final team = Session.I.teamReps;
    if (team.isEmpty) return [];

    final results = await Future.wait([
      _list('Sales Order',
          fields: '["name","customer","custom_sales_person","grand_total",'
              '"transaction_date","delivery_date","custom_po_status",'
              '"custom_rate_approved","custom_production_status",'
              '"custom_production_finish_date","custom_proforma_status",'
              '"custom_combined_order"]',
          filters: '[["custom_sales_person","in",${_inList(team)}],'
              '["transaction_date",">=","$from"],'
              '["transaction_date","<=","$to"]]',
          orderBy: 'transaction_date desc'),
      // A lead order failing must not cost the manager their Sales Orders.
      _list('Lead Order',
          fields: '["name","lead","lead_name","sales_person","total_amount",'
              '"order_date","delivery_date","status","custom_rate_approved"]',
          filters: '[["sales_person","in",${_inList(team)}],'
              '["order_date",">=","$from"],'
              '["order_date","<=","$to"]]',
          orderBy: 'order_date desc').catchError(
          (_) => <Map<String, dynamic>>[]),
    ]);

    final rows = <Map<String, dynamic>>[...results[0]];
    for (final l in results[1]) {
      final status = '${l['status'] ?? ''}';
      rows.add({
        ...l,
        'is_lead': true,
        'customer': l['lead_name'] ?? l['lead'],
        'custom_sales_person': l['sales_person'],
        'grand_total': l['total_amount'],
        'transaction_date': l['order_date'],
        // `orderApproved` reads this exact string, and it is what decides
        // whether the card counts as still waiting on the manager.
        'custom_po_status': status == 'Approved'
            ? 'PO Approved - Ready for SAP'
            : status,
      });
    }
    rows.sort((a, b) => '${b['transaction_date'] ?? ''}'
        .compareTo('${a['transaction_date'] ?? ''}'));
    return rows;
  }

  static Future<List<Map<String, dynamic>>> getPendingProformaReleases() {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    return _list('Sales Order',
        fields:
        '["name","customer","custom_sales_person","grand_total","custom_proforma_status"]',
        filters:
        '[["custom_proforma_status","=","Pending Release Approval"],["custom_sales_person","in",${_inList(team)}]]',
        orderBy: 'creation desc');
  }

  static Future<List<Map<String, dynamic>>> getPendingLocationVerifications() {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    return _list('Customer',
        fields:
        '["name","customer_name","custom_location_captured_by","custom_latitude","custom_longitude","custom_banner_photo"]',
        filters:
        '[["custom_location_status","=","Pending Verification"],["custom_location_captured_by","in",${_inList(team)}]]',
        orderBy: 'modified desc');
  }

  static Future<void> _put(String doctype, String name,
      Map<String, dynamic> body) async {
    final r =
    await Session.I.dio.put(_res(doctype) + '/$name', data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
  }

  /// Turns a lead into a customer at the moment its first order is approved.
  ///
  /// This is the point the business already treats as conversion — a lead
  /// becomes a customer when it is first invoiced, and approval is what makes
  /// the invoice inevitable. Doing it here rather than at order-taking keeps
  /// unapproved prospects out of the customer master entirely.
  ///
  /// GSTIN is the join key. Accounts will create the same party in SAP by hand
  /// afterwards, and the eventual sync matches ERPNext to SAP on the GST
  /// number — so two customers sharing one GSTIN would make that match
  /// ambiguous. An existing customer with the same GSTIN is therefore reused
  /// rather than duplicated, which also makes this safe to call twice.
  ///
  /// Returns the customer's name.
  static Future<String> convertLeadToCustomer(String leadName) async {
    final lead = await getLeadDoc(leadName);

    final missing = missingLeadDetails(lead);
    if (missing.isNotEmpty) {
      throw Exception(
          'Lead is missing ${missing.join(', ')} — cannot convert.');
    }

    final gstin = '${lead['custom_gstin']}'.trim().toUpperCase();
    final existing = await _list('Customer',
        fields: '["name"]',
        filters: '[["custom_gstin","=","$gstin"]]',
        limit: 1);
    if (existing.isNotEmpty) {
      await _put('Lead', leadName, {'status': 'Converted'});
      return '${existing.first['name']}';
    }

    final rep = '${lead['custom_sales_person'] ?? Session.I.salesPerson ?? ''}';
    final body = <String, dynamic>{
      'customer_name':
          '${lead['company_name'] ?? ''}'.trim().isNotEmpty
              ? '${lead['company_name']}'.trim()
              : '${lead['lead_name']}'.trim(),
      'customer_type': 'Company',
      // Records where the customer came from, so the trail survives even
      // though the Lead keeps existing.
      'lead_name': leadName,
      'custom_gstin': gstin,
      'custom_address': '${lead['custom_address'] ?? ''}',
      'custom_sales_route': '${lead['custom_sales_route'] ?? ''}',
      'custom_phone': '${lead['mobile_no'] ?? ''}',
      // A Link field: the bare Sales Person name, or nothing. Writing the old
      // "|Rep|" form would fail the link check outright.
      if (rep.isNotEmpty) 'custom_assigned_reps': rep,
      // The shop location the rep captured against the lead should not have to
      // be captured again just because the record changed type.
      'custom_latitude': lead['custom_latitude'],
      'custom_longitude': lead['custom_longitude'],
      'custom_verified_latitude': lead['custom_verified_latitude'],
      'custom_verified_longitude': lead['custom_verified_longitude'],
      'custom_location_status':
          '${lead['custom_location_status'] ?? 'Not Captured'}',
    };

    final territory = '${lead['territory'] ?? ''}';
    if (territory.isNotEmpty && territory != 'null') {
      body['territory'] = territory;
    }
    // customer_group is mandatory and the lead has none, so fall back to
    // whatever the site's first group is rather than failing the conversion.
    try {
      final groups = await getCustomerGroups();
      if (groups.isNotEmpty) body['customer_group'] = groups.first;
    } catch (_) {}

    final r = await Session.I.dio.post(_res('Customer'), data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
    final created = '${r.data['data']['name']}';
    await _put('Lead', leadName, {'status': 'Converted'});
    return created;
  }

  /// Approves a lead order: converts the lead, then raises the real Sales Order.
  ///
  /// The third step is the one that was missing. A Lead Order is an app-only
  /// record — the production dashboard reads Sales Orders and nothing else — so
  /// an approved lead order used to be a dead end: the lead became a customer,
  /// the order said Approved, and the factory never heard about it. Approval
  /// now produces the Sales Order that carries the work to the floor.
  ///
  /// The sequence is deliberate. Convert first, because a Sales Order needs a
  /// customer to belong to; raise the order second; mark the lead order
  /// approved last, so its status is only ever set once there is something
  /// real behind it. A failure part-way leaves the lead order pending and
  /// re-approvable — which is recoverable, unlike an order marked approved with
  /// nothing downstream.
  static Future<String?> approveLeadOrder(String name, bool approve) async {
    if (!approve) {
      await _put('Lead Order', name, {'status': 'Rejected'});
      return null;
    }

    final doc = await getLeadOrder(name);
    final leadName = '${doc['lead'] ?? ''}';

    String? customer;
    if (leadName.isNotEmpty && leadName != 'null') {
      customer = await convertLeadToCustomer(leadName);
    }

    String? salesOrder;
    if (customer != null) {
      salesOrder = await _salesOrderFromLeadOrder(doc, customer);
    }

    await _put('Lead Order', name, {
      'status': 'Approved',
      if (salesOrder != null) 'sales_order': salesOrder,
      if (customer != null)
        'approval_remarks': 'Converted to customer $customer'
            '${salesOrder != null ? ', raised as $salesOrder' : ''}',
    });
    return customer;
  }

  /// Raises the Sales Order behind an approved lead order.
  ///
  /// Created already approved, because the manager approving the lead order is
  /// the same decision they would make on a Sales Order — sending it back to
  /// their own queue would ask them to approve the same order twice.
  ///
  /// Two things a rep's order carries that this one cannot yet: the per-family
  /// roll and belt breakdown, and minimum-stock bookings. `Lead Order Item`
  /// holds only item_code, qty and rate, so there is nothing to map them from
  /// and no reservation to move across. A lead order therefore always reads as
  /// new production. Widening `Lead Order Item` to match `Sales Order Item` is
  /// what closes that gap; until then this is honest about what it knows.
  static Future<String?> _salesOrderFromLeadOrder(
      Map<String, dynamic> leadOrder, String customer) async {
    final rows = (leadOrder['items'] as List?) ?? const [];
    final items = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r is! Map) continue;
      final code = '${r['item_code'] ?? ''}'.trim();
      final qty = (r['qty'] as num?)?.toDouble() ?? 0;
      if (code.isEmpty || qty <= 0) continue;
      // Everything the rep entered comes across. `Lead Order Item` now carries
      // the same per-family breakdown as `Sales Order Item`, so a converted
      // order reaches production knowing it is 12 rolls and 3 loose belts —
      // not just a quantity of 12.75.
      // A discount the manager gave on the lead order used to come across
      // here, changing fields on the way — the lead's custom pair became the
      // standard ERPNext pair — because dropping it would have invoiced the
      // customer the full rate the discount had replaced. The discount feature
      // was removed on 17 September 2026 and the rep's rate is already net, so
      // there is one figure to carry and the standard fields are written flat.
      items.add({
        'item_code': code,
        'qty': qty,
        'rate': (r['rate'] as num?)?.toDouble() ?? 0,
        'price_list_rate': (r['rate'] as num?)?.toDouble() ?? 0,
        'discount_percentage': 0,
        'discount_amount': 0,
        'custom_product_category': r['custom_product_category'],
        'custom_rolls': r['custom_rolls'],
        'custom_loose_belts': r['custom_loose_belts'],
        'custom_boxes': r['custom_boxes'],
        'custom_cans': r['custom_cans'],
        'custom_total_weight': r['custom_total_weight'],
        'custom_rate_per_kg': r['custom_rate_per_kg'],
        'custom_packing_note': r['custom_packing_note'],
        'custom_fulfilment_mode': r['custom_fulfilment_mode'],
        if (r['custom_aged_batch'] != null)
          'custom_aged_batch': r['custom_aged_batch'],
        // The manager has just approved, so every line's price is final.
        'custom_rate_approved': 1,
      });
    }
    // An order with no usable lines would create an empty Sales Order that
    // production could do nothing with.
    if (items.isEmpty) return null;

    final company = await getCompany();
    final unit = Session.I.company ?? Session.I.managedTeamCompany;
    final delivery = '${leadOrder['delivery_date'] ?? ''}';
    final body = <String, dynamic>{
      'customer': customer,
      'company': company,
      'custom_sales_person': leadOrder['sales_person'] ?? Session.I.salesPerson,
      if (unit != null && unit.isNotEmpty) 'custom_company': unit,
      // The date the customer actually asked for, carried across rather than
      // invented — the rep agreed it with them when the order was taken.
      'delivery_date': delivery.length >= 10
          ? delivery.substring(0, 10)
          : serverNow()
              .add(const Duration(days: 7))
              .toIso8601String()
              .substring(0, 10),
      'custom_proforma_required': 1,
      'custom_proforma_status': 'Ready',
      // Straight to approved — see above.
      'custom_po_status': 'PO Approved - Ready for SAP',
      'custom_rate_approved': 1,
      // The moment the order was raised against the lead, not the moment it was
      // approved. This is what settles who ordered first when stock is short,
      // so it has to be the rep's timestamp rather than the manager's.
      'custom_order_placed_at':
          '${leadOrder['custom_order_placed_at'] ?? leadOrder['creation'] ?? nowStamp()}'
              .substring(0, 19),
      'items': items,
    };

    final r = await Session.I.dio.post(_res('Sales Order'), data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
    final created = '${r.data['data']['name']}';


    return created;
  }

  static Future<void> approveLeadOrderPO(String name, bool approve) => _put(
      'Lead Order',
      name,
      {'status': approve ? 'PO Approved - Ready for SAP' : 'Rejected'});

  /// The manager's decision on an order.
  ///
  /// Approving also stamps `custom_rate_approved`, which is what locks the
  /// manually typed rates on the rep's phone — approving an order *is*
  /// approving what it is being sold at.
  ///
  /// The approved value is still `PO Approved - Ready for SAP`. Nothing scans a
  /// purchase order any more, but that string is what the production dashboard,
  /// the monthly sales figures and every existing record already key off, so it
  /// is left alone and only the label the rep sees has changed.
  /// How the sales manager decided one line will be served.
  ///
  /// The decision belongs to the line, not the order: an order can hold six
  /// products that are all in stock, and the manager may want two of them off
  /// the shelf now and the rest made to order.
  ///
  /// It is a **note for production**, and nothing more. It used to book and
  /// release stock as it was switched; SAP commits stock against its own sales
  /// order now, so the shelf moves when the order reaches SAP and not when the
  /// manager labels a line.
  ///
  /// Works for an order against a customer or against a lead — the same
  /// decision either way.
  static Future<void> setLineFulfilmentMode({
    required String orderName,
    required String itemCode,
    required String mode,
    bool isLead = false,
  }) async {
    final ref = OrderRef(orderName, isLead: isLead);
    final order = isLead ? await getLeadOrder(orderName) : await getOrder(orderName);
    // Checked against the order as stored, not as the screen last saw it.
    //
    // Approval is the lock: where a line is served from only matters when
    // production receives the order, and approval is that moment. The two
    // below it are backstops for states that should not be reachable without
    // approval.
    //
    // A lead order has no approval status of this kind, so the gate applies to
    // Sales Orders.
    if (isOrderComplete(order)) {
      throw Exception('This order has been dispatched. Where its lines were '
          'served from can no longer be changed.');
    }
    if (!isLead && orderApproved(order)) {
      throw Exception('This order is approved and production is working to it. '
          'Where its lines are served from can no longer be changed.');
    }
    if (!orderEditWindowOpen(order['delivery_date'])) {
      throw Exception(orderLockReason(order));
    }
    final items = ((order['items'] as List?) ?? [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();

    for (final it in items) {
      if ('${it['item_code']}' == itemCode) it['custom_fulfilment_mode'] = mode;
    }

    await _put(ref.doctype, orderName, {'items': items});
  }

  /*
   * `setLineDiscount` stood here until 17 September 2026.
   *
   * The sales manager could put a percentage off any line, or take it off with
   * zero, and it was written the moment it was confirmed rather than held
   * until approval. It refused once the rates were approved — the rule the
   * manager was told at approval, "nobody, including you, can change them
   * afterwards", and a discount is a change to the rate whatever it is called.
   *
   * The whole feature is gone from both apps. The sales team types the rate
   * AFTER discount, so a line carries one figure instead of three, and that is
   * what reaches SAP: `Sync-SapOrders.ps1` sends `amount / custom_total_weight`
   * with DiscountPercent always 0.
   *
   * Lines saved before that keep whatever `discount_percentage` they were
   * written with. Nothing displays or re-applies it, and their `amount` was
   * always the net figure, so they still price correctly.
   */

  static Future<void> approveSalesOrderPO(String name, bool approve) async {
    final body = <String, dynamic>{
      'custom_po_status': approve ? 'PO Approved - Ready for SAP' : 'Rejected',
      'custom_rate_approved': approve ? 1 : 0,
    };

    // Approval is per line as well as per order. Stamping each line is what
    // lets the app tell an approved price from one the rep added afterwards,
    // and it is the only reason a new line can still be typed into an order
    // whose other rates are frozen.
    if (approve) {
      try {
        final order = await getOrder(name);
        final items = (order['items'] as List?) ?? [];
        body['items'] = [
          for (final raw in items)
            {
              ...(raw as Map).cast<String, dynamic>(),
              'custom_rate_approved': 1,
            }
        ];
      } catch (_) {
        // Falling back to the order-level flag alone still locks the rates —
        // it just cannot distinguish a line added later. Better than refusing
        // to record the manager's decision.
      }
    }

    await _put('Sales Order', name, body);
  }

  static Future<void> releaseProforma(String name, bool approve) => _put(
      'Sales Order',
      name,
      {'custom_proforma_status': approve ? 'Released' : 'Blocked - Credit'});

  // Approve a captured customer location: copy captured coords into the
  // verified fields so the 100 m check-in works against them. Reject sends
  // it back to "Not Captured" so the rep can re-capture.
  static Future<void> approveLocation(
      String name, bool approve, dynamic lat, dynamic lng) {
    if (approve) {
      return _put('Customer', name, {
        'custom_location_status': 'Verified',
        'custom_verified_latitude': lat,
        'custom_verified_longitude': lng,
      });
    }
    return _put('Customer', name, {'custom_location_status': 'Not Captured'});
  }

  static Future<void> captureLeadLocation({
    required String lead,
    required String salesPerson,
    required double lat,
    required double lng,
  }) async {
    await _put('Lead', lead, {
      'custom_latitude': lat,
      'custom_longitude': lng,
      'custom_location_status': _capturedStatus,
      'custom_location_captured_by': salesPerson,
      if (_selfVerifies) ...{
        'custom_verified_latitude': lat,
        'custom_verified_longitude': lng,
      },
    });
  }

  static Future<List<Map<String, dynamic>>>
  getPendingLeadLocationVerifications() {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    return _list('Lead',
        fields:
        '["name","lead_name","custom_location_captured_by","custom_latitude","custom_longitude","custom_banner_photo"]',
        filters:
        '[["custom_location_status","=","Pending Verification"],["custom_location_captured_by","in",${_inList(team)}]]',
        orderBy: 'modified desc');
  }

  static Future<void> approveLeadLocation(
      String name, bool approve, dynamic lat, dynamic lng) {
    if (approve) {
      return _put('Lead', name, {
        'custom_location_status': 'Verified',
        'custom_verified_latitude': lat,
        'custom_verified_longitude': lng,
      });
    }
    return _put('Lead', name, {'custom_location_status': 'Rejected'});
  }

  // ---- Logged-in rep's own target (shown on their home dashboard) ----
  static Future<Map<String, dynamic>?> getMyTarget() async {
    final me = Session.I.salesPerson;
    if (me == null) return null;
    final now = DateTime.now();
    final month = monthNames[now.month - 1];
    final list = await _list('Sales Target',
        fields: '["name","target_amount","target_unit"]',
        filters:
        '[["sales_person","=","$me"],["month","=","$month"],["year","=",${now.year}]]',
        limit: 1);
    return list.isEmpty ? null : list.first;
  }

  // Rep currency: AED for the UAE (Renjith) team, INR otherwise.
  static Future<String> myCurrency() async {
    final me = Session.I.salesPerson;
    if (me == null) return 'INR';
    final sp = await _list('Sales Person',
        fields: '["custom_team_manager"]',
        filters: '[["name","=","$me"]]',
        limit: 1);
    final mgr =
    sp.isNotEmpty ? (sp.first['custom_team_manager'] ?? '').toString() : '';
    return mgr == 'Renjith' ? 'AED' : 'INR';
  }

  // -------- Targets --------
  static List<String> get monthNames => const [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  static Future<List<Map<String, dynamic>>> getTargets(
      String month, int year) {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    return _list('Sales Target',
        fields:
        '["name","sales_person","month","year","target_amount","target_unit"]',
        filters:
        '[["month","=","$month"],["year","=",$year],["sales_person","in",${_inList(team)}]]',
        orderBy: 'sales_person asc');
  }

  // UAE team (Renjith) targets in AED; India teams (Saneesh/Pareeth) in INR.
  static String get teamCurrency =>
      Session.I.managedTeam == 'Renjith' ? 'AED' : 'INR';

  static Future<void> upsertTarget({
    required String salesPerson,
    required String month,
    required int year,
    required double amount,
    required String unit,
  }) async {
    final existing = await _list('Sales Target',
        fields: '["name"]',
        filters:
        '[["sales_person","=","$salesPerson"],["month","=","$month"],["year","=",$year]]',
        limit: 1);
    if (existing.isNotEmpty) {
      await _put('Sales Target', existing.first['name'] as String,
          {'target_amount': amount, 'target_unit': unit});
    } else {
      final r = await Session.I.dio.post(_res('Sales Target'), data: {
        'sales_person': salesPerson,
        'month': month,
        'year': year,
        'target_amount': amount,
        'target_unit': unit,
        'set_by': Session.I.managedTeam,
      });
      if (r.statusCode != 200 && r.statusCode != 201) {
        throw Exception(_frappeError(r));
      }
    }
  }

  static Future<double> getMonthCollections(String rep) async {
    final list = await _list('Collection Entry',
        fields: '["amount"]',
        filters:
        '[["sales_person","=","$rep"],["collection_date","Timespan","this month"]]');
    double t = 0;
    for (final e in list) {
      t += ((e['amount'] ?? 0) as num).toDouble();
    }
    return t;
  }

  // Sales achieved this month = manager-approved POs (ready for SAP),
  // across both Sales Orders and Lead Orders for this rep.
  static Future<double> getMonthSales(String rep) async {
    double t = 0;
    final so = await _list('Sales Order',
        fields: '["grand_total"]',
        filters:
        '[["custom_sales_person","=","$rep"],["custom_po_status","=","PO Approved - Ready for SAP"],["transaction_date","Timespan","this month"]]');
    for (final e in so) {
      t += ((e['grand_total'] ?? 0) as num).toDouble();
    }
    final lo = await _list('Lead Order',
        fields: '["total_amount"]',
        filters:
        '[["sales_person","=","$rep"],["status","=","PO Approved - Ready for SAP"],["order_date","Timespan","this month"]]');
    for (final e in lo) {
      t += ((e['total_amount'] ?? 0) as num).toDouble();
    }
    return t;
  }

  // Rep's total outstanding = sum of outstanding across customers assigned to
  // that rep. `custom_assigned_reps` is a Link to Sales Person.
  static Future<double> getRepOutstanding(String rep) async {
    final list = await _list('Customer',
        fields: '["custom_outstanding_balance"]',
        filters: '[["custom_assigned_reps","=","$rep"]]',
        limit: 0);
    double t = 0;
    for (final e in list) {
      t += ((e['custom_outstanding_balance'] ?? 0) as num).toDouble();
    }
    return t;
  }

  static Future<double> getRepOutstandingLimit(String rep) async {
    final l = await _list('Sales Person',
        fields: '["custom_outstanding_limit"]',
        filters: '[["name","=","$rep"]]',
        limit: 1);
    if (l.isEmpty) return 0;
    return ((l.first['custom_outstanding_limit'] ?? 0) as num).toDouble();
  }

  static Future<double> getCustomerOutstanding(String customer) async {
    final l = await _list('Customer',
        fields: '["custom_outstanding_balance"]',
        filters: '[["name","=","$customer"]]',
        limit: 1);
    if (l.isEmpty) return 0;
    return ((l.first['custom_outstanding_balance'] ?? 0) as num).toDouble();
  }

  static Future<double> getCustomerCreditLimit(String customer) async {
    final l = await _list('Customer',
        fields: '["custom_credit_limit"]',
        filters: '[["name","=","$customer"]]',
        limit: 1);
    if (l.isEmpty) return 0;
    return ((l.first['custom_credit_limit'] ?? 0) as num).toDouble();
  }

  static Future<void> upsertOutstandingLimit(String rep, double amount) =>
      _put('Sales Person', rep, {'custom_outstanding_limit': amount});

  // Escalation: manager approved but rep is over their outstanding limit ->
  // needs General Manager approval before it can go to SAP.
  static Future<void> escalateSalesOrderPOToGM(String name) =>
      _put('Sales Order', name, {'custom_po_status': 'Pending GM Approval'});

  static Future<void> escalateLeadOrderPOToGM(String name) =>
      _put('Lead Order', name, {'status': 'Pending GM Approval'});

  // GM queues: anything sitting at "Pending GM Approval".
  static Future<List<Map<String, dynamic>>> getPendingGMSalesOrderPOs() =>
      _list('Sales Order',
          fields:
          '["name","customer","custom_sales_person","grand_total","custom_po_status"]',
          filters: '[["custom_po_status","=","Pending GM Approval"]]',
          orderBy: 'creation desc');

  static Future<List<Map<String, dynamic>>> getPendingGMLeadOrderPOs() =>
      _list('Lead Order',
          fields: '["name","lead_name","sales_person","total_amount","status"]',
          filters: '[["status","=","Pending GM Approval"]]',
          orderBy: 'creation desc');


  // `item_group` is what sorts an Item into a product family, and the custom
  // fields alongside it are what each family's order row needs to turn rolls
  // and belts into a weight. `standard_rate` is still read, but only ever as a
  // hint on screen — reps price every line by hand.
  /// Sellable items, narrowed to the ones this rep's unit actually sells.
  ///
  /// Manna Treads, Manna Tyre Retreads and Manna Tyres UAE do not share a
  /// catalogue, and a rep shown another unit's products will eventually sell
  /// one. The unit list lives on the Item as a pipe-wrapped string — one item
  /// can be sold by several units, so it cannot be a Link. (`custom_assigned_reps`
  /// on Customer used to follow the same convention and is now a Link, so do
  /// not take it as the example any more.)
  ///
  /// Filtering happens here rather than in the query because an item with no
  /// units set has to stay visible to everyone — that is the state every
  /// existing item is in today, and dropping them would empty the catalogue.
  static Future<List<Map<String, dynamic>>> getItems() async {
    // The catalogue is the slowest-changing thing the app reads and the thing
    // every order screen needs, so it is cached under one key for all units —
    // the per-unit filter below is applied after, on whatever copy we have.
    final all = await _cachedRows(
        CacheKeys.items,
        () => _list('Item',
            fields:
                '["name","item_name","stock_uom","standard_rate","item_group",'
                    '"custom_units","custom_avg_weight_per_roll",'
                    '"custom_belts_per_roll","custom_weight_per_roll",'
                    '"custom_pack_litres"]',
            filters: '[["disabled","=",0],["is_sales_item","=",1]]',
            orderBy: 'item_name asc'));
    final unit = Session.I.company;
    if (unit == null || unit.trim().isEmpty) return all;
    return all.where((it) => sellsInUnit(it['custom_units'], unit)).toList();
  }

  /// True when an item belongs to [unit]. An item with no units recorded
  /// belongs to all of them, so an incomplete product import degrades to the
  /// old behaviour rather than to an empty product list.
  static bool sellsInUnit(dynamic units, String unit) {
    final s = '${units ?? ''}'.trim();
    if (s.isEmpty || s == 'null') return true;
    return s.toLowerCase().contains('|${unit.trim().toLowerCase()}|');
  }

  // ------------------------------------------------------------- stock ---
  //
  // Read-only. Booking used to live here — `reserveMinimumStock`,
  // `releaseReservations`, the production-run counters — and every one of
  // those wrote to doctypes this app no longer uses. SAP commits stock against
  // its own sales orders and the stock sync brings back what is left, so there
  // is nothing for the app to reserve and no counter for it to keep. See the
  // note at the top of `services/stock_service.dart`.

  /// What every item has available to promise, straight from SAP.
  static Future<Map<String, MinStock>> getMinimumStock() =>
      StockService.load();

  /// The same figures with each item's product record alongside.
  ///
  /// The product join runs through [getItems], so the same unit filter applies
  /// — a rep is not shown another unit's stock position any more than they are
  /// shown its catalogue. A stocked item with no matching product record is
  /// dropped rather than rendered as a bare code.
  static Future<List<MinStockDetail>> getMinimumStockDetailed() async {
    final results = await Future.wait([StockService.load(), getItems()]);
    final stock = results[0] as Map<String, MinStock>;
    if (stock.isEmpty) return [];
    final items = results[1] as List<Map<String, dynamic>>;

    final out = <MinStockDetail>[];
    for (final doc in items) {
      final s = stock['${doc['name']}'];
      if (s != null) out.add(MinStockDetail(stock: s, product: Product(doc)));
    }

    // Alphabetical, because the rep is looking something up rather than being
    // steered. This sorted worst-moving first until 21 August 2026 — the point
    // of the aging list was to float items drifting towards dead stock to the
    // top, and with that feature gone the ordering was a ranking of a thing
    // nobody is shown.
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  static Future<List<String>> getCustomerGroups() async {
    final l = await _list('Customer Group',
        fields: '["name"]',
        filters: '[["is_group","=",0]]',
        orderBy: 'name asc');
    return l.map((e) => e['name'] as String).toList();
  }

  // Routes (leaf Territories) a rep should actually be offered.
  //
  // Territory is a tree, and the UAE routes hang off a different top-level
  // group than the Indian ones — so listing every leaf drops both regions into
  // one dropdown. Anchor instead on the routes the rep's own customers and
  // leads already sit on, walk each up to its top-level group, and keep only
  // the leaves under those groups. A Kerala rep never sees a Dubai route, and
  // routes in their own region that they have not worked yet still show up.
  //
  // Pass [forRep] to scope to someone else — the day map does this so a
  // manager viewing a UAE rep gets that rep's routes, not their own.
  static Future<List<String>> getRoutes({String? forRep}) async {
    final tree = await _list('Territory',
        fields: '["name","is_group","parent_territory"]', orderBy: 'name asc');
    final parent = <String, String>{};
    final leaves = <String>[];
    for (final t in tree) {
      final name = '${t['name'] ?? ''}';
      if (name.isEmpty) continue;
      final p = '${t['parent_territory'] ?? ''}';
      if (p.isNotEmpty) parent[name] = p;
      if ('${t['is_group'] ?? 0}' != '1') leaves.add(name);
    }

    final rep = forRep ?? Session.I.salesPerson;
    if (rep == null || rep.isEmpty) return leaves;

    // Nothing on the rep's book yet means no region to infer — show them
    // everything rather than an empty dropdown.
    final regions = (await _repTerritories(rep))
        .map((t) => _regionOf(t, parent))
        .where((r) => r.isNotEmpty)
        .toSet();
    if (regions.isEmpty) return leaves;

    final scoped =
        leaves.where((l) => regions.contains(_regionOf(l, parent))).toList();
    return scoped.isEmpty ? leaves : scoped;
  }

  // The top-level group a territory sits under — 'UAE' or 'India', not the
  // 'All Territories' root. Stopping one short of the root is what keeps the
  // regions apart. A flat tree with no region groups degrades to the territory
  // itself, which still scopes the dropdown to what the rep actually works.
  static String _regionOf(String territory, Map<String, String> parent) {
    var cur = territory;
    final seen = <String>{};
    while (seen.add(cur)) {
      final p = parent[cur];
      if (p == null || p.isEmpty) return cur; // cur is the root
      final gp = parent[p];
      if (gp == null || gp.isEmpty) return cur; // cur's parent is the root
      cur = p;
    }
    return cur; // a cycle in the tree — bail out rather than spin
  }

  // Every route the rep is already working, from both sides of their book.
  static Future<Set<String>> _repTerritories(String rep) async {
    Future<List<Map<String, dynamic>>> pull(String doctype, String filters) async {
      try {
        return await _list(doctype,
            fields: '["territory"]', filters: filters, orderBy: 'modified desc');
      } catch (_) {
        // One side failing shouldn't cost us the other side's routes.
        return const [];
      }
    }

    final res = await Future.wait([
      pull('Customer', '[["custom_assigned_reps","=","$rep"]]'),
      pull('Lead', '[["custom_sales_person","=","$rep"]]'),
    ]);
    return res
        .expand((l) => l)
        .map((e) => '${e['territory'] ?? ''}')
        .where((t) => t.isNotEmpty)
        .toSet();
  }

  // Every customer on one route (Territory), regardless of which rep they are
  // assigned to — the day map uses this to draw the whole route.
  static Future<List<Map<String, dynamic>>> getCustomersInTerritory(
      String territory) {
    return _list('Customer',
        fields:
        '["name","customer_name","customer_group","territory","custom_latitude","custom_longitude","custom_phone"]',
        filters: '[["territory","=","$territory"]]',
        orderBy: 'customer_name asc');
  }

  // Leads that have had their location captured — the day map draws these as
  // an overlay. Pass a route (Territory) to narrow it to that route's leads.
  static Future<List<Map<String, dynamic>>> getLeadsWithLocation(
      {String? territory}) {
    final f = <String>['["custom_latitude","is","set"]'];
    if (territory != null && territory.isNotEmpty) {
      f.add('["territory","=","$territory"]');
    }
    return _list('Lead',
        fields:
            '["name","lead_name","company_name","territory","status","custom_latitude","custom_longitude","custom_location_status"]',
        filters: '[${f.join(',')}]',
        orderBy: 'lead_name asc');
  }

  /// Every Sales Person in one business unit.
  ///
  /// The unit is the team: `Manna Treads`, `Manna Tyre Retreads`,
  /// `Manna Tyres UAE`. It lives on the Sales Person, and a lead or customer
  /// belongs to whichever unit its rep does.
  static Future<List<String>> _repsInUnit(String unit) async {
    if (unit.isEmpty) return const [];
    final rows = await _list('Sales Person',
        fields: '["name"]',
        filters: '[["custom_company","=","$unit"],["is_group","=",0]]');
    return rows.map((e) => '${e['name']}').toList();
  }

  /// Leads and customers already on record within [radiusMetres] of a point,
  /// belonging to **another rep in the caller's own business unit**.
  ///
  /// Two exclusions, for two different reasons:
  ///
  /// *Other units* do not count. Manna Treads and Manna Tyre Retreads sell
  /// different things to the same trade, so one tyre shop is legitimately a
  /// customer of both, and neither record is a duplicate of the other.
  ///
  /// *The caller's own records* do not count either. A rep who has already put
  /// a shop on the map and walks next door is doing their job — and if the two
  /// really are the same place, they are the one person who can see that.
  ///
  /// What is left is the thing this exists to stop: two different reps on one
  /// team both claiming the same customer.
  ///
  /// A record whose rep has no unit set belongs to no team and blocks nobody.
  ///
  /// Two stages, because neither alone is right. The backend narrows by a
  /// latitude/longitude box, which SQL can do against an index; the box is a
  /// square around a circle, so it over-selects the corners. The exact
  /// haversine distance then trims it back to a true radius here.
  ///
  /// Throws rather than returning empty if the query fails. An empty list means
  /// "nothing is nearby", and a lookup that could not run must never be able to
  /// say that — see the callers, which refuse to proceed on an error.
  static Future<List<NearbyPlace>> nearbyPlaces({
    required double lat,
    required double lng,
    double radiusMetres = kDuplicateRadiusMetres,
    Set<String> exclude = const {},
  }) async {
    if (!isRealCoordinate(lat, lng)) {
      throw Exception('No usable GPS fix — cannot check what is nearby.');
    }
    final unit = '${Session.I.company ?? ''}'.trim();
    final me = '${Session.I.salesPerson ?? ''}'.trim();
    // The caller's own records are not a conflict with anybody.
    //
    // A rep who has already put one shop on the map and walks next door is
    // doing their job, not duplicating themselves — and if the two really are
    // the same shop they are the one person who can see that. This rule
    // exists to stop *two* reps claiming one customer, so the only records
    // that can block are other people's.
    final mates =
        (await _repsInUnit(unit)).where((r) => r != me).toList();
    // Nobody else on the team means nothing can clash. Blocking on every
    // record in the country would be worse than letting this through: it
    // would stop a rep working over a clash with a team they are not on.
    if (mates.isEmpty) return const [];

    final dLat = latSpanForMetres(radiusMetres);
    final dLng = lngSpanForMetres(radiusMetres, lat);
    String box(String latField, String lngField) => '["$latField",">=",'
        '${lat - dLat}],["$latField","<=",${lat + dLat}],'
        '["$lngField",">=",${lng - dLng}],["$lngField","<=",${lng + dLng}]';
    final team = _inList(mates);

    final results = await Future.wait([
      _list('Lead',
          fields: '["name","lead_name","company_name","custom_sales_person",'
              '"custom_latitude","custom_longitude"]',
          filters: '[${box('custom_latitude', 'custom_longitude')},'
              '["custom_sales_person","in",$team]]',
          orderBy: 'modified desc'),
      _list('Customer',
          fields: '["name","customer_name","custom_assigned_reps",'
              '"custom_latitude","custom_longitude"]',
          filters: '[${box('custom_latitude', 'custom_longitude')},'
              '["custom_assigned_reps","in",$team]]',
          orderBy: 'modified desc'),
    ]);

    double n(dynamic v) =>
        v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

    NearbyPlace? place(Map<String, dynamic> d, String kind) {
      final la = n(d['custom_latitude']), lo = n(d['custom_longitude']);
      // A record whose coordinates were never captured reads as (0, 0), which
      // is a real point in the Atlantic. Skipped rather than measured.
      if (!isRealCoordinate(la, lo)) return null;
      final label = '${d[kind == 'Lead' ? 'lead_name' : 'customer_name'] ?? ''}'
          .trim();
      return NearbyPlace(
        name: '${d['name']}',
        label: label.isEmpty ? '${d['name']}' : label,
        kind: kind,
        owner: '${d[kind == 'Lead' ? 'custom_sales_person' : 'custom_assigned_reps'] ?? ''}'
            .trim(),
        metres: metresBetween(lat, lng, la, lo),
      );
    }

    final makers = <NearbyPlace Function()>[];
    for (final d in results[0]) {
      final p = place(d, 'Lead');
      if (p != null) makers.add(() => p);
    }
    for (final d in results[1]) {
      final p = place(d, 'Customer');
      if (p != null) makers.add(() => p);
    }

    return placesWithin(
      lat: lat,
      lng: lng,
      radiusMetres: radiusMetres,
      candidates: makers,
      excludeNames: exclude,
    );
  }

  static Future<String> createCustomer({
    required String name,
    required String group,
    required String territory,
    String? phone,
  }) async {
    final rep = Session.I.salesPerson;
    final body = <String, dynamic>{
      'customer_name': name,
      'customer_type': 'Company',
      'customer_group': group,
      'territory': territory,
      if (rep != null && rep.isNotEmpty) 'custom_assigned_reps': rep,
      'custom_location_status': 'Not Captured',
    };
    if (phone != null && phone.trim().isNotEmpty) {
      body['custom_phone'] = phone.trim();
    }
    final r = await Session.I.dio.post(_res('Customer'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  // Restrict a list to the logged-in person's own sales_person.
  // If somehow no rep is resolved, force an impossible match (show nothing)
  // rather than leaking everyone's data.
  static String _mineFilter([String field = 'sales_person']) {
    final rep = Session.I.salesPerson;
    final v = (rep == null || rep.isEmpty) ? '__none__' : rep;
    return '[["$field","=","$v"]]';
  }

  // A visit is punched in against either a Customer or a Lead, so every visit
  // list pulls both party fields — otherwise lead visits come back nameless.
  static const _visitFields =
      '"name","customer","custom_lead","visit_date","visit_status"';

  /// True when the visit was punched in against a Lead rather than a Customer.
  static bool isLeadVisit(Map<String, dynamic> v) =>
      '${v['custom_lead'] ?? ''}'.isNotEmpty;

  /// Who the visit was to: the customer, else the lead, else the doc id.
  static String visitParty(Map<String, dynamic> v) {
    final c = '${v['customer'] ?? ''}';
    if (c.isNotEmpty) return c;
    final l = '${v['custom_lead_name'] ?? v['custom_lead'] ?? ''}';
    if (l.isNotEmpty) return l;
    return '${v['name'] ?? ''}';
  }

  /// Fills `custom_lead_name` on visits that point at a Lead so lists can show
  /// the lead's name instead of its document id. Cosmetic — on failure the
  /// rows keep the id and still display.
  static Future<List<Map<String, dynamic>>> _withLeadNames(
      List<Map<String, dynamic>> visits) async {
    final ids = visits
        .map((v) => '${v['custom_lead'] ?? ''}')
        .where((s) => s.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return visits;
    try {
      final rows = await _list('Lead',
          fields: '["name","lead_name","company_name"]',
          filters: '[["name","in",["${ids.join('","')}"]]]',
          limit: 0);
      final byId = <String, String>{
        for (final r in rows)
          '${r['name']}':
              '${r['lead_name'] ?? r['company_name'] ?? r['name']}',
      };
      for (final v in visits) {
        final id = '${v['custom_lead'] ?? ''}';
        if (id.isNotEmpty) v['custom_lead_name'] = byId[id] ?? id;
      }
    } catch (_) {}
    return visits;
  }

  // My own visits — customer and lead alike — with the GPS they were checked
  // in at, so the map can plot where I have actually been.
  static Future<List<Map<String, dynamic>>> getMyVisitsWithLocation(
      {int days = 30}) async {
    final me = Session.I.salesPerson;
    if (me == null || me.isEmpty) return [];
    final from = DateTime.now().subtract(Duration(days: days));
    final fromStr =
        '${from.year}-${from.month.toString().padLeft(2, '0')}-${from.day.toString().padLeft(2, '0')}';
    return _withLeadNames(await _list('Sales Visit',
        fields:
            '[$_visitFields,"check_in_time","check_in_latitude","check_in_longitude"]',
        filters:
            '[["sales_person","=","$me"],["visit_date",">=","$fromStr"]]',
        orderBy: 'visit_date desc',
        limit: 0));
  }

  static Future<List<Map<String, dynamic>>> getMyVisits() async =>
      _withLeadNames(await _list('Sales Visit',
          fields: '[$_visitFields]', filters: _mineFilter(), limit: 50));

  // ---- Trip tagging + visit linking (Sub-chunk 4) ----
  static Future<Map<String, dynamic>?> getActiveTrip() async {
    final me = Session.I.salesPerson;
    if (me == null) return null;
    final list = await _list('Trip',
        fields: '["name","trip_date","purpose"]',
        filters: '[["sales_person","=","$me"],["status","=","Active"]]',
        orderBy: 'creation desc',
        limit: 1);
    return list.isNotEmpty ? list.first : null;
  }

  static Future<List<Map<String, dynamic>>> getAllSalesPersons() =>
      _list('Sales Person',
          fields: '["name"]', orderBy: 'name asc', limit: 0);

  static Future<List<Map<String, dynamic>>> getVisitsForTrip(
      String tripName) async =>
      _withLeadNames(await _list('Sales Visit',
          fields:
              '[$_visitFields,"sales_person","check_in_time","check_in_latitude","check_in_longitude"]',
          filters: '[["custom_trip","=","$tripName"]]',
          orderBy: 'creation desc',
          limit: 0));

  static Future<void> saveTripTaggedReps(
      String tripName, List<String> reps) async {
    final rows = reps.map((r) => {'sales_person': r}).toList();
    final csv = reps.isEmpty ? '' : '|${reps.join('|')}|';
    await _put('Trip', tripName, {'tagged_reps': rows, 'tagged_csv': csv});
  }

  static Future<List<String>> _tripsTaggedForMe() async {
    final me = Session.I.salesPerson;
    if (me == null) return [];
    final rows = await _list('Trip',
        fields: '["name"]',
        filters: '[["tagged_csv","like","%|$me|%"]]',
        limit: 0);
    return rows.map((r) => '${r['name']}').toList();
  }

  // My visits + visits on trips I'm tagged on (auto-shared).
  static Future<List<Map<String, dynamic>>> getMyVisitsIncludingTagged() async {
    // Cached as one composed list rather than per-query: the merge of a rep's
    // own visits with the ones tagged to them through a shared trip is what the
    // screen actually shows, and half of it would be misleading.
    return _cachedRows(CacheKeys.visits, () async {
      const f = '[$_visitFields,"sales_person","custom_trip"]';
      final own = await _list('Sales Visit',
          fields: f, filters: _mineFilter(), limit: 50);
      final byName = <String, Map<String, dynamic>>{};
      for (final v in own) {
        byName['${v['name']}'] = v;
      }
      final tagged = await _tripsTaggedForMe();
      if (tagged.isNotEmpty) {
        final inClause = '["${tagged.join('","')}"]';
        final shared = await _list('Sales Visit',
            fields: f,
            filters: '[["custom_trip","in",$inClause]]',
            limit: 50);
        for (final v in shared) {
          byName['${v['name']}'] = v;
        }
      }
      final list = byName.values.toList();
      list.sort((a, b) => '${b['visit_date']}'.compareTo('${a['visit_date']}'));
      return _withLeadNames(list);
    });
  }

  /// Every order this rep has raised — against customers and against leads.
  ///
  /// A lead order is an order. Leaving it out of My Orders meant a rep could
  /// take one and then have nowhere to see what became of it, which is the
  /// screen's whole job.
  ///
  /// The two doctypes are mapped onto one shape here rather than in the widget:
  /// a Lead Order names its party in `lead_name` and its state in `status`,
  /// where a Sales Order uses `customer` and `custom_po_status`.
  static Future<List<Map<String, dynamic>>> getMyOrders() => _cachedRows(
        CacheKeys.orders,
        () async {
          final results = await Future.wait([
            _list('Sales Order',
                fields:
                    '["name","customer","grand_total","transaction_date","delivery_date","custom_proforma_status","custom_proforma_required","custom_order_placed_at","custom_po_status","custom_production_status","custom_production_finish_date","custom_combined_order","custom_duplicate_of","custom_duplicate_ignored","custom_edit_count","docstatus",'
                    // What SAP says about it: the order number that proves it
                    // reached the factory, where it is on the floor, and which
                    // delivery is carrying it out.
                    '"custom_sap_sales_order","custom_sap_production_stage",'
                    '"custom_sap_delivery_order","custom_sap_delivery_date",'
                    '"custom_sap_synced_at","custom_sap_sync_error"]',
                filters: _mineFilter('custom_sales_person'),
                limit: 50),
            // A rep's own lead orders. Failing here must not cost them their
            // customer orders, so it is caught rather than propagated.
            _list('Lead Order',
                fields:
                    '["name","lead","lead_name","order_date","delivery_date","total_amount","status","custom_order_placed_at","sales_person"]',
                filters: _mineFilter('sales_person'),
                limit: 50).catchError(
                (_) => <Map<String, dynamic>>[]),
          ]);

          final rows = <Map<String, dynamic>>[...results[0]];
          for (final l in results[1]) {
            rows.add({
              ...l,
              'is_lead': true,
              'customer': l['lead_name'] ?? l['lead'],
              'transaction_date': l['order_date'],
              'grand_total': l['total_amount'],
            });
          }
          final collapsed = await _collapseIntoGroups(rows);
          // Newest first across all of them, so the list reads as one history
          // rather than as several lists stapled together.
          collapsed.sort((a, b) => '${b['transaction_date'] ?? ''}'
              .compareTo('${a['transaction_date'] ?? ''}'));
          return collapsed;
        },
      );

  /// Replaces each week's grouped orders with the one combined order holding
  /// them.
  ///
  /// Once the production manager has closed a week, a customer's four orders
  /// are one order as far as everybody afterwards is concerned — that is the
  /// point of grouping. Listing both the group and its members would show the
  /// same money twice and leave the rep counting it twice.
  ///
  /// Ungrouped orders are untouched, so a week still running reads exactly as
  /// it did before it was closed.
  static Future<List<Map<String, dynamic>>> _collapseIntoGroups(
      List<Map<String, dynamic>> rows) async {
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      final g = '${r['custom_combined_order'] ?? ''}'.trim();
      if (g.isEmpty || g == 'null') continue;
      groups.putIfAbsent(g, () => []).add(r);
    }
    if (groups.isEmpty) return rows;

    // The combined orders are read rather than reconstructed from the members:
    // the header carries the week and the totals for *every* order in the
    // group, including any raised by another rep, and a rep looking at their
    // customer's week should see the whole week.
    List<Map<String, dynamic>> heads = const [];
    try {
      heads = await _list('Combined Order',
          fields: '["name","customer","customer_name","week_start","week_end",'
              '"custom_dispatch","status","order_count","total_amount"]',
          filters: '[["name","in",${_inList(groups.keys.toList())}]]');

      // The van, for the groups a dispatch made. The rep is asked "when did
      // it come and on what", and the combined order holds only the link —
      // so the vehicle and date are read from the dispatch itself rather
      // than copied onto the group, where they would go stale if the van
      // or the date changed before it left.
      final dispatchIds = <String>{
        for (final h in heads)
          if ('${h['custom_dispatch'] ?? ''}'.trim().isNotEmpty &&
              '${h['custom_dispatch']}'.trim() != 'null')
            '${h['custom_dispatch']}'.trim()
      };
      if (dispatchIds.isNotEmpty) {
        // Best-effort: a group with no readable dispatch still lists, it just
        // shows no van. Losing the row entirely would be far worse.
        try {
          final vans = await _list('Manna Dispatch',
              fields: '["name","vehicle","dispatch_date"]',
              filters: '[["name","in",${_inList(dispatchIds.toList())}]]');
          final byId = {for (final v in vans) '${v['name']}': v};
          heads = [
            for (final h in heads)
              {
                ...h,
                if (byId['${h['custom_dispatch']}'] != null) ...{
                  'vehicle': byId['${h['custom_dispatch']}']!['vehicle'],
                  'dispatch_date': byId['${h['custom_dispatch']}']!
                      ['dispatch_date'],
                }
              }
          ];
        } catch (_) {
          // Leave the groups without their van details.
        }
      }
    } catch (_) {
      // If the headers cannot be read, leave the individual orders showing.
      // A rep seeing their orders un-grouped is a worse list; a rep seeing
      // neither the group nor its members has lost work off their screen.
      return rows;
    }
    return collapseIntoGroups(rows, heads);
  }

  /// The swap itself, given the headers. Separated from fetching them because
  /// this is where an order could go missing, and that is worth testing without
  /// a network.
  @visibleForTesting
  static List<Map<String, dynamic>> collapseIntoGroups(
      List<Map<String, dynamic>> rows, List<Map<String, dynamic>> heads) {
    if (heads.isEmpty) return rows;
    final found = {for (final h in heads) '${h['name']}'};

    // Only members of a group that was actually read are dropped. An order
    // pointing at a combined order that could not be found stays on the list:
    // losing it from the rep's screen is far worse than showing it ungrouped.
    final out = <Map<String, dynamic>>[
      for (final r in rows)
        if (!found.contains('${r['custom_combined_order'] ?? ''}'.trim())) r
    ];
    for (final h in heads) {
      out.add({
        ...h,
        'is_combined': true,
        // Mapped onto the same shape the list already speaks, so the row sorts
        // and renders beside ordinary orders instead of needing its own path.
        'customer': h['customer_name'] ?? h['customer'],
        // Dated by the van where there was one, falling back to the week for
        // the older groups "Close the week" made. This is what the row sorts
        // on, so a dispatch group must not date itself from an empty week.
        'transaction_date':
            h['dispatch_date'] ?? h['week_end'] ?? h['week_start'],
        'grand_total': h['total_amount'],
      });
    }
    return out;
  }

  static Future<Map<String, dynamic>> getOrder(String name) async {
    final r = await Session.I.dio.get(_res('Sales Order') + '/$name');
    final d = (r.data is Map) ? r.data['data'] : null;
    if (d is Map<String, dynamic>) return d;
    throw Exception(_frappeError(r));
  }

  static Future<Map<String, dynamic>> getLeadDoc(String name) async {
    final r = await Session.I.dio.get('${_res('Lead')}/$name');
    final d = (r.data is Map) ? r.data['data'] : null;
    if (d is Map<String, dynamic>) return d;
    throw Exception(_frappeError(r));
  }

  static Future<Map<String, dynamic>> getCustomerDoc(String name) async {
    final r = await Session.I.dio.get(_res('Customer') + '/$name');
    final d = (r.data is Map) ? r.data['data'] : null;
    if (d is Map<String, dynamic>) return d;
    throw Exception(_frappeError(r));
  }

  static Future<void> setOrderField(
      String name, Map<String, dynamic> body) async {
    final r =
    await Session.I.dio.put(_res('Sales Order') + '/$name', data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
  }

  /// Replaces an order's lines and re-books whatever minimum stock the new
  /// line-up needs.
  ///
  /// Customers change their minds, and until 1 pm on the delivery date the
  /// factory can still act on it, so the whole line-up is rewritten rather than
  /// patched — adding, removing and requantifying are one operation as far as
  /// the rep is concerned.
  ///
  /// [returnForApproval] is set when the order had already been approved.
  /// Anything the rep changes after that point — a quantity, a new product, the
  /// delivery date — means what the manager signed off is not what will ship,
  /// so it goes back to them.
  ///
  /// The two `custom_rate_approved` flags do different jobs and are cleared
  /// differently. The **order-level** one means "this order has a decision on
  /// it" and is cleared here, so a re-submitted order shows up to the manager
  /// as something to decide rather than as already approved. The **per-line**
  /// ones mean "this price is final", are carried through untouched, and are
  /// what keep an approved rate locked while the order goes round again.
  /*
   * `_keepDiscounts` stood here until 17 September 2026.
   *
   * A Frappe child table is replaced rather than merged, and the rep's editor
   * knew nothing about discounts — it built each line from the rate per kg the
   * rep typed. So without it, a rep opening a pending order to fix a quantity
   * silently took back a discount their manager had already given, and the
   * manager approved a full-price order believing it was still on.
   *
   * There are no discounts to carry now: the rep types the rate after
   * discount, so the figure their editor builds is already the whole price.
   */

  static Future<void> updateOrderLines({
    required String orderName,
    required List<Map<String, dynamic>> items,
    required bool returnForApproval,
    String? deliveryDate,
    bool isLead = false,
  }) async {
    final ref = OrderRef(orderName, isLead: isLead);

    /*
     * Checked against the order AS STORED, not against what the screen loaded.
     *
     * This had no gate at all until 17 September 2026 — the screen was the
     * only thing standing between a rep and a write, and on this site there is
     * no Server Script behind it to say no. A rep sitting on an order screen
     * while their manager approves it could save straight over the approval.
     *
     * An approved order belongs to SAP. Nothing here can reach it — the sync
     * only ever creates a SAP order, never updates one — so a write accepted
     * at this point would change the ERPNext document, show the rep a new
     * quantity, and leave the factory building the old one.
     */
    if (!isLead) {
      final stored = await getOrder(orderName);
      if (orderApproved(stored)) throw Exception(orderLockReason(stored));
    }

    final body = <String, dynamic>{
      'items': items,
    };
    if (deliveryDate != null) body['delivery_date'] = deliveryDate;
    if (returnForApproval) {
      body['custom_rate_approved'] = 0;
      if (isLead) {
        // A lead order is not visible to production — it does not become a
        // Sales Order until it is approved — so there is no floor to warn and
        // nothing to acknowledge. It simply goes back in the queue.
        body['status'] = 'Pending Approval';
      } else {
        body['custom_po_status'] = 'Pending Rate Approval';
        // Production has already seen this order. A change nobody tells the
        // floor about is a batch made to the wrong spec, so the order is
        // flagged until the production manager acknowledges it.
        body['custom_changed_after_approval'] = 1;
      }
    }
    final r = await Session.I.dio
        .put('${_res(ref.doctype)}/$orderName', data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }

    /*
     * Both of these run AFTER the save and neither can fail it. A rep who was
     * told their edit did not go through, when it did, would key it again.
     *
     * Lead orders are excluded: the count and the duplicate check are about
     * Sales Orders, and a Lead Order has neither field.
     */
    if (!isLead) {
      await bumpEditCount(orderName);
      await refreshDuplicateFlag(orderName);
    }
  }

  /// Frappe hands numbers back as num or as a string, depending on the path.
  static double _toNum(dynamic v) =>
      v is num ? v.toDouble() : (double.tryParse('${v ?? ''}'.trim()) ?? 0);

  static int _toInt(dynamic v) =>
      v is num ? v.toInt() : (int.tryParse('${v ?? ''}'.trim()) ?? 0);

  // -------- Credit conditions (GM approval) --------
  //
  // When the GM lets an over-limit order through, the approval can carry a
  // condition — "clear the 60-day outstanding by the 15th" — owned by the rep
  // who raised the order. Before this the GM's yes left no trace of what was
  // promised in return, and nobody was accountable for it afterwards.
  //
  // Deliberately toothless: nothing here refuses an order. A condition is
  // shown, chased and closed, and a rule that blocked a sale on one that had
  // been forgotten would stop a rep selling in front of a customer.

  /// Attach a condition to a customer, owned by [salesPerson].
  ///
  /// Written after the approval, never before, and never able to fail it: an
  /// approval the GM believes they gave and the rep cannot see is worse than
  /// a condition nobody recorded.
  static Future<String?> addCreditCondition({
    required String customer,
    required String salesPerson,
    required String condition,
    required String dueDateIso,
    String? salesOrder,
  }) async {
    try {
      final r = await Session.I.dio.post(
        _res('Manna Credit Condition'),
        data: {
          'customer': customer,
          'sales_person': salesPerson,
          'condition': condition,
          'due_date': dueDateIso,
          'status': 'Open',
          if (salesOrder != null && salesOrder.isNotEmpty) 'sales_order': salesOrder,
          // A display name, matching custom_approved_by and the other
          // who-did-this fields on this site, which are Data and not Links.
          'set_by': Session.I.salesPersonLabel ?? Session.I.salesPerson ?? Session.I.email,
          'set_on': nowStamp(),
        },
      );
      if (r.statusCode == 200 || r.statusCode == 201) {
        await OfflineCache.clear();
        return r.data['data']['name'] as String;
      }
    } catch (_) {
      // Swallowed on purpose — see the doc comment.
    }
    return null;
  }

  /// Every condition on a customer, open ones first and oldest deadline first.
  ///
  /// Closed ones are kept and shown: the record of what was demanded and
  /// whether it was met is the point, and hiding them would leave the tab
  /// looking empty for a customer with a long history of them.
  static Future<List<Map<String, dynamic>>> creditConditions(
      String customer) async {
    return _list('Manna Credit Condition',
        fields: '["name","customer","sales_person","sales_order","condition",'
            '"due_date","status","set_by","set_on","response","responded_on",'
            '"close_note","closed_by","closed_on"]',
        filters: '[["customer","=","$customer"]]',
        orderBy: 'status asc, due_date asc');
  }

  // -------- The SAP credit-limit refresh --------
  //
  // Frappe Cloud cannot reach the SAP LAN, so nothing here speaks to SAP. The
  // button raises a flag on the `SAP Sync Control` Single; a poller on the
  // on-prem Windows box picks it up within about two minutes, runs the sync
  // and writes the outcome back.
  //
  // The cooldown lives in the `manna_sap_request_sync` Server Script, not
  // here. The SAP Service Layer licence pool is tiny and logging in inside the
  // window takes it down for 20-30 minutes for everybody. This file only
  // reports the refusal; the server makes it.

  /// The sync state. Polled every 10 seconds while a run is in flight.
  static Future<Map<String, dynamic>> sapSyncStatus() async {
    final r = await Session.I.dio.post('/api/method/manna_sap_get_status');
    final m = r.data is Map ? r.data['message'] : null;
    return m is Map ? Map<String, dynamic>.from(m) : <String, dynamic>{};
  }

  /// Ask for a refresh.
  ///
  /// A refusal is a normal answer, not an error: `ok` false with a reason of
  /// `in_progress` or `cooldown`. Only Accounts Manager, Sales Manager and
  /// System Manager may ask at all — anyone else gets a 403 from the script,
  /// which is why the button is not offered to a rep in the first place.
  static Future<Map<String, dynamic>> requestSapSync() async {
    final r = await Session.I.dio.post('/api/method/manna_sap_request_sync');
    final m = r.data is Map ? r.data['message'] : null;
    if (m is Map) return Map<String, dynamic>.from(m);
    throw Exception(_frappeError(r));
  }

  /// Every condition this rep owes, across all their customers.
  ///
  /// The customer screen shows one shop's conditions; this is the rep's own
  /// list, which is the only view that answers "what do I still owe?". A rep
  /// with an obligation on a shop they are not visiting today would otherwise
  /// never see it until the deadline had passed.
  ///
  /// Open and Awaiting Review first, soonest deadline first — what is still
  /// owed, in the order it falls due. Closed ones are kept but sink to the
  /// bottom: the record of what was demanded and whether it was met is the
  /// point of keeping them.
  static Future<List<Map<String, dynamic>>> myCreditConditions() async {
    final rep = Session.I.salesPerson;
    if (rep == null || rep.isEmpty) return const [];
    return _list('Manna Credit Condition',
        fields: '["name","customer","sales_person","sales_order","condition",'
            '"due_date","status","set_by","set_on","response","responded_on",'
            '"close_note","closed_by","closed_on"]',
        filters: '[["sales_person","=","$rep"]]',
        orderBy: 'status asc, due_date asc');
  }

  /// The rep's answer. Moves it to Awaiting Review — the rep says what they
  /// did, the GM decides whether that settles it.
  static Future<void> respondToCondition(String name, String response) async {
    await _put('Manna Credit Condition', name, {
      'response': response,
      'responded_on': nowStamp(),
      'status': 'Awaiting Review',
    });
    await OfflineCache.clear();
  }

  /// The GM's decision. [closed] false sends it back to the rep.
  ///
  /// Only the GM closes one. The person under an obligation declaring it
  /// satisfied is not accountability, and this is the door that enforces it —
  /// the screen hides the button, and there is no Server Script behind it.
  static Future<void> decideCondition(String name,
      {required bool closed, String? note}) async {
    if (!Session.I.isGM) {
      throw Exception('Only the general manager can close a credit condition.');
    }
    await _put('Manna Credit Condition', name, {
      'status': closed ? 'Closed' : 'Open',
      if (note != null && note.trim().isNotEmpty) 'close_note': note.trim(),
      'closed_by': closed ? (Session.I.salesPersonLabel ?? Session.I.salesPerson ?? Session.I.email) : '',
      'closed_on': closed ? nowStamp() : '',
    });
    await OfflineCache.clear();
  }

  // -------- Duplicate orders, edit count, deletion --------
  //
  // All three were asked for on 21 August 2026. The rule behind the first is in
  // core/duplicate_order.dart and pinned by shared/fixtures/duplicate_order.json.

  /// Item codes on the customer's other OPEN orders, keyed by order name.
  ///
  /// One document read per order, because `Sales Order Item` cannot be listed
  /// directly on this site — it answers 403, see CLAUDE.md section 4. That is
  /// why this runs when an order is SAVED and not while a list renders.
  ///
  /// Capped at the ten most recent. A customer with more open orders than that
  /// has a bigger problem than a duplicate warning, and ten document reads is
  /// already the most a rep should wait through on a shop counter.
  static Future<Map<String, List<String>>> _openOrderItems({
    required String customer,
    required String excluding,
  }) async {
    if (customer.isEmpty) return {};
    final heads = await _list('Sales Order',
        fields: '["name","custom_production_status","docstatus"]',
        filters: '[["customer","=","$customer"]]',
        orderBy: 'creation desc',
        limit: 40);

    final out = <String, List<String>>{};
    for (final h in heads) {
      if (out.length >= 10) break;
      final name = '${h['name']}';
      if (name == excluding) continue;
      // Cancelled is docstatus 2. Dispatched is done with. Both are filtered
      // here rather than in the query: an unset production status reads back
      // three different ways and a SQL "!=" would silently drop those rows,
      // which are exactly the open orders this is looking for.
      if (_toInt(h['docstatus']) == 2) continue;
      if ('${h['custom_production_status'] ?? ''}' == kStageDispatched) continue;

      try {
        final doc = await getOrder(name);
        final items = ((doc['items'] as List?) ?? const [])
            .cast<Map<String, dynamic>>();
        out[name] = items.map((i) => '${i['item_code'] ?? ''}').toList();
      } catch (_) {
        // One unreadable order is not a reason to give up on the warning.
      }
    }
    return out;
  }

  /// Work out whether [orderName] repeats a customer's open order, and store it.
  ///
  /// Best-effort and never rethrows: this runs after the order has already been
  /// saved, and a warning that could not be computed must not surface as a
  /// failure to save. The rep would have no idea what had actually happened to
  /// their order.
  static Future<void> refreshDuplicateFlag(String orderName) async {
    try {
      final doc = await getOrder(orderName);
      final mine = ((doc['items'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map((i) => '${i['item_code'] ?? ''}')
          .toList();

      final others = await _openOrderItems(
          customer: '${doc['customer'] ?? ''}', excluding: orderName);
      final found = findDuplicate(mine: mine, otherOpenOrders: others);

      final was = '${doc['custom_duplicate_of'] ?? ''}'.trim();
      final now = found?.order ?? '';
      if (was == now) return;

      await _put('Sales Order', orderName, {
        'custom_duplicate_of': now,
        // A dismissal covers the overlap the rep actually looked at. Pointing
        // at a DIFFERENT order is new information and deserves a fresh look;
        // re-flagging the same one would nag somebody who already decided.
        'custom_duplicate_ignored': 0,
      });
      await OfflineCache.clear();
    } catch (_) {
      // Left as it was. The order itself is saved, which is what matters.
    }
  }

  /// The rep has seen the duplicate warning and wants it gone.
  ///
  /// Stored on the order, not the phone, so it stays dismissed on every device
  /// and survives a reinstall.
  static Future<void> ignoreDuplicate(String orderName) async {
    await _put('Sales Order', orderName, {'custom_duplicate_ignored': 1});
    await OfflineCache.clear();
  }

  /// Count one more rep edit against the order.
  ///
  /// Read-then-write rather than a server-side increment, because this site has
  /// no Server Scripts. Two edits racing would lose one count, which is a price
  /// worth paying for a figure that exists to say "this has been changed a lot".
  static Future<void> bumpEditCount(String orderName) async {
    try {
      final doc = await getOrder(orderName);
      final n = _toInt(doc['custom_edit_count']);
      await _put('Sales Order', orderName, {'custom_edit_count': n + 1});
    } catch (_) {
      // Never the reason an edit fails.
    }
  }

  /// Delete an order the rep raised and no longer wants.
  ///
  /// Nothing has to be released first any more. A draft order holds no stock:
  /// it is not in SAP until it is approved, and it is SAP that commits stock
  /// against an order. Deleting one leaves nothing behind.
  ///
  /// The caller decides who may do this; [canDeleteOrder] in core/order_rules
  /// is the rule.
  static Future<void> deleteOrder(String orderName) async {
    final r = await Session.I.dio.delete('${_res('Sales Order')}/$orderName');
    if (r.statusCode != 200 && r.statusCode != 202) {
      throw Exception(_frappeError(r));
    }
    await OfflineCache.clear();
  }

  // -------- Leads --------
  static Future<List<Map<String, dynamic>>> getLeads() {
    return _cachedRows(
        CacheKeys.leads,
        () => _visibleRows(
            'Lead', kFieldLeadOwner,
            // The location fields belong here even though the list does not
            // draw them. The detail screen is built from this row, so leaving
            // them out made a captured location vanish the moment a rep left
            // the screen and came back — it read the absent status as "Not
            // Captured" and asked them to do it again.
            fields:
                '["name","lead_name","company_name","mobile_no","email_id","custom_gstin","custom_address","custom_payment_terms","territory","custom_sales_route","status","custom_location_status","custom_latitude","custom_longitude","custom_verified_latitude","custom_verified_longitude"]'));
  }

  /// Sets who a lead belongs to. UAE only (see `core/visibility.dart`) —
  /// callers must check `canAssignOwner` first; this does not re-check it.
  static Future<void> assignLeadOwner(String leadName, String rep) async {
    await _put('Lead', leadName, {kFieldLeadOwner: rep});
    await OfflineCache.clear();
  }

  static Future<String> createLead({
    required String leadName,
    String? company,
    String? mobile,
    String? email,
    String? gstin,
    String? address,
    String? paymentTerms,
    String? territory,
    String? salesRoute,
  }) async {
    final body = <String, dynamic>{
      'lead_name': leadName,
      'custom_sales_person': Session.I.salesPerson,
      'status': 'Lead',
    };
    void put(String key, String? v) {
      if (v != null && v.trim().isNotEmpty) body[key] = v.trim();
    }
    put('company_name', company);
    put('mobile_no', mobile);
    put('email_id', email);
    put('custom_gstin', gstin);
    put('custom_address', address);
    put('custom_payment_terms', paymentTerms);
    put('territory', territory);
    put('custom_sales_route', salesRoute);
    final r = await Session.I.dio.post(_res('Lead'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  /// Edits an existing lead. Blank values clear the field, so the whole
  /// editable set is sent every time.
  static Future<Map<String, dynamic>> updateLead({
    required String name,
    required String leadName,
    String? company,
    String? mobile,
    String? email,
    String? gstin,
    String? address,
    String? paymentTerms,
    String? territory,
    String? salesRoute,
  }) async {
    final body = <String, dynamic>{'lead_name': leadName.trim()};
    void put(String key, String? v) => body[key] = (v ?? '').trim();
    put('company_name', company);
    put('mobile_no', mobile);
    put('email_id', email);
    put('custom_gstin', gstin);
    put('custom_address', address);
    put('custom_payment_terms', paymentTerms);
    put('territory', territory);
    put('custom_sales_route', salesRoute);
    final r = await Session.I.dio.put(_res('Lead') + '/$name', data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      final d = (r.data is Map) ? r.data['data'] : null;
      return d is Map<String, dynamic> ? d : body;
    }
    throw Exception(_frappeError(r));
  }

  static Future<List<Map<String, dynamic>>> getLeadOrders({String? lead}) {
    final rep = Session.I.salesPerson;
    final f = <String>[];
    if (rep != null && rep.isNotEmpty) f.add('["sales_person","=","$rep"]');
    if (lead != null) f.add('["lead","=","$lead"]');
    final filters = f.isEmpty ? null : '[${f.join(',')}]';
    return _list('Lead Order',
        fields: '["name","lead","lead_name","order_date","delivery_date",'
            '"total_amount","status","po_number","custom_rate_approved",'
            '"custom_order_placed_at","sales_person"]',
        filters: filters,
        orderBy: 'creation desc');
  }

  static Future<Map<String, dynamic>> getLeadOrder(String name) async {
    final r = await Session.I.dio.get(_res('Lead Order') + '/$name');
    final d = (r.data is Map) ? r.data['data'] : null;
    if (d is Map<String, dynamic>) return d;
    throw Exception(_frappeError(r));
  }

  static Future<String> createLeadOrder({
    required String lead,
    required List<Map<String, dynamic>> items,
    required double total,
  }) async {
    final body = {
      'lead': lead,
      'sales_person': Session.I.salesPerson,
      'status': 'Pending Approval',
      'items': items,
      'total_amount': total,
    };
    final r = await Session.I.dio.post(_res('Lead Order'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<void> uploadLeadOrderPO({
    required String name,
    required String filePath,
    String? poNumber,
  }) async {
    await uploadPhoto(
        docname: name,
        fieldname: 'po_attachment',
        filePath: filePath,
        doctype: 'Lead Order',
        filename: 'signed_po.jpg');
    final body = <String, dynamic>{'status': 'PO Uploaded'};
    if (poNumber != null && poNumber.trim().isNotEmpty) {
      body['po_number'] = poNumber.trim();
    }
    final r = await Session.I.dio.put(_res('Lead Order') + '/$name', data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
  }

  static Future<List<Map<String, dynamic>>> getMyCollections() =>
      _cachedRows(
          CacheKeys.collections,
          () => _list('Collection Entry',
              fields:
                  '["name","customer","amount","mode_of_payment","collection_date"]',
              filters: _mineFilter(),
              limit: 50));

  /// The ERPNext Company this rep's orders belong to.
  ///
  /// This used to return whichever Company was created most recently, which
  /// meant every rep — Treads, Retreads and UAE alike — booked into the same
  /// one. On a site with an Indian company and a UAE company that quietly ran
  /// rupee orders through a dirham conversion and into the wrong cost centre.
  /// It follows the rep's unit now.
  ///
  /// The fallbacks matter: if the expected company has been renamed the app
  /// should still take the order rather than refuse to sell.
  static Future<String> getCompany() async {
    final list = await _list('Company', fields: '["name"]');
    final names = list.map((e) => e['name'] as String).toList();
    if (names.isEmpty) return '';
    final wanted = companyForUnit(Session.I.company);
    return names.firstWhere(
      (n) => n == wanted,
      orElse: () => names.firstWhere(
          (n) => !n.toLowerCase().contains('demo'),
          orElse: () => names.first),
    );
  }

  static Future<List<String>> getModesOfPayment() async {
    try {
      final list = await _list('Mode of Payment', fields: '["name"]');
      final modes = list.map((e) => e['name'] as String).toList();
      if (modes.isNotEmpty) return modes;
    } catch (_) {}
    return const ['Cash', 'Cheque', 'Credit Card', 'Wire Transfer', 'Bank Draft'];
  }

  static Future<String> createSalesVisit({
    required String customer,
    required String salesPerson,
    required double lat,
    required double lng,
    String purpose = 'General',
    String? trip,
    String? site,
  }) async {
    final stamp =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final body = {
      'visit_date': stamp.substring(0, 10),
      'sales_person': salesPerson,
      'customer': customer,
      'visit_purpose': purpose,
      'visit_status': 'Checked In',
      'check_in_time': stamp,
      'check_in_latitude': lat,
      'check_in_longitude': lng,
      if (trip != null && trip.isNotEmpty) 'custom_trip': trip,
      if (site != null && site.isNotEmpty) 'custom_site': site,
    };
    final r = await Session.I.dio.post(_res('Sales Visit'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<Map<String, dynamic>?> getOpenVisit(
      {String? customer, String? lead}) async {
    final rep = Session.I.salesPerson;
    if (rep == null) return null;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final party = customer != null
        ? '["customer","=","$customer"]'
        : '["custom_lead","=","$lead"]';
    final list = await _list('Sales Visit',
        fields:
        '["name","check_in_time","check_in_latitude","check_in_longitude"]',
        filters:
        '[["sales_person","=","$rep"],["visit_date","=","$today"],["check_out_time","is","not set"],$party]',
        orderBy: 'check_in_time desc',
        limit: 1);
    return list.isEmpty ? null : list.first;
  }

  /// This rep's open visit anywhere, or null when they are not on one.
  ///
  /// A rep can only be in one shop at a time, so only one visit may be open.
  /// Leaving one running while starting another produces two overlapping
  /// visits, and the first then reads as however long it took the rep to
  /// notice — which is not how long they were in the shop.
  ///
  /// Restricted to today for the same reason the per-party lookup is: a visit
  /// somebody forgot to close last week should not stop them working this
  /// morning. Those are cleaned up separately.
  static Future<Map<String, dynamic>?> getAnyOpenVisit() async {
    final rep = Session.I.salesPerson;
    if (rep == null) return null;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final list = await _list('Sales Visit',
        fields: '["name","check_in_time","customer","custom_lead"]',
        filters: '[["sales_person","=","$rep"],["visit_date","=","$today"],'
            '["check_out_time","is","not set"]]',
        orderBy: 'check_in_time desc',
        limit: 1);
    if (list.isEmpty) return null;
    return _withPartyLabel(list.first);
  }

  /// Put a readable party name on a visit, under `party_label`.
  ///
  /// A visit stores the party as a **docname**, and for a lead that is
  /// `CRM-LEAD-2026-02014`. Telling a rep they are "still checked in at
  /// CRM-LEAD-2026-02014" names nothing they can recognise while they are
  /// standing in front of the next customer, which is the moment this message
  /// exists for.
  ///
  /// Resolved once here so the three places that say it — the punch-in guard,
  /// the still-checked-in dialog and the checked-in-elsewhere banner — cannot
  /// each fall back differently.
  ///
  /// Falls back to the docname on any failure. An ugly identifier still tells
  /// a rep WHICH place to go and punch out of; no name at all does not.
  static Future<Map<String, dynamic>> _withPartyLabel(
      Map<String, dynamic> visit) async {
    final customer = '${visit['customer'] ?? ''}'.trim();
    final lead = '${visit['custom_lead'] ?? ''}'.trim();
    final id = customer.isNotEmpty ? customer : lead;
    if (id.isEmpty || id == 'null') return visit;

    visit['party_label'] = id;
    try {
      final rows = customer.isNotEmpty
          ? await _list('Customer',
              fields: '["name","customer_name"]',
              filters: '[["name","=","$customer"]]',
              limit: 1)
          : await _list('Lead',
              fields: '["name","lead_name","company_name"]',
              filters: '[["name","=","$lead"]]',
              limit: 1);
      if (rows.isNotEmpty) {
        final r = rows.first;
        final label = customer.isNotEmpty
            ? '${r['customer_name'] ?? ''}'
            : '${r['lead_name'] ?? r['company_name'] ?? ''}';
        if (label.trim().isNotEmpty && label.trim() != 'null') {
          visit['party_label'] = label.trim();
        }
      }
    } catch (_) {
      // Keeps the docname set above.
    }
    return visit;
  }

  /// Every place a visit to this party may legitimately be punched at.
  ///
  /// The party's own registered pin, plus each of its sites — a customer with
  /// a shop and a godown is two drops, and a rep at the godown is not in the
  /// wrong place.
  ///
  /// Verified coordinates are preferred, falling back to the captured ones.
  /// A rep's capture waits on their manager, and refusing every punch until
  /// that queue is cleared would stop the work the queue exists to record.
  static Future<List<RegisteredPlace>> registeredPlacesFor(
      {String? customer, String? lead}) async {
    final out = <RegisteredPlace>[];

    double n(dynamic v) =>
        v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

    void addFrom(Map<String, dynamic> d, String label, String prefix) {
      final vLat = n(d['${prefix}verified_latitude']);
      final vLng = n(d['${prefix}verified_longitude']);
      if (isRealCoordinate(vLat, vLng)) {
        out.add(RegisteredPlace(label, vLat, vLng));
        return;
      }
      final cLat = n(d['${prefix}latitude']);
      final cLng = n(d['${prefix}longitude']);
      if (isRealCoordinate(cLat, cLng)) {
        out.add(RegisteredPlace(label, cLat, cLng));
      }
    }

    try {
      if (customer != null && customer.isNotEmpty) {
        addFrom(await getCustomerDoc(customer), customer, 'custom_');
        for (final s in await getCustomerSites(customer)) {
          addFrom(s, '${s['site_name'] ?? 'site'}', '');
        }
      } else if (lead != null && lead.isNotEmpty) {
        final d = await getLeadDoc(lead);
        addFrom(d, '${d['lead_name'] ?? lead}', 'custom_');
        for (final s in await getLeadSites(lead)) {
          addFrom(s, '${s['site_name'] ?? 'site'}', '');
        }
      }
    } catch (_) {
      // Whatever was gathered before the failure still counts. An empty list
      // reads as "cannot tell", which the caller treats as permission rather
      // than refusal.
    }
    return out;
  }

  static Future<String> punchInVisit(
      {String? customer,
        String? lead,
        required double lat,
        required double lng}) async {
    final rep = Session.I.salesPerson!;

    // One visit at a time. The screen checks this first and explains it
    // properly; this is the backstop, so a second visit cannot be opened by a
    // draft synced later or by a screen added in future that forgets.
    final open = await getAnyOpenVisit();
    if (open != null) {
      // The readable name, not the docname — see _withPartyLabel.
      final where = '${open['party_label'] ?? open['customer'] ?? open['custom_lead'] ?? ''}'
          .trim();
      throw Exception('You are still checked in'
          '${where.isEmpty ? '' : ' at $where'}. '
          'Punch out there before starting another visit.');
    }

    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceFirst('T', ' ');
    // Link to the trip that's running, so the visit shows on the trip.
    String? trip;
    try {
      trip = (await getActiveTrip())?['name'] as String?;
    } catch (_) {}
    final body = {
      'visit_date': stamp.substring(0, 10),
      'sales_person': rep,
      if (customer != null) 'customer': customer,
      if (lead != null) 'custom_lead': lead,
      if (trip != null && trip.isNotEmpty) 'custom_trip': trip,
      'visit_status': 'Checked In',
      'check_in_time': stamp,
      'check_in_latitude': lat,
      'check_in_longitude': lng,
    };
    final r = await Session.I.dio.post(_res('Sales Visit'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<double> punchOutVisit(
      {required String name,
        required double lat,
        required double lng,
        required String checkInTime}) async {
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceFirst('T', ' ');
    double mins = 0;
    try {
      final inT = DateTime.parse(checkInTime.replaceFirst(' ', 'T'));
      mins = DateTime.now().difference(inT).inSeconds / 60.0;
    } catch (_) {}
    await _put('Sales Visit', name, {
      'check_out_time': stamp,
      'check_out_latitude': lat,
      'check_out_longitude': lng,
      'custom_duration_minutes': double.parse(mins.toStringAsFixed(1)),
      'visit_status': 'Completed',
    });
    return mins;
  }

  /// Raises a Sales Order.
  ///
  /// Reps are no longer asked whether they want a proforma. Raising the order
  /// sends it for approval, and a proforma is something they print afterwards
  /// if the customer wants one — so it is a button on the order, not a
  /// decision to make before the order exists.
  ///
  /// The placed-at stamp used to be written by a Before Save script so that it
  /// could not come off a phone. Without server scripts the app has to write
  /// it, so it is taken from [nowStamp] — the server's clock as last seen on a
  /// response header, not the handset's. That keeps a rep with a wrong date
  /// from backdating their own order, but it is no longer *impossible* to
  /// forge, and nothing now stops a later edit from moving it.
  static Future<String> createSalesOrder({
    required String customer,
    required String company,
    required List<Map<String, dynamic>> items,
    String? deliveryDate,
  }) async {
    final body = {
      'customer': customer,
      'company': company,
      'custom_sales_person': Session.I.salesPerson,
      if (Session.I.company != null && Session.I.company!.isNotEmpty)
        'custom_company': Session.I.company,
      'delivery_date': deliveryDate ??
          DateTime.now()
              .add(const Duration(days: 7))
              .toIso8601String()
              .substring(0, 10),
      'custom_proforma_required': 1,
      'custom_proforma_status': 'Ready',
      // Straight into the manager's queue. Reps used to have to get the
      // proforma signed and scan it back before an order counted as pending;
      // that step is gone, so raising the order is the request for approval.
      'custom_po_status': 'Pending Approval',
      'custom_rate_approved': 0,
      'custom_order_placed_at': nowStamp(),
      'items': items,
    };
    final r = await Session.I.dio.post(_res('Sales Order'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  /// Raises an order and books its minimum-stock lines.
  ///
  /// These used to commit together inside one server transaction. Without
  /// server scripts they cannot, so the order is written first and the stock
  /// booked immediately after — and if any booking is refused, the order is
  /// unwound rather than left standing against stock it never got.
  ///
  /// The order of the two matters. A reservation has to name the order it is
  /// held against, so the order has to exist first; the alternative is stock
  /// held against nothing, which nobody would ever notice was stranded.
  /// Refuses to raise an order for a party with no delivery route.
  ///
  /// The screens check this before letting a rep start, which is where a rep
  /// should meet it. This is the backstop: the route is what production is
  /// given in place of the customer's name, so an order without one is one the
  /// floor cannot deliver, and it must not be creatable through any path — an
  /// unsent draft synced later, or a screen added in future that forgets.
  static Future<void> _requireRoute(String doctype, String name) async {
    final rows = await _list(doctype,
        fields: '["name","custom_sales_route"]',
        filters: '[["name","=","$name"]]',
        limit: 1);
    final route =
        rows.isEmpty ? '' : '${rows.first['custom_sales_route'] ?? ''}'.trim();
    if (route.isEmpty || route == 'null') {
      throw Exception('No delivery route is set for this '
          '${doctype == 'Lead' ? 'lead' : 'customer'}. '
          'Set the route first — the factory has nothing else telling it where '
          'the order goes.');
    }
  }

  static Future<String> placeOrder({
    required String customer,
    required String company,
    required List<Map<String, dynamic>> items,
    required String deliveryDate,
  }) async {
    await _requireRoute('Customer', customer);
    final name = await createSalesOrder(
        customer: customer,
        company: company,
        items: items,
        deliveryDate: deliveryDate);

    // Best-effort — see refreshDuplicateFlag.
    await refreshDuplicateFlag(name);
    return name;
  }

  /// Raises an order against a lead.
  ///
  /// Identical in every respect that matters to [placeOrder]. A lead is a
  /// customer who has not been invoiced yet, not a different kind of order.
  static Future<String> placeLeadOrder({
    required String lead,
    required List<Map<String, dynamic>> items,
    required String deliveryDate,
    required double total,
  }) async {
    await _requireRoute('Lead', lead);
    final body = {
      'lead': lead,
      'sales_person': Session.I.salesPerson,
      'status': 'Pending Approval',
      'delivery_date': deliveryDate,
      // Off the server clock, for the same reason a Sales Order's is: this is
      // what settles who ordered first when stock is short.
      'custom_order_placed_at': nowStamp(),
      'custom_rate_approved': 0,
      'items': items,
      'total_amount': total,
    };
    final r = await Session.I.dio.post(_res('Lead Order'), data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
    return r.data['data']['name'] as String;
  }

  static Future<String> createComplaint({
    required String customer,
    required String complaintType,
    required String description,
  }) async {
    final body = {
      'customer': customer,
      'sales_person': Session.I.salesPerson,
      'complaint_type': complaintType,
      'description': description,
      'status': 'Open',
    };
    final r = await Session.I.dio.post(_res('Customer Complaint'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<String> createCollectionEntry({
    required String customer,
    required String salesPerson,
    required double amount,
    required String mode,
    String? referenceNo,
    required double lat,
    required double lng,
  }) async {
    final body = {
      'collection_date': today(),
      'sales_person': salesPerson,
      'customer': customer,
      'amount': amount,
      'mode_of_payment': mode,
      if (referenceNo != null && referenceNo.isNotEmpty)
        'reference_no': referenceNo,
      'latitude': lat,
      'longitude': lng,
      'status': 'Collected',
    };
    final r = await Session.I.dio.post(_res('Collection Entry'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  // -------- Trips (rich model) --------
  static Future<List<Map<String, dynamic>>> getMyTrips() async {
    // Own trips merged with ones this rep was tagged into — cached together for
    // the same reason visits are: either half alone reads as a missing trip.
    return _cachedRows(CacheKeys.trips, () async {
      final me = Session.I.salesPerson;
      const f =
          '["name","trip_date","purpose","status","total_distance_km","odometer_distance_km","primary_mode","start_odometer","end_odometer","sales_person"]';
      final owned = await _list('Trip',
          fields: f,
          filters: '[["sales_person","=","$me"],["status","!=","Cancelled"]]',
          orderBy: 'trip_date desc',
          limit: 100);
      final byName = <String, Map<String, dynamic>>{};
      for (final t in owned) {
        t['_shared'] = false;
        byName['${t['name']}'] = t;
      }
      final shared = await _list('Trip',
          fields: f,
          filters:
              '[["tagged_csv","like","%|$me|%"],["status","!=","Cancelled"]]',
          orderBy: 'trip_date desc',
          limit: 100);
      for (final t in shared) {
        final n = '${t['name']}';
        if (!byName.containsKey(n)) {
          t['_shared'] = true;
          byName[n] = t;
        }
      }
      final list = byName.values.toList();
      list.sort((a, b) => '${b['trip_date']}'.compareTo('${a['trip_date']}'));
      return list;
    });
  }

  static Future<Map<String, dynamic>?> getTrip(String name) async {
    final r =
    await Session.I.dio.get('${_res('Trip')}/${Uri.encodeComponent(name)}');
    if (r.data is Map && r.data['data'] is Map) {
      return Map<String, dynamic>.from(r.data['data']);
    }
    return null;
  }

  static Future<String> createTrip({
    required String tripDate,
    required String purpose,
    String? route,
    double startOdometer = 0,
    double? lat,
    double? lng,
  }) async {
    final now =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final body = {
      'sales_person': Session.I.salesPerson,
      'trip_date': tripDate,
      'purpose': purpose,
      'status': 'Active',
      'start_time': now,
      'start_odometer': startOdometer,
      if (route != null && route.isNotEmpty) 'route': route,
      if (lat != null) 'start_latitude': lat,
      if (lng != null) 'start_longitude': lng,
    };
    final r = await Session.I.dio.post(_res('Trip'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<void> endTrip({
    required String name,
    double? lat,
    double? lng,
  }) async {
    final now =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final body = {
      'status': 'Completed',
      'end_time': now,
      if (lat != null) 'end_latitude': lat,
      if (lng != null) 'end_longitude': lng,
    };
    await _put('Trip', name, body);
  }

  static Future<void> cancelTrip(String name) async {
    final now =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    await _put('Trip', name, {'status': 'Cancelled', 'end_time': now});
  }

  static Future<void> updateTrip(String name, Map<String, dynamic> body) =>
      _put('Trip', name, body);

  // ---- Trip rates (office-controlled, single-doctype) ----
  static Future<Map<String, dynamic>> getTripRates() async {
    final r = await Session.I.dio
        .get('${_res('Trip Rate Settings')}/Trip Rate Settings');
    if (r.data is Map && r.data['data'] is Map) {
      return Map<String, dynamic>.from(r.data['data']);
    }
    return {};
  }

  static Future<void> saveTripRates(Map<String, dynamic> body) =>
      _put('Trip Rate Settings', 'Trip Rate Settings', body);

  static double rateForMode(Map<String, dynamic> rates, String? mode) {
    double g(String k) => (rates[k] is num) ? (rates[k] as num).toDouble() : 0.0;
    switch (mode) {
      case 'Own Vehicle':
        return g('rate_own_car');
      case 'Bike':
        return g('rate_own_bike');
      case 'Company Vehicle (Car)':
        return g('rate_company_car');
      case 'Company Vehicle (Bike)':
        return g('rate_company_bike');
      case 'Company Vehicle': // legacy
        return g('rate_company_car');
      case 'Bus':
      case 'Taxi':
      case 'Mixed':
        return 0;
      default:
        return 0;
    }
  }

  static double _legDist(Map l) {
    final hasOdo = (l['has_odometer'] ?? 1) == 1;
    final s = (l['start_odometer'] is num)
        ? (l['start_odometer'] as num).toDouble()
        : 0.0;
    final e =
    (l['end_odometer'] is num) ? (l['end_odometer'] as num).toDouble() : 0.0;
    if (hasOdo && e > s) return e - s;
    return (l['leg_distance_km'] is num)
        ? (l['leg_distance_km'] as num).toDouble()
        : 0.0;
  }

  // Replace the trip's vehicle legs and recompute distance + cost estimate.
  static Future<void> saveTripLegs(
      String tripName, List<Map<String, dynamic>> legs) async {
    final rates = await getTripRates();
    final forTotals = <TripLegInput>[];
    final clean = <Map<String, dynamic>>[];
    for (final l in legs) {
      final d = _legDist(l);
      // Collected for the shared rule rather than totalled here — the
      // dashboard writes trips too, and the two must agree exactly on what a
      // rep is paid. See core/trip_totals.dart and
      // shared/fixtures/trip_totals.json.
      forTotals.add(TripLegInput(
        mode: l['mode'] as String?,
        km: d,
        hasOdometer: (l['has_odometer'] ?? 1) == 1,
        claimedAmount: ((l['claimed_amount'] ?? 0) as num).toDouble(),
      ));
      clean.add({
        if (l['name'] != null) 'name': l['name'],
        'mode': l['mode'],
        'vehicle_no': l['vehicle_no'],
        'has_odometer': l['has_odometer'] ?? 1,
        'start_odometer': l['start_odometer'] ?? 0,
        'end_odometer': l['end_odometer'] ?? 0,
        'leg_distance_km': d,
        'claimed_amount': l['claimed_amount'] ?? 0,
        'custom_approved_amount': l['custom_approved_amount'] ?? 0,
        'status': l['status'] ?? 'Pending',
        'custom_approval_remarks': l['custom_approval_remarks'],
        'custom_not_verified': l['custom_not_verified'] ?? 0,
        'custom_actual_start_odometer': l['custom_actual_start_odometer'] ?? 0,
        'custom_actual_end_odometer': l['custom_actual_end_odometer'] ?? 0,
        'start_odometer_photo': l['start_odometer_photo'],
        'end_odometer_photo': l['end_odometer_photo'],
        'custom_end_time': l['custom_end_time'],
        'remarks': l['remarks'],
      });
    }
    final totals =
        tripTotalsFromLegs(forTotals, (m) => rateForMode(rates, m));
    final body = <String, dynamic>{
      'legs': clean,
      'odometer_distance_km': totals.odometerKm,
      'total_distance_km': totals.totalKm,
      'estimated_cost': totals.cost,
      'primary_mode': totals.primaryMode,
      'cost_basis': totals.costBasis,
    };
    await _put('Trip', tripName, body);
  }

  // Upload a file attached to a parent doc, return its file_url (for child rows).
  static Future<String?> uploadFileGetUrl({
    required String filePath,
    String? doctype,
    String? docname,
    String filename = 'bill.jpg',
  }) async {
    final map = <String, dynamic>{
      'file': await MultipartFile.fromFile(filePath, filename: filename),
      'is_private': 1,
    };
    if (doctype != null) map['doctype'] = doctype;
    if (docname != null) map['docname'] = docname;
    final r =
    await Session.I.dio.post('/api/method/upload_file', data: FormData.fromMap(map));
    if (r.statusCode == 200 || r.statusCode == 201) {
      final d = r.data;
      if (d is Map && d['message'] is Map) {
        return d['message']['file_url'] as String?;
      }
    }
    return null;
  }

  static Future<void> saveTripExpenses(
      String tripName, List<Map<String, dynamic>> expenses) async {
    double total = 0;
    // Built by `tripExpenseRow`, which is the single place that knows which
    // fields a row carries. A whitelist inline here is what silently dropped
    // `custom_for_person` on every save.
    final clean = expenses.map((e) {
      if (e['amount'] is num) total += (e['amount'] as num).toDouble();
      return tripExpenseRow(e);
    }).toList();
    await _put(
        'Trip', tripName, {'expenses': clean, 'total_expenses': total});
  }

  /// This rep's trips between two dates, with distance and expenses.
  ///
  /// Both the trips they own and the ones they were tagged onto, because a rep
  /// riding with a colleague still travelled the distance and a summary that
  /// omitted those days would read as time off.
  ///
  /// Each row carries `_mine`, false when the trip belongs to a colleague who
  /// tagged this rep onto it. Whether the cost is *shared* is read off
  /// `tagged_csv` by `isSharedTrip` rather than flagged here, so one definition
  /// serves both the totals and the row.
  static Future<List<Map<String, dynamic>>> getExpenseSummary({
    required String from,
    required String to,
  }) async {
    final me = Session.I.salesPerson;
    if (me == null) return [];
    const f = '["name","trip_date","purpose","status","sales_person",'
        '"total_distance_km","odometer_distance_km","total_expenses",'
        '"estimated_cost","final_cost","tagged_csv"]';
    final range = '["trip_date",">=","$from"],["trip_date","<=","$to"],'
        '["status","!=","Cancelled"]';

    final results = await Future.wait([
      _list('Trip',
          fields: f,
          filters: '[$range,["sales_person","=","$me"]]',
          orderBy: 'trip_date desc',
          limit: 0),
      // Trips somebody else raised and tagged this rep onto.
      _list('Trip',
              fields: f,
              filters: '[$range,["tagged_csv","like","%|$me|%"]]',
              orderBy: 'trip_date desc',
              limit: 0)
          .catchError((_) => <Map<String, dynamic>>[]),
    ]);

    final byName = <String, Map<String, dynamic>>{};
    for (final t in results[0]) {
      t['_mine'] = true;
      byName['${t['name']}'] = t;
    }
    for (final t in results[1]) {
      // A trip this rep owns *and* is tagged on is still one trip.
      final n = '${t['name']}';
      if (byName.containsKey(n)) continue;
      t['_mine'] = false;
      byName[n] = t;
    }

    final list = byName.values.toList()
      ..sort((a, b) => '${b['trip_date']}'.compareTo('${a['trip_date']}'));
    return list;
  }

  // HR: all trips with expense totals + tagged members.
  static Future<List<Map<String, dynamic>>> getAllTripsForHR() => _list('Trip',
      fields:
      '["name","trip_date","purpose","status","sales_person","estimated_cost","final_cost","total_expenses","total_distance_km","tagged_csv"]',
      orderBy: 'trip_date desc',
      limit: 200);

  static Future<List<Map<String, dynamic>>> getTrips() => _list('Trip Log',
      fields:
      '["name","sales_person","vehicle_no","trip_date","start_odometer","end_odometer","distance_km"]',
      filters: _mineFilter(),
      limit: 50);

  static Future<String> createTripStart({
    required String salesPerson,
    required String vehicleNo,
    required double startOdo,
    required double lat,
    required double lng,
  }) async {
    final stamp =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final body = {
      'trip_date': stamp.substring(0, 10),
      'sales_person': salesPerson,
      'vehicle_no': vehicleNo,
      'start_time': stamp,
      'start_odometer': startOdo,
      'start_latitude': lat,
      'start_longitude': lng,
    };
    final r = await Session.I.dio.post(_res('Trip Log'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<void> tripEnd({
    required String tripName,
    required double startOdo,
    required double endOdo,
    required double lat,
    required double lng,
  }) async {
    final stamp =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final body = {
      'end_time': stamp,
      'end_odometer': endOdo,
      'distance_km': endOdo - startOdo,
      'end_latitude': lat,
      'end_longitude': lng,
    };
    final r = await Session.I.dio
        .put('${_res('Trip Log')}/${Uri.encodeComponent(tripName)}', data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
  }

  /// Whether this login's own capture stands without anyone checking it.
  ///
  /// Only a sales manager's does. They are the person the queue would send it
  /// to, so routing their own capture into their own inbox asks them to
  /// approve themselves — and the photo exists solely for that check, which is
  /// why they are not asked for one either.
  ///
  /// A rep's capture still goes through both. The photograph is the only
  /// evidence that the coordinates belong to the shop rather than to wherever
  /// the phone happened to be, and it is a manager who says so.
  ///
  /// Decided here rather than on each screen, so no caller can forget it and
  /// quietly let a rep self-verify.
  static bool get _selfVerifies => Session.I.isManager;

  static String get _capturedStatus =>
      _selfVerifies ? 'Verified' : 'Pending Verification';

  /// True when this login must photograph the place it is capturing.
  /// Read by the capture screens; the same rule as [_selfVerifies], inverted.
  static bool get locationPhotoRequired => !_selfVerifies;

  static Future<void> captureCustomerLocation({
    required String customer,
    required String salesPerson,
    required double lat,
    required double lng,
  }) async {
    final stamp =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final body = {
      'custom_latitude': lat,
      'custom_longitude': lng,
      'custom_location_status': _capturedStatus,
      'custom_location_captured_by': salesPerson,
      'custom_location_captured_on': stamp,
      // A self-verified capture has to write the verified pair as well.
      // Nothing else will: there is no queue entry for anyone to approve, and
      // those are the coordinates every later check reads.
      if (_selfVerifies) ...{
        'custom_verified_latitude': lat,
        'custom_verified_longitude': lng,
      },
    };
    final r = await Session.I.dio.put(
        '${_res('Customer')}/${Uri.encodeComponent(customer)}',
        data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
  }

  static Future<void> uploadPhoto({
    required String docname,
    required String fieldname,
    required String filePath,
    String doctype = 'Trip Log',
    String filename = 'photo.jpg',
  }) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, filename: filename),
      'doctype': doctype,
      'docname': docname,
      'fieldname': fieldname,
      'is_private': 1,
    });
    final r = await Session.I.dio.post('/api/method/upload_file', data: form);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
  }

  // -------- Attendance --------
  static Future<List<Map<String, dynamic>>> getTodayAttendance(
      String salesPerson) =>
      _list('Attendance Log',
          fields:
          '["name","sales_person","attendance_date","status","punch_in_time","punch_out_time","working_hours"]',
          filters:
          '[["sales_person","=","$salesPerson"],["attendance_date","=","${today()}"]]',
          limit: 1);

  // ---- Attendance calendar + regularization ----
  static String _monthBounds(int year, int month, bool last) {
    final y = year.toString().padLeft(4, '0');
    final m = month.toString().padLeft(2, '0');
    if (!last) return '$y-$m-01';
    final lastDay = DateTime(year, month + 1, 0).day;
    return '$y-$m-${lastDay.toString().padLeft(2, '0')}';
  }

  static Future<List<Map<String, dynamic>>> getAttendanceForMonth(
      String rep, int year, int month) {
    return _list('Attendance Log',
        fields:
        '["name","attendance_date","punch_in_time","punch_out_time","working_hours","status"]',
        filters:
        '[["sales_person","=","$rep"],["attendance_date","between",["${_monthBounds(year, month, false)}","${_monthBounds(year, month, true)}"]]]',
        orderBy: 'attendance_date asc');
  }

  static Future<List<Map<String, dynamic>>> getRegularizationsForMonth(
      String rep, int year, int month) {
    return _list('Attendance Regularization',
        fields:
        '["name","attendance_date","status","requested_punch_in","requested_punch_out","reason"]',
        filters:
        '[["sales_person","=","$rep"],["attendance_date","between",["${_monthBounds(year, month, false)}","${_monthBounds(year, month, true)}"]]]',
        orderBy: 'attendance_date asc');
  }

  static Future<String> myTeamManager() async {
    final me = Session.I.salesPerson;
    if (me == null) return '';
    final sp = await _list('Sales Person',
        fields: '["custom_team_manager"]',
        filters: '[["name","=","$me"]]',
        limit: 1);
    return sp.isNotEmpty
        ? (sp.first['custom_team_manager'] ?? '').toString()
        : '';
  }

  static Future<void> createRegularization({
    required String attendanceDate,
    required String? punchIn,
    required String? punchOut,
    required String reason,
  }) async {
    final isMgr = Session.I.isManager;
    final body = {
      'sales_person': Session.I.salesPerson,
      'attendance_date': attendanceDate,
      'requested_punch_in': punchIn,
      'requested_punch_out': punchOut,
      'reason': reason,
      'requester_is_manager': isMgr ? 1 : 0,
      'team_manager': await myTeamManager(),
      'approver_type': isMgr ? 'HR' : 'Sales Manager',
      'status': 'Pending Approval',
    };
    final r =
    await Session.I.dio.post(_res('Attendance Regularization'), data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
  }

  static Future<List<Map<String, dynamic>>>
  getPendingRegularizationsForManager() {
    final team = Session.I.managedTeam;
    if (team == null || team.isEmpty) return Future.value([]);
    return _list('Attendance Regularization',
        fields:
        '["name","sales_person","attendance_date","requested_punch_in","requested_punch_out","reason","status"]',
        filters:
        '[["status","=","Pending Approval"],["approver_type","=","Sales Manager"],["team_manager","=","$team"]]',
        orderBy: 'attendance_date asc');
  }

  static Future<List<Map<String, dynamic>>> getPendingRegularizationsForHR() {
    return _list('Attendance Regularization',
        fields:
        '["name","sales_person","attendance_date","requested_punch_in","requested_punch_out","reason","status"]',
        filters:
        '[["status","=","Pending Approval"],["approver_type","=","HR"]]',
        orderBy: 'attendance_date asc');
  }

  static Future<void> approveRegularization(
      Map<String, dynamic> reg, bool approve) async {
    final name = reg['name'] as String;
    if (!approve) {
      await _put('Attendance Regularization', name,
          {'status': 'Rejected', 'decided_by': Session.I.email});
      return;
    }
    final rep = reg['sales_person'] as String;
    final date = reg['attendance_date'] as String;
    final pin = reg['requested_punch_in'];
    final pout = reg['requested_punch_out'];
    double hours = 0;
    try {
      if (pin != null && pout != null) {
        final a = DateTime.parse('$pin'.replaceFirst(' ', 'T'));
        final b = DateTime.parse('$pout'.replaceFirst(' ', 'T'));
        hours = b.difference(a).inMinutes / 60.0;
        if (hours < 0) hours = 0;
      }
    } catch (_) {}
    hours = double.parse(hours.toStringAsFixed(2));
    final logBody = {
      'punch_in_time': pin,
      'punch_out_time': pout,
      'working_hours': hours,
      'status': pout != null ? 'Punched Out' : 'Punched In',
    };
    final existing = await _list('Attendance Log',
        fields: '["name"]',
        filters: '[["sales_person","=","$rep"],["attendance_date","=","$date"]]',
        limit: 1);
    if (existing.isNotEmpty) {
      await _put('Attendance Log', existing.first['name'] as String, logBody);
    } else {
      await Session.I.dio.post(_res('Attendance Log'),
          data: {'sales_person': rep, 'attendance_date': date, ...logBody});
    }
    await _put('Attendance Regularization', name,
        {'status': 'Approved', 'decided_by': Session.I.email});
  }

  // Missed punch-out (punched in, never out) -> alert next morning. Deliberately
  // scoped to *yesterday*: a rep who is still out at 10 PM has not missed
  // anything yet, so nothing nags them the same night.
  static Future<Map<String, dynamic>?> getMissedPunchYesterday() async {
    final me = Session.I.salesPerson;
    if (me == null) return null;
    final y = ServerClock.I.now().subtract(const Duration(days: 1));
    final ds =
        '${y.year}-${y.month.toString().padLeft(2, '0')}-${y.day.toString().padLeft(2, '0')}';
    final list = await _list('Attendance Log',
        fields: '["name","attendance_date","punch_in_time","punch_out_time"]',
        filters: '[["sales_person","=","$me"],["attendance_date","=","$ds"]]',
        limit: 1);
    if (list.isEmpty) return null;
    final r = list.first;
    if (r['punch_in_time'] != null && r['punch_out_time'] == null) return r;
    return null;
  }

  /// `yyyy-MM-dd HH:mm:ss`, the shape Frappe wants for a Datetime field.
  static String _stamp(DateTime t) =>
      t.toIso8601String().substring(0, 19).replaceFirst('T', ' ');

  static Future<String> punchIn({
    required String salesPerson,
    required double lat,
    required double lng,
  }) async {
    final now = ServerClock.I.now();
    if (minuteOfDay(now) < kPunchInFromMinute) {
      throw const AttendanceWindowError(
          'Punch-in opens at 5:00 AM. If you started before that, punch in now '
          'and request a regularization for the earlier time.');
    }
    final stamp = _stamp(now);
    final body = {
      'attendance_date': stamp.substring(0, 10),
      'sales_person': salesPerson,
      'status': 'Punched In',
      'punch_in_time': stamp,
      'punch_in_latitude': lat,
      'punch_in_longitude': lng,
    };
    final r = await Session.I.dio.post(_res('Attendance Log'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  /// Records the moment the rep finished. Punching out a second time is
  /// allowed and simply replaces the first — the last one is the official
  /// punch-out, and the hours are recomputed from it.
  static Future<double> punchOut({
    required String name,
    required String punchInTime,
    required double lat,
    required double lng,
  }) async {
    final now = ServerClock.I.now();
    if (minuteOfDay(now) > kPunchOutUntilMinute) {
      throw AttendanceWindowError(
        'Punch-out closed at 9:30 PM. Request a regularization for today and '
        'your manager can set the time you actually finished.',
        regularizeDate: DateTime(now.year, now.month, now.day),
      );
    }
    double hours = 0;
    try {
      final tin = DateTime.parse(punchInTime.replaceFirst(' ', 'T'));
      hours = now.difference(tin).inMinutes / 60.0;
      if (hours < 0) hours = 0;
    } catch (_) {}
    hours = double.parse(hours.toStringAsFixed(2));
    final body = {
      'punch_out_time': _stamp(now),
      'punch_out_latitude': lat,
      'punch_out_longitude': lng,
      'working_hours': hours,
      'status': 'Punched Out',
    };
    final r = await Session.I.dio.put(
        '${_res('Attendance Log')}/${Uri.encodeComponent(name)}',
        data: body);
    if (r.statusCode == 200 || r.statusCode == 201) return hours;
    throw Exception(_frappeError(r));
  }

  // -------- Expenses --------
  static Future<List<Map<String, dynamic>>> getMyExpenses() => _list(
      'Expense Entry',
      fields:
      '["name","sales_person","expense_date","category","amount","status","remarks"]',
      filters: _mineFilter(),
      limit: 50);

  static Future<String> createExpense({
    required String salesPerson,
    required String category,
    required double amount,
    String? remarks,
  }) async {
    final body = {
      'expense_date': today(),
      'sales_person': salesPerson,
      'category': category,
      'amount': amount,
      'status': 'Pending',
      if (remarks != null && remarks.isNotEmpty) 'remarks': remarks,
    };
    final r = await Session.I.dio.post(_res('Expense Entry'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  // -------- Day map (rep's day plotted on a map) --------
  // Read-only: uses coordinate fields already written by check-in, punch and
  // trip start/end. No backend changes needed.
  static Future<List<Map<String, dynamic>>> getVisitsForDay(
      String rep, String date) async =>
      _withLeadNames(await _list('Sales Visit',
          fields:
          '[$_visitFields,"check_in_time","check_in_latitude","check_in_longitude"]',
          filters: '[["sales_person","=","$rep"],["visit_date","=","$date"]]',
          orderBy: 'check_in_time asc'));

  static Future<List<Map<String, dynamic>>> getAttendanceForDay(
      String rep, String date) =>
      _list('Attendance Log',
          fields:
          '["name","attendance_date","punch_in_time","punch_out_time","punch_in_latitude","punch_in_longitude","punch_out_latitude","punch_out_longitude"]',
          filters:
          '[["sales_person","=","$rep"],["attendance_date","=","$date"]]',
          limit: 10);

  static Future<List<Map<String, dynamic>>> getTripsForDay(
      String rep, String date) =>
      _list('Trip',
          fields:
          '["name","purpose","trip_date","start_time","end_time","start_latitude","start_longitude","end_latitude","end_longitude"]',
          filters: '[["sales_person","=","$rep"],["trip_date","=","$date"]]',
          orderBy: 'creation asc');

  // Reps the current user may view on the day map.
  // HR / GM: everyone. Plain manager: their team (plus self if they're a rep).
  static Future<List<Map<String, dynamic>>> getPickableReps() async {
    if (Session.I.isHR || Session.I.isGM) {
      final list = await _list('Sales Person',
          fields: '["name","sales_person_name"]',
          filters: '[["is_group","=",0]]',
          orderBy: 'name asc');
      return list
          .map((e) => {
        'name': e['name'],
        'label': (e['sales_person_name'] ?? e['name']),
      })
          .toList();
    }
    final me = Session.I.salesPerson;
    final reps = <Map<String, dynamic>>[];
    if (me != null && me.isNotEmpty && !Session.I.teamReps.contains(me)) {
      reps.add({'name': me, 'label': Session.I.salesPersonLabel ?? me});
    }
    reps.addAll(Session.I.teamReps.map((r) => {'name': r, 'label': r}));
    return reps;
  }

  // Append one GPS point to a trip's route (read-modify-write the child list,
  // same pattern as legs/expenses). Used by the 20-min route tracker.
  /// Appends a batch of recorded points to a trip in one write.
  ///
  /// A batch rather than one call per point, because a phone coming back into
  /// signal after an hour has a dozen waiting, and each one otherwise re-reads
  /// the whole trip and rewrites the whole child table.
  ///
  /// Each point carries the time it was actually taken. Stamping them on
  /// arrival would draw the route through wherever the rep happened to regain
  /// signal rather than where they had been.
  static Future<void> appendTripGpsPoints(
      String tripName, List<TripPoint> points) async {
    if (points.isEmpty) return;
    final trip = await getTrip(tripName);
    final existing =
        ((trip?['gps_points'] as List?) ?? []).cast<Map<String, dynamic>>();
    final rows = existing
        .map((p) => {
              if (p['name'] != null) 'name': p['name'],
              'timestamp': p['timestamp'],
              'latitude': p['latitude'],
              'longitude': p['longitude'],
            })
        .toList();
    final seen = <String>{
      for (final r in rows) '${r['timestamp']}|${r['latitude']}|${r['longitude']}'
    };
    for (final p in points) {
      // A flush that half-succeeded and was retried would otherwise double the
      // route back on itself.
      final key = '${p.at}|${p.lat}|${p.lng}';
      if (!seen.add(key)) continue;
      rows.add({'timestamp': p.at, 'latitude': p.lat, 'longitude': p.lng});
    }
    await _put('Trip', tripName, {'gps_points': rows});
  }

  static Future<void> appendTripGpsPoint(
          String tripName, double lat, double lng) =>
      appendTripGpsPoints(
          tripName, [TripPoint(tripName, lat, lng, nowStamp())]);

  // -------- Leave (financial-year allowance of 12 days) --------
  static Future<List<Map<String, dynamic>>> getMyLeaves() => _cachedRows(
      CacheKeys.leaves,
      () => _list('Leave Request',
          fields:
              '["name","leave_date","half_day","half_day_period","leave_days","reason","status","approver_type","is_hr_entry"]',
          filters: _mineFilter('sales_person'),
          orderBy: 'leave_date desc',
          limit: 100));

  /// What paid leave this rep has left.
  ///
  /// A running accrual, not an annual allowance: a balance carried forward
  /// from before the scheme started, plus one day a month since, less what has
  /// been approved. This used to hand everybody a flat twelve days per
  /// financial year, which was wrong in shape as well as in number — nobody
  /// has twelve, and the balances carry forward rather than resetting each
  /// April. See core/leave_balance.dart.
  ///
  /// Returns [LeaveBalance.none] for anybody not on the scheme. That is a
  /// different answer from zero and every caller has to keep it different:
  /// five reps carry a zero balance and still accrue.
  static Future<LeaveBalance> getLeaveBalance(String rep) async {
    // The scheme itself, off the rep's own record so HR can change a balance
    // in Desk without an app release.
    String? from;
    double opening = 0;
    try {
      final rows = await _list('Sales Person',
          fields:
              '["name","custom_leave_opening_balance","custom_leave_accrual_from"]',
          filters: '[["name","=","$rep"]]',
          limit: 1);
      if (rows.isNotEmpty) {
        from = '${rows.first['custom_leave_accrual_from'] ?? ''}';
        opening = _toNum(rows.first['custom_leave_opening_balance']);
      }
    } catch (_) {
      // Unreadable reads as "not on the scheme" rather than as twelve days.
      // Inventing an entitlement is the one failure that costs money.
      return LeaveBalance.none;
    }
    final start = (from ?? '').trim();
    if (start.isEmpty || start == 'null') return LeaveBalance.none;

    // Only leave since accrual began. The opening balance is already net of
    // anything taken before then — counting it twice would charge a rep for
    // the same days again.
    final list = await _cachedRows(
        CacheKeys.leaveBalance,
        () => _list('Leave Request',
            fields: '["leave_days","status","leave_date"]',
            filters:
                '[["sales_person","=","$rep"],["leave_date",">=","${start.substring(0, 10)}"]]',
            limit: 0));

    double taken = 0, pending = 0;
    for (final e in list) {
      final d = _toNum(e['leave_days']);
      switch ('${e['status']}') {
        case 'Approved':
          taken += d;
        case 'Pending Approval':
          pending += d;
      }
    }

    return leaveBalanceFor(
      accrualFrom: start,
      opening: opening,
      taken: taken,
      pending: pending,
      asOf: ServerClock.I.now(),
    );
  }

  static Future<String> createLeaveRequest({
    required String leaveDate,
    required bool halfDay,
    String? halfPeriod,
    required String reason,
  }) async {
    final isMgr = Session.I.isManager;
    final body = {
      'sales_person': Session.I.salesPerson,
      'leave_date': leaveDate,
      'half_day': halfDay ? 1 : 0,
      if (halfDay) 'half_day_period': halfPeriod ?? 'Morning',
      'leave_days': halfDay ? 0.5 : 1,
      'reason': reason,
      'status': 'Pending Approval',
      'approver_type': isMgr ? 'HR' : 'Sales Manager',
      'team_manager': await myTeamManager(),
      'requester_is_manager': isMgr ? 1 : 0,
    };
    final r = await Session.I.dio.post(_res('Leave Request'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<List<Map<String, dynamic>>> getPendingLeaveForManager() {
    final team = Session.I.managedTeam;
    if (team == null || team.isEmpty) return Future.value([]);
    return _list('Leave Request',
        fields:
        '["name","sales_person","leave_date","half_day","half_day_period","leave_days","reason","status"]',
        filters:
        '[["status","=","Pending Approval"],["approver_type","=","Sales Manager"],["team_manager","=","$team"]]',
        orderBy: 'leave_date asc');
  }

  static Future<List<Map<String, dynamic>>> getPendingLeaveForHR() =>
      _list('Leave Request',
          fields:
          '["name","sales_person","leave_date","half_day","half_day_period","leave_days","reason","status"]',
          filters:
          '[["status","=","Pending Approval"],["approver_type","=","HR"]]',
          orderBy: 'leave_date asc');

  // Rep leaves (decided by their sales manager) - HR sees these read-only.
  static Future<List<Map<String, dynamic>>> getTeamLeavesForHR() => _list(
      'Leave Request',
      fields:
      '["name","sales_person","leave_date","half_day","half_day_period","leave_days","reason","status","team_manager"]',
      filters: '[["approver_type","=","Sales Manager"]]',
      orderBy: 'leave_date desc',
      limit: 40);

  static Future<void> approveLeave(String name, bool approve) => _put(
      'Leave Request',
      name,
      {'status': approve ? 'Approved' : 'Rejected', 'decided_by': Session.I.email});

  static Future<String> hrCreateLeave({
    required String rep,
    required String leaveDate,
    required bool halfDay,
    String? halfPeriod,
    required String reason,
  }) async {
    final body = {
      'sales_person': rep,
      'leave_date': leaveDate,
      'half_day': halfDay ? 1 : 0,
      if (halfDay) 'half_day_period': halfPeriod ?? 'Morning',
      'leave_days': halfDay ? 0.5 : 1,
      'reason': reason,
      'status': 'Approved',
      'approver_type': 'HR',
      'is_hr_entry': 1,
      'decided_by': Session.I.email,
    };
    final r = await Session.I.dio.post(_res('Leave Request'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<List<Map<String, dynamic>>> getLeavesForMonth(
      String rep, int year, int month) {
    return _list('Leave Request',
        fields:
        '["leave_date","half_day","half_day_period","leave_days","status"]',
        filters:
        '[["sales_person","=","$rep"],["status","=","Approved"],["leave_date","between",["${_monthBounds(year, month, false)}","${_monthBounds(year, month, true)}"]]]',
        orderBy: 'leave_date asc');
  }

  // -------- Customer sites (multiple verified locations per customer) --------
  static Future<List<Map<String, dynamic>>> getCustomerSites(
      String customer) =>
      _list('Customer Site',
          fields:
          '["name","site_name","route","latitude","longitude","verified_latitude","verified_longitude","location_status"]',
          filters: '[["customer","=","$customer"]]',
          orderBy: 'creation asc',
          limit: 0);

  /// Sites belonging to a lead. A lead can have several premises before it is
  /// ever converted, and each one is a separate drop with its own route.
  static Future<List<Map<String, dynamic>>> getLeadSites(String lead) =>
      _list('Customer Site',
          fields:
          '["name","site_name","route","latitude","longitude","verified_latitude","verified_longitude","location_status"]',
          filters: '[["lead","=","$lead"]]',
          orderBy: 'creation asc',
          limit: 0);

  /// Every location that is captured can carry its own route, because every
  /// one of them is a separate place a van has to reach. A customer's second
  /// yard may be on an entirely different run from their office.
  static Future<void> setSiteRoute(String siteName, String route) =>
      _put('Customer Site', siteName, {'route': route});

  static Future<String> createCustomerSite({
    String? customer,
    String? lead,
    required String siteName,
    required double lat,
    required double lng,
    String? route,
  }) async {
    final body = {
      if (customer != null && customer.isNotEmpty) 'customer': customer,
      if (lead != null && lead.isNotEmpty) 'lead': lead,
      'site_name': siteName,
      'latitude': lat,
      'longitude': lng,
      if (route != null && route.isNotEmpty) 'route': route,
      'location_status': 'Pending Verification',
      'captured_by': Session.I.salesPerson,
      'captured_on': nowStamp(),
    };
    final r = await Session.I.dio.post(_res('Customer Site'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  /// Removes a site captured by mistake — the wrong premises, or a duplicate
  /// of one already on the list.
  ///
  /// Deleted rather than disabled: a site that was never a real drop should not
  /// keep appearing in a route list for somebody to plan a van around.
  static Future<void> deleteSite(String name) async {
    final r = await Session.I.dio
        .delete('${_res('Customer Site')}/${Uri.encodeComponent(name)}');
    if (r.statusCode != 200 && r.statusCode != 202) {
      throw Exception(_frappeError(r));
    }
  }

  static Future<List<Map<String, dynamic>>> getPendingSiteVerifications() {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    return _list('Customer Site',
        // `lead` as well as `customer`: a site can belong to either, and a
        // verification card headed by a blank customer tells the manager
        // nothing about what they are approving.
        fields:
        '["name","site_name","customer","lead","captured_by","latitude","longitude","banner_photo"]',
        filters:
        '[["location_status","=","Pending Verification"],["captured_by","in",${_inList(team)}]]',
        orderBy: 'modified desc');
  }

  static Future<void> approveSite(
      String name, bool approve, dynamic lat, dynamic lng) {
    if (approve) {
      return _put('Customer Site', name, {
        'location_status': 'Verified',
        'verified_latitude': lat,
        'verified_longitude': lng,
      });
    }
    return _put('Customer Site', name, {'location_status': 'Rejected'});
  }

  // Approved POs (ready for SAP) for the logged-in production manager's unit.
  /// Approved orders for the production floor, with the destination route and
  /// the customer's name.
  ///
  /// The customer was deliberately withheld here until 19 Aug 2026 — the floor
  /// plans vans, not relationships, and the route was held to be enough.
  /// Dispatch is what changed it: somebody loading a vehicle has to know whose
  /// pallet is whose, and a route does not say that when two customers sit on
  /// one round. Both are resolved here in one lookup for the whole list.
  static Future<List<Map<String, dynamic>>> getApprovedPOsForProduction() async {
    final unit = Session.I.productionCompany;
    if (unit == null || unit.isEmpty) return [];
    final orders = await _list('Sales Order',
        fields: '["name","customer","grand_total","transaction_date",'
            '"delivery_date","custom_sales_person","custom_production_status",'
            '"custom_production_finish_date","custom_changed_after_approval"]',
        filters:
            '[["custom_company","=","$unit"],["custom_po_status","=","PO Approved - Ready for SAP"]]',
        orderBy: 'transaction_date desc',
        limit: 100);
    if (orders.isEmpty) return orders;

    final codes = orders
        .map((o) => '${o['customer'] ?? ''}')
        .where((c) => c.isNotEmpty)
        .toSet();
    final routes = <String, String>{};
    final names = <String, String>{};
    if (codes.isNotEmpty) {
      final rows = await _list('Customer',
          fields: '["name","customer_name","custom_sales_route","territory"]',
          filters: '[["name","in",${_inList(codes.toList())}]]');
      for (final r in rows) {
        routes['${r['name']}'] = destinationOf(r);
        names['${r['name']}'] = '${r['customer_name'] ?? r['name']}';
      }
    }
    for (final o in orders) {
      final code = '${o['customer'] ?? ''}';
      o['destination'] = routes[code] ?? 'No route set';
      // Falls back to the customer CODE, never a blank: a van loaded against
      // an unnamed row is worse than one against an ugly identifier.
      o['customer_name'] = names[code] ?? code;
    }
    return orders;
  }

  /// Where an order is going, as production should see it.
  ///
  /// The Sales Route, or nothing. Territory used to stand in when no route was
  /// set, from a time when the routes were still being drawn up — but every
  /// customer sits in the single territory "India", so what reached the floor
  /// was "India (no route set)", which reads like a destination, sorts like a
  /// destination, and tells nobody anything. A blank is more use than a
  /// plausible wrong answer: it cannot be mistaken for somewhere to drive.
  ///
  /// New orders cannot be raised without a route at all — see [_requireRoute] —
  /// so this only speaks for orders taken before that rule existed.
  static String destinationOf(Map<String, dynamic> customer) {
    final route = '${customer['custom_sales_route'] ?? ''}'.trim();
    if (route.isNotEmpty && route != 'null') return route;
    return 'No route set';
  }

  /// One order for the production floor, with the customer stripped out the
  /// same way. Returns the raw document plus a `destination`.
  static Future<Map<String, dynamic>> getOrderForProduction(String name) async {
    final o = await getOrder(name);

    // The customer's name is kept as of 19 Aug 2026 — see
    // `getApprovedPOsForProduction` for why it stopped being withheld. The
    // stored `customer_name` on the order is overwritten from the Customer
    // record rather than trusted: it is copied at order time and goes stale
    // the moment a customer is renamed.
    final code = '${o['customer'] ?? ''}';
    var destination = 'No route set';
    var customerName = code;
    if (code.isNotEmpty) {
      try {
        final rows = await _list('Customer',
            fields: '["name","customer_name","custom_sales_route","territory"]',
            filters: '[["name","=","$code"]]',
            limit: 1);
        if (rows.isNotEmpty) {
          destination = destinationOf(rows.first);
          customerName = '${rows.first['customer_name'] ?? code}';
        }
      } catch (_) {}
    }
    o['destination'] = destination;
    o['customer_name'] = customerName;
    o.remove('company_address_display');
    return o;
  }

  /// True once every line on an order has been dispatched.
  ///
  /// Derived, never stored. A separate "complete" flag would be one more thing
  /// that can disagree with the floor — ticked on an order still being made, or
  /// left unticked on one long gone. The order-level status is already rolled
  /// up from the lines, so completion is read from it rather than kept beside
  /// it.
  static bool isOrderComplete(Map<String, dynamic> order) =>
      '${order['custom_production_status'] ?? ''}' == kStageDispatched;

  static Future<List<Map<String, dynamic>>> getCombinedOrders({
    String? customer,
    String? weekStartIso,
  }) {
    final f = <String>[];
    if (customer != null && customer.isNotEmpty) {
      f.add('["customer","=","$customer"]');
    }
    if (weekStartIso != null && weekStartIso.isNotEmpty) {
      f.add('["week_start","=","$weekStartIso"]');
    }
    return _list('Combined Order',
        fields: '["name","customer","customer_name","week_start","week_end",'
            '"status","order_count","total_amount","grouped_by"]',
        filters: f.isEmpty ? null : '[${f.join(',')}]',
        orderBy: 'week_start desc, customer_name asc');
  }

  /// The individual orders inside one combined order.
  ///
  /// Read from the Sales Orders rather than from a list held on the combined
  /// order itself. With membership stored in one place there is nothing to keep
  /// in step, so a combined order can never claim to hold an order that does
  /// not point back at it.
  static Future<List<Map<String, dynamic>>> ordersInCombined(String name) =>
      _list('Sales Order',
          fields: '["name","customer","customer_name","transaction_date",'
              '"grand_total","custom_production_status","custom_sales_person"]',
          filters: '[["custom_combined_order","=","$name"]]',
          orderBy: 'transaction_date asc');

  /// Takes one order back out of its group.
  static Future<void> ungroupOrder(String orderName) async {
    await _put('Sales Order', orderName, {'custom_combined_order': ''});
    await OfflineCache.clear();
  }

  /// Moves one line along its process cycle.
  ///
  /// A line used to be two halves — the portion served off a shelf
  /// reservation, and the portion being made — each moving along its own
  /// sequence. Reservations are gone, so there is one line and one stage.
  static Future<void> setItemStage({
    required String orderName,
    required String itemRowName,
    required String stage,
  }) async {
    final order = await getOrder(orderName);
    final items = ((order['items'] as List?) ?? [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    for (final it in items) {
      if ('${it['name']}' != itemRowName) continue;
      it['custom_production_stage'] = stage;
    }
    await _put('Sales Order', orderName, {
      'items': items,
      // Rolled up to the order so the sales side can see it. Production moves
      // stages per item; the manager's order list and review read the
      // order-level field, and nothing was writing it — so an order in Curing
      // still read "Not Started" to everyone outside the factory.
      'custom_production_status': _rollUpStage(items),
    });
  }

  /// One coarse status for a whole order, from its items' stages.
  ///
  /// `custom_production_status` is a Select and accepts only these four values,
  /// so the per-item stage cannot be copied into it — writing "Curing" there is
  /// rejected outright. That split is right anyway: the floor works in fine
  /// stages, the sales side only needs to know whether an order has started,
  /// is running, is ready, or has gone.
  ///
  /// Ready and Dispatched are decided by the **slowest** line — an order is not
  /// ready to ship because one of its lines is packed. Started is decided by
  /// the fastest: once the floor has touched anything, work is under way.
  @visibleForTesting
  static String rollUpStage(List<Map<String, dynamic>> items) =>
      _rollUpStage(items);

  static String _rollUpStage(List<Map<String, dynamic>> items) {
    if (items.isEmpty) return 'Not Started';

    var allDispatched = true;
    var allPackedOrBetter = true;
    var anyStarted = false;

    // A line used to be split in two — the part covered by a shelf
    // reservation, which only had to be picked and packed, and the part being
    // made, which ran the full cycle — and each half was weighed on its own
    // sequence. Reservations are gone, so no line reports a shelf half any
    // more and every line is weighed once, on its own product's sequence.
    void weigh(List<String> stages, String current) {
      // A stage no longer in the sequence counts as unknown rather than as
      // finished, so revising the stage list cannot make an order look done.
      final rank = current.isEmpty ? 0 : stageIndex(stages, current);
      final effective = rank < 0 ? 0 : rank;

      if (effective > 0) anyStarted = true;
      if (current != kStageDispatched) allDispatched = false;
      // "Packed" is the last stage before Dispatched in every family.
      if (effective < stages.length - 2) allPackedOrBetter = false;
    }

    for (final it in items) {
      weigh(stagesForItem(it), '${it['custom_production_stage'] ?? ''}');
    }

    if (allDispatched) return 'Dispatched';
    if (allPackedOrBetter) return 'Ready';
    return anyStarted ? 'In Production' : 'Not Started';
  }

  /// The production manager moving a delivery date, forwards or back.
  ///
  /// The date the customer originally asked for is captured the first time it
  /// moves, and never overwritten after that. Without it the new date is just
  /// a number — nobody, including the person who moved it, can see that it was
  /// moved or what from.
  ///
  /// Only the delivery date is sent. `custom_order_placed_at` never is: the
  /// moment the order was raised is not production's to move, and it is what
  /// every deadline on the order is measured from.
  static Future<void> setProductionDeliveryDate(
      String orderName, String deliveryDate) async {
    final order = await getOrder(orderName);
    final body = <String, dynamic>{'delivery_date': deliveryDate};

    final original = '${order['custom_original_delivery_date'] ?? ''}';
    if (original.isEmpty || original == 'null') {
      final current = '${order['delivery_date'] ?? ''}';
      if (current.isNotEmpty && current != 'null') {
        body['custom_original_delivery_date'] = current.substring(0, 10);
      }
    }
    await _put('Sales Order', orderName, body);
  }

  /// The routes a rep can put a customer on.
  ///
  /// Sales Route replaces Territory as the routing unit. Routes are named per
  /// rep ("Jaimon D - Adoor"), so a rep is offered their own — but they are
  /// still being created, and a rep with none yet would otherwise be shown an
  /// empty dropdown and be unable to set a route at all. In that case every
  /// active route is offered instead.
  /// Cached, because a route list that will not load blocks the rep from
  /// saving a customer at all — and routes change about once a quarter.
  static Future<List<String>> getSalesRoutes({String? forRep}) async {
    Future<List<Map<String, dynamic>>> fetch(String filters) => _list(
        'Sales Route',
        fields: '["name"]',
        filters: filters,
        orderBy: 'name asc');

    final cached = await OfflineCache.read<List<String>>(
      'routes:${forRep ?? 'all'}',
      () async {
        if (forRep != null && forRep.isNotEmpty) {
          /*
           * A pooled unit shares its routes as well as its customers. Without
           * this a rep covering a colleague's leave can see the customer and
           * then cannot set the round it belongs to — half a cover is worse
           * than none, because the order gets raised against the wrong route.
           */
          final clause = Session.I.unitPeers.contains(forRep)
              ? _visibleFilter(kFieldRouteOwner)
              : '["$kFieldRouteOwner","=","$forRep"]';
          if (clause != null) {
            final mine = await fetch('[["is_active","=",1],$clause]');
            if (mine.isNotEmpty) {
              return mine.map((e) => '${e['name']}').toList();
            }
          }
        }
        final all = await fetch('[["is_active","=",1]]');
        return all.map((e) => '${e['name']}').toList();
      },
      decode: (j) => (j as List? ?? []).map((e) => '$e').toList(),
    );
    return cached.value;
  }

  /// Fills in the packing details an Item was imported without.
  ///
  /// A rep standing in front of the product knows what a roll weighs and how
  /// many belts come off it; waiting for the office to fill that in is a sale
  /// lost. So they can supply it once, here.
  ///
  /// **Only ever sends fields that are currently empty.** A packing figure that
  /// has been set is not editable from the app at all — it decides what the
  /// customer is charged, and a number that can be changed after orders have
  /// been priced against it is a number nobody can reconcile. Corrections go
  /// through Desk.
  ///
  /// Returns the fields that were actually written, so the caller can update
  /// its copy without a re-fetch.
  static Future<Map<String, dynamic>> saveItemPacking({
    required String itemCode,
    double? weightPerRoll,
    int? beltsPerRoll,
    double? packLitres,
  }) async {
    // Re-read rather than trusting the caller's copy: another rep may have
    // filled the same item in since this screen loaded, and their figure wins.
    final r = await Session.I.dio
        .get('${_res('Item')}/${Uri.encodeComponent(itemCode)}');
    final doc = (r.data is Map) ? r.data['data'] : null;
    if (doc is! Map) throw Exception('Could not read $itemCode.');

    double num0(dynamic v) =>
        v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

    final body = <String, dynamic>{};
    if (weightPerRoll != null &&
        weightPerRoll > 0 &&
        num0(doc['custom_weight_per_roll']) <= 0) {
      body['custom_weight_per_roll'] = weightPerRoll;
    }
    if (beltsPerRoll != null &&
        beltsPerRoll > 0 &&
        num0(doc['custom_belts_per_roll']) <= 0) {
      body['custom_belts_per_roll'] = beltsPerRoll;
    }
    if (packLitres != null &&
        packLitres > 0 &&
        num0(doc['custom_pack_litres']) <= 0) {
      body['custom_pack_litres'] = packLitres;
    }
    // What the item ends up with either way: whatever was already on it, plus
    // whatever this rep is adding. Returned even when there is nothing to
    // write, so a row that lost the race still prices off the winner's figures
    // instead of sitting there claiming the item is incomplete.
    final effective = <String, dynamic>{
      for (final f in const [
        'custom_weight_per_roll',
        'custom_belts_per_roll',
        'custom_pack_litres',
      ])
        if (num0(doc[f]) > 0) f: doc[f],
      ...body,
    };

    if (body.isEmpty) return effective;

    try {
      await _put('Item', itemCode, body);
    } on DioException catch (e) {
      // Reps are read-only on Item under stock ERPNext permissions. Said in
      // terms of what to do about it, because the rep cannot grant it and
      // needs to know who can.
      if (e.response?.statusCode == 403) {
        throw Exception('Your login cannot edit the product master. Ask the '
            'office to add the packing details, or to give your role write '
            'access to Item.');
      }
      rethrow;
    }
    // The catalogue is cached for offline use; a stale copy would keep telling
    // the rep the item is incomplete.
    await OfflineCache.clear();
    return effective;
  }

  /// Removes a visit the rep logged by mistake.
  ///
  /// Deleted rather than cancelled: a visit recorded against the wrong shop is
  /// not a thing that happened, and leaving it as a cancelled row would still
  /// count it on the day map and in the visit totals.
  static Future<void> deleteVisit(String name) async {
    final r = await Session.I.dio
        .delete('${_res('Sales Visit')}/${Uri.encodeComponent(name)}');
    if (r.statusCode != 200 && r.statusCode != 202) {
      throw Exception(_frappeError(r));
    }
    await OfflineCache.clear();
  }

  /// What stands in the way of deleting this lead.
  ///
  /// Asked BEFORE the delete, not inferred from the failure afterwards. Frappe
  /// answers a blocked delete with a LinkExistsError naming an internal
  /// doctype — true, and useless to a rep standing in a shop. Reading the
  /// links first is what lets the app say "2 visits are logged against this
  /// lead" instead.
  ///
  /// A failure to read them is reported as a blocker of its own rather than as
  /// "nothing in the way": not knowing what points at a record is not the same
  /// as nothing pointing at it, and only one of those is safe to act on.
  static Future<LeadDeleteBlockers> getLeadDeleteBlockers(
      Map<String, dynamic> lead) async {
    final name = '${lead['name'] ?? ''}';
    final owner = '${lead[kFieldLeadOwner] ?? ''}';
    final me = Session.I.salesPerson ?? '';

    // Ownership first: it decides whether the rest is even worth asking.
    if (owner.isNotEmpty && owner != me) {
      return LeadDeleteBlockers(ownedBy: owner);
    }

    final converted = '${lead['customer'] ?? ''}';

    final visits = await _list('Sales Visit',
        fields: '["name"]', filters: '[["custom_lead","=","$name"]]', limit: 50);
    final orders = await _list('Lead Order',
        fields: '["name"]', filters: '[["lead","=","$name"]]', limit: 50);

    return LeadDeleteBlockers(
      visits: visits.length,
      leadOrders: orders.map((e) => '${e['name']}').toList(),
      customer: converted.isEmpty || converted == 'null' ? null : converted,
    );
  }

  /// Removes a lead the rep captured by mistake.
  ///
  /// Deleted rather than closed: a shop keyed twice, or captured at the wrong
  /// door, is not a lead that went cold — it is a row that should never have
  /// existed, and leaving it as "Do Not Contact" would keep it in every count
  /// of what the territory holds.
  ///
  /// The caller is expected to have checked [getLeadDeleteBlockers] first. This
  /// re-reads the lead and checks again anyway, because there are no Server
  /// Scripts here and the gap between asking and acting is where a colleague's
  /// visit lands.
  static Future<void> deleteLead(String name) async {
    final fresh = await getLeadDoc(name);
    final blockers = await getLeadDeleteBlockers(fresh);
    final refusal = leadDeleteRefusal(blockers);
    if (refusal != null) throw Exception(refusal);

    final r = await Session.I.dio
        .delete('${_res('Lead')}/${Uri.encodeComponent(name)}');
    if (r.statusCode != 200 && r.statusCode != 202) {
      throw Exception(_frappeError(r));
    }
    await OfflineCache.clear();
  }

  /// The rep's own routes, with enough detail to manage them.
  static Future<List<Map<String, dynamic>>> getMySalesRoutes() {
    final rep = Session.I.salesPerson;
    if (rep == null || rep.isEmpty) return Future.value([]);
    return _list('Sales Route',
        fields: '["name","route_name","sales_person","is_active","visit_day"]',
        filters: '[["sales_person","=","$rep"]]',
        orderBy: 'route_name asc');
  }

  /// Adds a route for this rep.
  ///
  /// Named `Rep - Area`, which is the convention every existing route already
  /// follows and what makes a route list readable when a manager sees several
  /// reps' routes at once. The rep supplies the area only; prefixing their own
  /// name is not their job to remember.
  static Future<String> createSalesRoute(String area) async {
    final rep = Session.I.salesPerson;
    if (rep == null || rep.isEmpty) {
      throw Exception('No sales person linked to this login.');
    }
    final trimmed = area.trim();
    if (trimmed.isEmpty) throw Exception('Enter an area name.');

    final name = trimmed.startsWith('$rep -') ? trimmed : '$rep - $trimmed';
    final r = await Session.I.dio.post(_res('Sales Route'), data: {
      'route_name': name,
      'sales_person': rep,
      'is_active': 1,
    });
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
    // The route list is cached for offline use, so it has to be dropped or the
    // rep adds a route and cannot see it.
    await OfflineCache.clear();
    return '${r.data['data']['name']}';
  }

  /// Removes a route.
  ///
  /// Frappe refuses this while any customer, lead or site still points at it,
  /// which is the behaviour we want — deleting a route out from under a
  /// customer would leave production with nothing to plan a delivery by. The
  /// refusal surfaces as a readable message rather than being pre-empted here,
  /// because the app cannot see every doctype that might link to it.
  static Future<void> deleteSalesRoute(String name) async {
    final r = await Session.I.dio
        .delete('${_res('Sales Route')}/${Uri.encodeComponent(name)}');
    if (r.statusCode != 200 && r.statusCode != 202) {
      throw Exception(_frappeError(r));
    }
    await OfflineCache.clear();
  }

  /// Updates the details a rep can correct in the field.
  ///
  /// The sales route is the important one: it is the only thing production is
  /// given to plan a delivery by. An order taken against a customer with no
  /// route reaches the floor as "No route set".
  static Future<void> updateCustomer({
    required String name,
    String? salesRoute,
    String? customerGroup,
    String? phone,
    String? address,
    String? gstin,
    String? state,
  }) async {
    final body = <String, dynamic>{};
    if (salesRoute != null && salesRoute.isNotEmpty) {
      body['custom_sales_route'] = salesRoute;
    }
    if (customerGroup != null && customerGroup.isNotEmpty) {
      body['customer_group'] = customerGroup;
    }
    if (phone != null) body['custom_phone'] = phone.trim();
    if (address != null) body['custom_address'] = address.trim();
    if (gstin != null) body['custom_gstin'] = gstin.trim().toUpperCase();
    if (state != null) body['custom_state'] = state.trim();
    if (body.isEmpty) return;
    await _put('Customer', name, body);
  }

  /// The production manager confirming they have seen a post-approval change.
  static Future<void> acknowledgeOrderChange(String orderName) =>
      _put('Sales Order', orderName, {'custom_changed_after_approval': 0});

  static Future<void> setProductionStatus({
    required String orderName,
    required String status,
    String? finishDate,
  }) async {
    await _put('Sales Order', orderName, {
      'custom_production_status': status,
      'custom_production_finish_date': finishDate,
    });
  }

  static Future<String> createRetreadProforma({
    required String customer,
    String? customerName,
    required List<Map<String, dynamic>> rates,
    String? notes,
  }) async {
    final body = <String, dynamic>{
      'customer': customer,
      if (customerName != null && customerName.isNotEmpty)
        'customer_name': customerName,
      'sales_rep': Session.I.salesPerson,
      'proforma_date': today(),
      'status': 'Shared',
      'rates': rates,
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
    };
    final r = await Session.I.dio.post(_res('Retread Proforma'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<List<Map<String, dynamic>>> getMyRetreadProformas() {
    final me = Session.I.salesPerson;
    if (me == null) return Future.value([]);
    return _list('Retread Proforma',
        fields: '["name","customer","customer_name","proforma_date","status"]',
        filters: '[["sales_rep","=","$me"]]',
        orderBy: 'proforma_date desc');
  }

  static Future<Map<String, dynamic>> getRetreadProforma(String name) async {
    final r = await Session.I.dio.get('${_res('Retread Proforma')}/$name');
    return (r.data['data'] as Map).cast<String, dynamic>();
  }

  static Future<void> supersedeProforma(String name) =>
      _put('Retread Proforma', name, {'status': 'Superseded'});

  static Future<List<Map<String, dynamic>>> getMyReadyTyres() {
    final me = Session.I.salesPerson;
    if (me == null) return Future.value([]);
    return _list('Retread Tyre',
        fields:
        '["name","customer","customer_name","tyre_size","tyre_brand","retread_type","tread_pattern","tyre_number","proforma"]',
        filters: '[["sales_rep","=","$me"],["status","=","Ready"]]',
        orderBy: 'customer asc');
  }

  static Future<void> placeRetreadOrder(
      List<String> tyreNames, Map<String, double> rateByName) async {
    final orderRef = 'RO-${DateTime.now().millisecondsSinceEpoch}';
    final orderDate = today();
    for (final n in tyreNames) {
      await _put('Retread Tyre', n, {
        'status': 'Ordered',
        'rate': rateByName[n] ?? 0,
        'order_ref': orderRef,
        'order_date': orderDate,
      });
    }
  }

  static Future<List<Map<String, dynamic>>> getMyRetreadOrderedTyres() {
    final me = Session.I.salesPerson;
    if (me == null) return Future.value([]);
    return _list('Retread Tyre',
        fields:
        '["name","customer","customer_name","tyre_size","retread_type","tyre_number","rate","status","order_ref","order_date","delivery_date","vehicle"]',
        filters:
        '[["sales_rep","=","$me"],["status","in",["Ordered","Scheduled","Delivered","Invoiced"]]]',
        orderBy: 'order_date desc');
  }

  static String _frappeError(Response r) {
    try {
      final d = r.data;
      if (d is Map &&
          d['exception'] != null &&
          d['_server_messages'] == null) {
        var ex = d['exception'].toString();
        if (ex.contains(':')) ex = ex.split(':').last.trim();
        return ex.length > 160 ? ex.substring(0, 160) : ex;
      }
      if (d is Map && d['_server_messages'] != null) {
        final msgs = jsonDecode(d['_server_messages']) as List;
        return msgs.map((m) => jsonDecode(m)['message']).join('\n');
      }
    } catch (_) {}
    return 'HTTP ${r.statusCode}';
  }
}
