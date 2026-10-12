import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/app_bus.dart';
import 'package:manna_field_sales/core/attendance_rules.dart';
import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/server_clock.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/screens/attendance/attendance_calendar_screen.dart';
import 'package:manna_field_sales/screens/attendance/regularization_approvals_screen.dart';
import 'package:manna_field_sales/screens/auth/login_screen.dart';
import 'package:manna_field_sales/screens/customers/customer_list_screen.dart';
import 'package:manna_field_sales/screens/customers/routes_screen.dart';
import 'package:manna_field_sales/screens/history/my_collections_screen.dart';
import 'package:manna_field_sales/screens/history/my_orders_screen.dart';
import 'package:manna_field_sales/screens/history/my_visits_screen.dart';
import 'package:manna_field_sales/screens/leads/leads_screen.dart';
import 'package:manna_field_sales/screens/leave/hr_add_leave_screen.dart';
import 'package:manna_field_sales/screens/leave/leave_approvals_screen.dart';
import 'package:manna_field_sales/screens/leave/leave_screen.dart';
import 'package:manna_field_sales/screens/manager/gm_approvals_screen.dart';
import 'package:manna_field_sales/screens/home/update_sheet.dart';
import 'package:manna_field_sales/screens/manager/manager_dashboard_screen.dart';
import 'package:manna_field_sales/screens/map/day_map_screen.dart';
import 'package:manna_field_sales/screens/map/map_screen.dart';
import 'package:manna_field_sales/screens/orders/min_stock_screen.dart';
import 'package:manna_field_sales/screens/production/production_dashboard_screen.dart';
import 'package:manna_field_sales/screens/retread/retread_orders_screen.dart';
import 'package:manna_field_sales/screens/retread/retread_proforma_list_screen.dart';
import 'package:manna_field_sales/screens/retread/retread_ready_tyres_screen.dart';
import 'package:manna_field_sales/screens/trips/expense_summary_screen.dart';
import 'package:manna_field_sales/screens/trips/hr_trip_expenses_screen.dart';
import 'package:manna_field_sales/screens/trips/trip_rates_screen.dart';
import 'package:manna_field_sales/screens/trips/trips_screen.dart';
import 'package:manna_field_sales/screens/orders/unsent_orders_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/screens/conditions/my_conditions_screen.dart';
import 'package:manna_field_sales/services/update_service.dart';
import 'package:manna_field_sales/services/pending_orders.dart';
import 'package:manna_field_sales/services/location_service.dart';
import 'package:manna_field_sales/services/trip_tracker.dart';
import 'package:manna_field_sales/widgets/trip_recording_indicator.dart';

class HomeDashboard extends StatefulWidget {
  const HomeDashboard({super.key});
  @override
  State<HomeDashboard> createState() => _HomeDashboardState();
}

class _HomeDashboardState extends State<HomeDashboard>
    with WidgetsBindingObserver {
  late Future<List<int>> _counts;
  late Future<Map<String, dynamic>?> _activeTrip;
  // Held in state, not created in build(). A future made inside build() is a
  // new request on every setState, and its card dropped back to a loading
  // placeholder each time, which is part of what made this screen flicker.
  late Future<List<dynamic>> _target;
  Map<String, dynamic>? _att;

  /// True only until today's attendance has been read once. A later refresh
  /// keeps the card and its button as they are and swaps the data in when it
  /// arrives. Hiding them on every refresh is what made Punch Out blink.
  bool _attLoading = true;
  bool _attLoaded = false;
  bool _attInFlight = false;
  bool _attBusy = false;

  /// Resumes, AppBus bumps and pull-to-refresh all ask for a refresh. Those
  /// asks are merged so the screen reloads at most once per [_refreshGap],
  /// however many arrive. A refresh that writes (flushing route points)
  /// bumps AppBus, and nothing else stops that from triggering another.
  Timer? _refreshTimer;
  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _refreshGap = Duration(seconds: 5);

  /// Orders typed with no signal and not yet sent. The tile only appears when
  /// there are some — a permanent "Unsent Orders (0)" would train reps to
  /// ignore the one thing on this screen that means work is outstanding.
  int _unsent = 0;

  void _requestRefresh() {
    if (!mounted || (_refreshTimer?.isActive ?? false)) return;
    final wait = _refreshGap - DateTime.now().difference(_lastRefresh);
    if (wait <= Duration.zero) {
      _refreshAll();
    } else {
      _refreshTimer = Timer(wait, _refreshAll);
    }
  }

  void _refreshAll() {
    if (!mounted) return;
    _lastRefresh = DateTime.now();
    setState(() {
      _counts = _loadCounts();
      _activeTrip = _loadActiveTrip();
      _target = _loadTarget();
    });
    _loadAtt();
    _loadUnsent();
    // Route points recorded without signal are pushed whenever the app is in
    // front of somebody, which in practice is the first moment after a rep
    // gets back into coverage. Waiting for the next five-minute fix would
    // leave a morning's driving sitting on the phone until lunchtime.
    unawaited(TripTracker.I.flushPending());
    // Recording lives in memory, so an app Android killed comes back not
    // recording even though the trip is still Active. Picked up here rather
    // than waiting for a rep to notice the indicator in the top bar.
    unawaited(TripTracker.I.resumeIfNeeded());
  }

  Future<void> _loadUnsent() async {
    final n = await PendingOrders.count();
    if (mounted && n != _unsent) setState(() => _unsent = n);
  }

  /// Offered once per launch. A rep who says "Later" is not asked again until
  /// they next open the app — the same prompt on every home-screen rebuild is
  /// how a convenience turns into something people learn to dismiss blind.
  static bool _updateOffered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppBus.I.addListener(_requestRefresh);
    _lastRefresh = DateTime.now();
    _counts = _loadCounts();
    _activeTrip = _loadActiveTrip();
    _target = _loadTarget();
    _loadAtt();
    _loadUnsent();
    _offerUpdate();
  }

  /// Ask GitHub whether there is a newer build, and offer it if so.
  ///
  /// Deliberately not awaited by anything: the home screen renders while this
  /// runs, and every failure is silent — see `services/update_service.dart`.
  Future<void> _offerUpdate() async {
    if (_updateOffered) return;
    _updateOffered = true;
    final update = await UpdateService.check();
    if (update == null || !mounted) return;
    await showUpdateSheet(context, update);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppBus.I.removeListener(_requestRefresh);
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _requestRefresh();
  }

  Future<void> _loadAtt() async {
    final rep = Session.I.salesPerson;
    if (rep == null) {
      if (mounted) setState(() => _attLoading = false);
      return;
    }
    if (_attInFlight) return;
    _attInFlight = true;
    if (!_attLoaded && mounted) setState(() => _attLoading = true);
    try {
      final list = await Api.getTodayAttendance(rep);
      if (mounted) {
        setState(() {
          _att = list.isNotEmpty ? list.first : null;
          _attLoaded = true;
        });
      }
    } catch (_) {
    } finally {
      _attInFlight = false;
      if (mounted) setState(() => _attLoading = false);
    }
  }

  Future<List<dynamic>> _loadTarget() => Future.wait([
        Api.getMyTarget(),
        Api.myCurrency(),
        Api.getMonthSales(Session.I.salesPerson ?? '__none__'),
      ]);

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  /// A location refusal the rep can only undo in Android's settings. Once
  /// "Don't allow" has been chosen twice, Android stops showing the dialog, so
  /// the message points at the one place that still works.
  void _snackError(Object e) {
    if (!mounted) return;
    final msg = humanError(e);
    if (!msg.toLowerCase().contains('location permission')) return _snack(msg);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Location is not allowed for this app. '
          'Allow it in Settings → Permissions → Location.'),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(
          label: 'Settings', onPressed: TripTracker.I.openLocationSettings),
    ));
  }

  Future<void> _punchIn() async {
    final rep = Session.I.salesPerson;
    if (rep == null) return _snack('No rep linked to this login.');
    setState(() => _attBusy = true);
    _snack('Getting GPS…');
    try {
      final pos = await getCurrentLocation();
      await Api.punchIn(salesPerson: rep, lat: pos.latitude, lng: pos.longitude);
      _snack('Punched in ✓');
      await _loadAtt();
    } on AttendanceWindowError catch (e) {
      await _outsidePunchHours(e);
    } catch (e) {
      _snackError(e);
    } finally {
      if (mounted) setState(() => _attBusy = false);
    }
  }

  Future<void> _punchOut() async {
    if (_att == null) return;
    final again = (_att?['punch_out_time']) != null;
    setState(() => _attBusy = true);
    _snack('Getting GPS…');
    try {
      final pos = await getCurrentLocation();
      final hours = await Api.punchOut(
        name: _att!['name'],
        punchInTime: (_att!['punch_in_time'] ?? '').toString(),
        lat: pos.latitude,
        lng: pos.longitude,
      );
      _snack(again
          ? 'Punch-out updated ✓  ${hours.toStringAsFixed(2)} h'
          : 'Punched out ✓  ${hours.toStringAsFixed(2)} h');
      await _loadAtt();
    } on AttendanceWindowError catch (e) {
      await _outsidePunchHours(e);
    } catch (e) {
      _snackError(e);
    } finally {
      if (mounted) setState(() => _attBusy = false);
    }
  }

  /// The punch was refused for the hour it is, not because anything broke —
  /// so say which window closed and, where regularization is the way out,
  /// hand the rep straight to it.
  Future<void> _outsidePunchHours(AttendanceWindowError e) async {
    if (!mounted) return;
    final day = e.regularizeDate;
    final regularize = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Outside punch hours'),
        content: Text(e.message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Close')),
          if (day != null)
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Regularize')),
        ],
      ),
    );
    if (regularize == true && mounted) {
      _go(AttendanceCalendarScreen(regularizeDate: day));
    }
  }

  Future<Map<String, dynamic>?> _loadActiveTrip() async {
    if (Session.I.salesPerson == null) return null;
    try {
      return await Api.getActiveTrip();
    } catch (_) {
      return null;
    }
  }

  Widget _attendanceCard() {
    final status = (_att?['status'] ?? '').toString();
    final isIn = status == 'Punched In';
    final isOut = status == 'Punched Out';
    String line;
    if (_attLoading) {
      line = 'Loading attendance…';
    } else if (isIn) {
      line = 'Punched in at ${(_att?['punch_in_time'] ?? '').toString().padRight(16).substring(11, 16)}';
    } else if (isOut) {
      line =
      'Done for today · ${(_att?['working_hours'] ?? 0)} h · out at ${hhmm(_att?['punch_out_time'])}';
    } else {
      line = 'Not punched in yet';
    }
    // A rep who punched out early, then kept working, punches out again — the
    // later stamp becomes the official one. Only offered while the window is
    // still open; after that the day needs regularizing.
    final canRepunch = isOut &&
        !_attLoading &&
        minuteOfDay(ServerClock.I.now()) <= kPunchOutUntilMinute;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Icon(isIn ? Icons.timer : (isOut ? Icons.check_circle : Icons.how_to_reg),
              size: 36,
              color: isIn
                  ? Colors.orange
                  : (isOut ? Colors.green : const Color(0xFFF46A21))),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Attendance',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 2),
                Text(line, style: const TextStyle(color: Colors.black54)),
              ],
            ),
          ),
          if (!_attLoading && !isOut)
            FilledButton.icon(
              onPressed: _attBusy
                  ? null
                  : (isIn ? _punchOut : _punchIn),
              icon: Icon(isIn ? Icons.logout : Icons.login, size: 18),
              label: Text(isIn ? 'Punch Out' : 'Punch In'),
              style: FilledButton.styleFrom(
                  backgroundColor: isIn ? Colors.orange : const Color(0xFFF46A21)),
            )
          else if (canRepunch)
            OutlinedButton.icon(
              onPressed: _attBusy ? null : _punchOut,
              icon: const Icon(Icons.update, size: 18),
              label: const Text('Punch Out Again'),
            ),
        ]),
      ),
    );
  }

  Widget _myTargetCard() {
    return FutureBuilder<List<dynamic>>(
      future: _target,
      builder: (context, snap) {
        if (snap.hasError) {
          return const Card(
            child: ListTile(
              leading: Icon(Icons.flag, color: Colors.grey),
              title: Text('My Sales Target'),
              subtitle: Text('Could not load the target. Pull down to retry.'),
            ),
          );
        }
        if (!snap.hasData) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Row(children: [
                Icon(Icons.flag, color: Color(0xFFF46A21)),
                SizedBox(width: 12),
                Text('Loading target…'),
              ]),
            ),
          );
        }
        final target = snap.data![0] as Map<String, dynamic>?;
        final cur = snap.data![1] as String;
        final actual = snap.data![2] as double;
        if (target == null) {
          return const Card(
            child: ListTile(
              leading: Icon(Icons.flag, color: Colors.grey),
              title: Text('My Sales Target'),
              subtitle: Text('No target set for this month yet'),
            ),
          );
        }
        final amt = ((target['target_amount'] ?? 0) as num).toDouble();
        final unit = (target['target_unit'] ?? 'Currency') as String;
        final isCur = unit == 'Currency';
        final pct =
        (isCur && amt > 0) ? (actual / amt).clamp(0.0, 1.0) : 0.0;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.flag, color: Color(0xFFF46A21)),
                    const SizedBox(width: 8),
                    const Text('My Sales Target',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text(
                        isCur
                            ? '$cur ${amt.toStringAsFixed(0)}'
                            : '${amt.toStringAsFixed(0)} t',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                  ]),
                  const SizedBox(height: 10),
                  if (isCur) ...[
                    Text(
                        'Sales this month (approved POs): $cur ${actual.toStringAsFixed(0)}',
                        style: const TextStyle(
                            fontSize: 13, color: Colors.black54)),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                          value: pct,
                          minHeight: 10,
                          backgroundColor: const Color(0xFFE0E0E0)),
                    ),
                    const SizedBox(height: 4),
                    Text('${(pct * 100).toStringAsFixed(0)}% of target',
                        style: const TextStyle(fontSize: 12)),
                  ] else
                    const Text(
                        'Tonnage achieved is tracked from dispatch (coming via SAP).',
                        style:
                        TextStyle(fontSize: 12, color: Colors.deepOrange)),
                ]),
          ),
        );
      },
    );
  }

  Future<List<int>> _loadCounts() async {
    final t = today();
    final me = Session.I.salesPerson ?? '__none__';
    return Future.wait([
      Api.getCount('Sales Visit',
          '[["sales_person","=","$me"],["visit_date","=","$t"]]'),
      Api.getCount('Sales Order',
          '[["custom_sales_person","=","$me"],["transaction_date","=","$t"]]'),
      Api.getCount('Collection Entry',
          '[["sales_person","=","$me"],["collection_date","=","$t"]]'),
    ]);
  }

  Future<void> _logout() async {
    // Api.logout clears the stored token, cookie and password.
    await Api.logout();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
              (r) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRep = Session.I.salesPerson != null;
    final tiles = <_Tile>[
      // A Manager tile sat here too until 11 Oct 2026. The black bar at the
      // top is the one way in; two was clutter.
      if (Session.I.isGM)
        _Tile('GM Approvals', Icons.gavel,
                () => _go(const GMApprovalsScreen())),
      if (isRep || Session.I.isManager || Session.I.isGM || Session.I.isHR)
        _Tile('Day Map', Icons.pin_drop, () => _go(const DayMapScreen())),
      // Sits above everything else a rep does: an order nobody has received is
      // the most urgent thing on this screen.
      if (isRep && _unsent > 0)
        _Tile('Unsent Orders ($_unsent)', Icons.cloud_off,
            () => _go(const UnsentOrdersScreen())),
      if (isRep) ...[
        _Tile('Customers', Icons.store, () => _go(const CustomerListScreen())),
        // Reachable from the route filters too, but a rep setting up their
        // patch for the first time is not filtering anything yet.
        _Tile('My Routes', Icons.alt_route, () => _go(const RoutesScreen())),
        _Tile('Leads', Icons.emoji_objects, () => _go(const LeadsScreen())),
        _Tile('My Visits', Icons.location_on, () => _go(const MyVisitsScreen())),
        _Tile('My Orders', Icons.shopping_cart,
                () => _go(Session.I.company == kUnitRetreads
                ? const RetreadOrdersScreen()
                : const MyOrdersScreen())),
        // Beside Collections on purpose: both are money the rep owes somebody
        // an answer about, and a condition is usually discharged by collecting.
        _Tile('My Conditions', Icons.rule,
                () => _go(const MyConditionsScreen())),
        _Tile('Collections', Icons.payments,
                () => _go(const MyCollectionsScreen())),
        _Tile('Map', Icons.map, () => _go(const MapScreen())),
        _Tile('Trips', Icons.directions_car, () => _go(const TripsScreen())),
        // Separate from Trips: that screen is one day's work, this is the
        // month's claim, and a rep looking for what they are owed was
        // otherwise adding trips up on paper.
        _Tile('My Expenses', Icons.receipt_long,
                () => _go(const ExpenseSummaryScreen())),
        _Tile('Leave', Icons.beach_access, () => _go(const LeaveScreen())),
      ],
      // Minimum stock is how Treads sells; Retreads and UAE run a different
      // process. The tile is absent for them rather than opening an empty list
      // they would have to ask about. Managers get it too, so the Treads
      // manager can see what their team is being told to clear.
      if ((isRep || Session.I.isManager) && Session.I.isTreadsUnit)
        _Tile('Min Stock', Icons.inventory_2,
                () => _go(const MinimumStockScreen())),
      if (isRep && Session.I.company == kUnitRetreads)
        _Tile('Retread Rates', Icons.request_quote,
                () => _go(const RetreadProformaListScreen())),
      if (isRep && Session.I.company == kUnitRetreads)
        _Tile('Ready Tyres', Icons.checklist,
                () => _go(const RetreadReadyTyresScreen())),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(Session.I.salesPersonLabel == null
            ? 'Manna Field Sales'
            : 'Manna · ${Session.I.salesPersonLabel}'),
        actions: [
          if (isRep)
            FutureBuilder<Map<String, dynamic>?>(
              future: _activeTrip,
              builder: (_, snap) => TripRecordingIndicator(trip: snap.data),
            ),
          IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Logout',
              onPressed: _logout),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          _refreshTimer?.cancel();
          _refreshAll();
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (Session.I.isManager)
              Card(
                color: const Color(0xFF3F3F3F),
                child: ListTile(
                  leading:
                  const Icon(Icons.verified_user, color: Colors.white),
                  title: Text('Manager · ${Session.I.managedTeam} Team',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: const Text('Team orders & approvals',
                      style: TextStyle(color: Colors.white70)),
                  trailing:
                  const Icon(Icons.chevron_right, color: Colors.white),
                  onTap: () => _go(const ManagerDashboardScreen()),
                ),
              ),
            if (Session.I.isManager) const SizedBox(height: 16),
            if (Session.I.isGM)
              Card(
                color: const Color(0xFFF46A21),
                child: ListTile(
                  leading: const Icon(Icons.gavel, color: Colors.white),
                  title: const Text('General Manager',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: const Text('Final approval for over-limit POs',
                      style: TextStyle(color: Colors.white70)),
                  trailing:
                  const Icon(Icons.chevron_right, color: Colors.white),
                  onTap: () => _go(const GMApprovalsScreen()),
                ),
              ),
            if (Session.I.isGM) const SizedBox(height: 16),
            if (Session.I.isProductionManager)
              Card(
                color: const Color(0xFF7C3AED),
                child: ListTile(
                  leading: const Icon(Icons.factory, color: Colors.white),
                  title: const Text('Production Manager',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: Text('Approved POs · ${Session.I.productionCompany ?? ''}',
                      style: const TextStyle(color: Colors.white70)),
                  trailing: const Icon(Icons.chevron_right, color: Colors.white),
                  onTap: () => _go(const ProductionDashboardScreen()),
                ),
              ),
            if (Session.I.isProductionManager) const SizedBox(height: 16),
            if (Session.I.isHR)
              Card(
                color: const Color(0xFF0F766E),
                child: ListTile(
                  leading: const Icon(Icons.badge, color: Colors.white),
                  title: const Text('HR Manager',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: const Text(
                      'Approve managers\' attendance regularizations',
                      style: TextStyle(color: Colors.white70)),
                  trailing:
                  const Icon(Icons.chevron_right, color: Colors.white),
                  onTap: () => _go(
                      const RegularizationApprovalsScreen(forHR: true)),
                ),
              ),
            if (Session.I.isHR)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.beach_access, color: Color(0xFFF46A21)),
                  title: const Text('Leave Approvals'),
                  subtitle: const Text('Approve managers\' leave requests'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _go(const LeaveApprovalsScreen(forHR: true)),
                ),
              ),
            if (Session.I.isHR)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.event_note, color: Color(0xFFF46A21)),
                  title: const Text('Add Leave (backdated)'),
                  subtitle: const Text('Mark leave for any date on request'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _go(const HRAddLeaveScreen()),
                ),
              ),
            if (Session.I.isHR) const SizedBox(height: 16),
            if (Session.I.isHR)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.payments_outlined,
                      color: Color(0xFFF46A21)),
                  title: const Text('Trip Rates'),
                  subtitle: const Text('Set ₹/km reimbursement rates'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _go(const TripRatesScreen()),
                ),
              ),
            if (Session.I.isHR)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.receipt_long,
                      color: Color(0xFFF46A21)),
                  title: const Text('Trip Expenses'),
                  subtitle:
                  const Text('All trips, costs & tagged members'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _go(const HRTripExpensesScreen()),
                ),
              ),
            if (Session.I.isHR) const SizedBox(height: 16),
            if (isRep) _attendanceCard(),
            if (isRep) const SizedBox(height: 12),
            if (isRep)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.calendar_month,
                      color: Color(0xFFF46A21)),
                  title: const Text('Attendance Calendar'),
                  subtitle:
                  const Text('View your month & request regularization'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _go(const AttendanceCalendarScreen()),
                ),
              ),
            if (isRep) const SizedBox(height: 16),
            if (isRep)
              Card(
                color: const Color(0xFF3F3F3F),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: FutureBuilder<List<int>>(
                    future: _counts,
                    builder: (context, snap) {
                      final v = snap.data;
                      Widget metric(String label, String value) => Column(
                        children: [
                          Text(value,
                              style: const TextStyle(
                                  color: Color(0xFFF7943E),
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold)),
                          Text(label,
                              style:
                              const TextStyle(color: Colors.white70)),
                        ],
                      );
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("Today",
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 14)),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              metric('Visits', v == null ? '—' : '${v[0]}'),
                              metric('Orders', v == null ? '—' : '${v[1]}'),
                              metric('Collections',
                                  v == null ? '—' : '${v[2]}'),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            if (isRep) const SizedBox(height: 16),
            if (isRep) _myTargetCard(),
            const SizedBox(height: 16),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              children: tiles
                  .map((t) => InkWell(
                onTap: t.onTap,
                child: Card(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(t.icon, size: 40,
                          color: const Color(0xFFF46A21)),
                      const SizedBox(height: 8),
                      Text(t.label,
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  void _go(Widget screen) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => screen))
        .then((_) {
      setState(() { _counts = _loadCounts(); });
      // An order taken — or sent — while that screen was open changes whether
      // the Unsent tile belongs here at all.
      _loadUnsent();
    });
  }
}

class _Tile {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  _Tile(this.label, this.icon, this.onTap);
}

// -------------------- CUSTOMERS --------------------
