// Everything waiting on the manager that is not an order.
//
// Three queues, one tab each: attendance corrections, locations a rep captured
// (customers, leads and their sites), and leave. Orders are decided on their
// own review screen and nowhere else.
//
// The dashboard has the first two (Location Checks, Attendance Corrections).
// Leave is the phone's alone: reps apply on the phone with the manager as the
// approver, and the dashboard leaves those requests to this screen.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:manna_field_sales/core/attendance_rules.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/leave_balance.dart';
import 'package:manna_field_sales/core/manager_scope.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/manager/manager_ui.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/sync_all_button.dart';

enum ApprovalQueue { locations, attendance, leave }

/// The queues this manager works, in the order they are shown.
///
/// Locations came first until 11 Oct 2026. A place waiting a day to be
/// verified costs nobody anything; a rep's attendance does, so it leads.
List<ApprovalQueue> approvalQueuesFor(String? team) {
  bool can(ManagerScreen s) =>
      canOpenAs(isGM: Session.I.isGM, managedTeam: team, screen: s);
  return [
    if (can(ManagerScreen.regularizations)) ApprovalQueue.attendance,
    if (can(ManagerScreen.locations)) ApprovalQueue.locations,
    ApprovalQueue.leave,
  ];
}

const Map<ApprovalQueue, String> approvalQueueLabel = {
  ApprovalQueue.locations: 'Locations',
  ApprovalQueue.attendance: 'Attendance',
  ApprovalQueue.leave: 'Leave',
};

/// One location waiting to be verified.
class _Place {
  final String kind; // customer | lead | site
  final String name;
  final String title;
  final String rep;
  final double? lat;
  final double? lng;
  final String photo;
  const _Place(this.kind, this.name, this.title, this.rep, this.lat, this.lng,
      this.photo);

  _Place withPhoto(String p) =>
      _Place(kind, name, title, rep, lat, lng, p);

  bool get hasCoords => lat != null && lng != null && (lat != 0 || lng != 0);
}

double? _coord(dynamic v) {
  final s = textOf(v);
  return s.isEmpty ? null : double.tryParse(s);
}

/// How many are waiting in each queue — for the home tab.
Future<Map<ApprovalQueue, int>> countApprovals(List<ApprovalQueue> queues) async {
  final out = <ApprovalQueue, int>{};
  await Future.wait(queues.map((q) async {
    try {
      out[q] = switch (q) {
        ApprovalQueue.locations => (await _loadPlaces()).length,
        ApprovalQueue.attendance =>
          (await Api.getPendingRegularizationsForManager()).length,
        ApprovalQueue.leave => (await Api.getPendingLeaveForManager()).length,
      };
    } catch (_) {
      // A count that cannot be read is left off, not shown as zero.
    }
  }));
  return out;
}

Future<List<_Place>> _loadPlaces() async {
  final r = await Future.wait([
    Api.getPendingLocationVerifications(),
    Api.getPendingLeadLocationVerifications(),
    Api.getPendingSiteVerifications(),
  ]);
  final places = [
    for (final c in r[0])
      _Place('customer', '${c['name']}', textOf(c['customer_name']),
          textOf(c['custom_location_captured_by']),
          _coord(c['custom_latitude']), _coord(c['custom_longitude']),
          textOf(c['custom_banner_photo'])),
    for (final l in r[1])
      _Place('lead', '${l['name']}', textOf(l['lead_name']),
          textOf(l['custom_location_captured_by']),
          _coord(l['custom_latitude']), _coord(l['custom_longitude']),
          textOf(l['custom_banner_photo'])),
    for (final s in r[2])
      _Place(
          'site',
          '${s['name']}',
          [textOf(s['site_name']), textOf(s['customer']).isNotEmpty
                  ? textOf(s['customer'])
                  : textOf(s['lead'])]
              .where((x) => x.isNotEmpty)
              .join(' · '),
          textOf(s['captured_by']),
          _coord(s['latitude']),
          _coord(s['longitude']),
          textOf(s['banner_photo'])),
  ];
  return _withAttachedPhotos(places);
}

const Map<String, (String, String)> _photoField = {
  'customer': ('Customer', 'custom_banner_photo'),
  'lead': ('Lead', 'custom_banner_photo'),
  'site': ('Customer Site', 'banner_photo'),
};

/// Fills in a photo the record's own field does not hold but which is attached
/// to it — every site captured before 11 Oct 2026 (see `Api.uploadPhoto`).
/// A lookup that fails leaves the card without a photo rather than the queue
/// without its cards.
Future<List<_Place>> _withAttachedPhotos(List<_Place> places) async {
  final found = <String, Map<String, String>>{};
  await Future.wait(_photoField.entries.map((e) async {
    final names = [
      for (final p in places)
        if (p.kind == e.key && p.photo.isEmpty) p.name
    ];
    try {
      found[e.key] = await Api.attachedPhotos(e.value.$1, e.value.$2, names);
    } catch (_) {}
  }));
  return [
    for (final p in places)
      p.photo.isEmpty && (found[p.kind]?[p.name] ?? '').isNotEmpty
          ? p.withPhoto(found[p.kind]![p.name]!)
          : p
  ];
}

class ApprovalsView extends StatefulWidget {
  final List<ApprovalQueue> queues;

  /// Which queue to show; the home tab sets it when a count is tapped.
  final ValueNotifier<ApprovalQueue> selected;

  const ApprovalsView(
      {super.key, required this.queues, required this.selected});

  @override
  State<ApprovalsView> createState() => _ApprovalsViewState();
}

class _ApprovalsViewState extends State<ApprovalsView> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ApprovalQueue>(
      valueListenable: widget.selected,
      builder: (context, sel, _) {
        final current = widget.queues.contains(sel) ? sel : widget.queues.first;
        return Column(children: [
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: SegmentedButton<ApprovalQueue>(
              showSelectedIcon: false,
              segments: [
                for (final q in widget.queues)
                  ButtonSegment(value: q, label: Text(approvalQueueLabel[q]!)),
              ],
              selected: {current},
              onSelectionChanged: (s) => widget.selected.value = s.first,
            ),
          ),
          Expanded(
            child: switch (current) {
              ApprovalQueue.locations => const _LocationsQueue(),
              ApprovalQueue.attendance => const _AttendanceQueue(),
              ApprovalQueue.leave => const _LeaveQueue(),
            },
          ),
        ]);
      },
    );
  }
}

/// The scaffolding every queue shares: load, reload on sync, pull to refresh,
/// and drop a card the moment it is decided.
abstract class _QueueState<W extends StatefulWidget, T> extends State<W> {
  late Future<List<T>> _future = load();
  final Set<String> _done = {};
  final Set<String> _busy = {};

  Future<List<T>> load();
  String keyOf(T item);
  Widget card(T item);
  String get emptyText;

  @override
  void initState() {
    super.initState();
    SapSyncAll.epoch.addListener(_reload);
  }

  @override
  void dispose() {
    SapSyncAll.epoch.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _done.clear();
      _future = load();
    });
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  /// Runs one decision, then takes the card away.
  Future<void> decide(T item, Future<void> Function() write, String said) async {
    final k = keyOf(item);
    setState(() => _busy.add(k));
    try {
      await write();
      if (!mounted) return;
      setState(() => _done.add(k));
      _snack(said);
    } catch (e) {
      if (mounted) _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy.remove(k));
    }
  }

  bool busy(T item) => _busy.contains(keyOf(item));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<T>>(
      future: _future,
      builder: (context, snap) {
        Widget body;
        if (snap.connectionState != ConnectionState.done) {
          body = const Center(child: CircularProgressIndicator());
        } else if (snap.hasError) {
          body = ErrorState(error: snap.error, onRetry: _reload);
        } else {
          final items =
              (snap.data ?? []).where((i) => !_done.contains(keyOf(i))).toList();
          body = items.isEmpty
              ? EmptyState(icon: Icons.task_alt, text: emptyText)
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  itemCount: items.length,
                  itemBuilder: (_, i) => card(items[i]),
                );
        }
        return RefreshIndicator(
          onRefresh: () async {
            _reload();
            await _future.catchError((_) => <T>[]);
          },
          child: body is ListView
              ? body
              : LayoutBuilder(
                  builder: (_, c) => SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: SizedBox(height: c.maxHeight, child: body),
                  ),
                ),
        );
      },
    );
  }
}

// ----------------------------------------------------------- locations ---

/// The locations queue on its own screen, opened from the manager dashboard.
class LocationApprovalsScreen extends StatelessWidget {
  const LocationApprovalsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Location Approvals')),
        body: const _LocationsQueue(),
      );
}

class _LocationsQueue extends StatefulWidget {
  const _LocationsQueue();
  @override
  State<_LocationsQueue> createState() => _LocationsQueueState();
}

class _LocationsQueueState extends _QueueState<_LocationsQueue, _Place> {
  @override
  Future<List<_Place>> load() => _loadPlaces();
  @override
  String keyOf(_Place p) => '${p.kind}:${p.name}';
  @override
  String get emptyText => 'No locations to verify.';

  static const _kindLabel = {
    'customer': 'Customer',
    'lead': 'Lead',
    'site': 'Site',
  };

  Future<void> _write(_Place p, bool approve) => switch (p.kind) {
        'lead' => Api.approveLeadLocation(p.name, approve, p.lat, p.lng),
        'site' => Api.approveSite(p.name, approve, p.lat, p.lng),
        _ => Api.approveLocation(p.name, approve, p.lat, p.lng),
      };

  Future<void> _sendBack(_Place p) async {
    final ok = await confirmAction(context,
        title: 'Send back to ${p.rep.isEmpty ? 'the rep' : p.rep}?',
        body: 'They will need to capture this location again.',
        action: 'Send back',
        destructive: true);
    if (ok) await decide(p, () => _write(p, false), 'Sent back');
  }

  Future<void> _map(_Place p) async {
    final uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=${p.lat},${p.lng}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _noPhoto(String text) => Container(
        height: 90,
        width: double.infinity,
        color: const Color(0xFFF3F4F6),
        alignment: Alignment.center,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.no_photography_outlined, color: kMuted, size: 20),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(color: kMuted)),
        ]),
      );

  void _fullScreen(String url, String title) => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
                backgroundColor: Colors.black, title: Text(title)),
            body: Center(
              child: InteractiveViewer(
                maxScale: 5,
                child: Image.network(url, headers: Session.I.authHeaders),
              ),
            ),
          ),
        ),
      );

  @override
  Widget card(_Place p) {
    final photo = p.photo.isEmpty
        ? ''
        : (p.photo.startsWith('http') ? p.photo : '${Session.I.baseUrl}${p.photo}');
    return Panel(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // The photo is what the manager is verifying, so it is most of the
        // card, and a tap opens it full screen to read the board.
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: photo.isEmpty
              ? _noPhoto('No photo captured')
              : GestureDetector(
                  onTap: () => _fullScreen(photo, p.title),
                  child: Image.network(photo,
                      height: 300,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      headers: Session.I.authHeaders,
                      loadingBuilder: (_, child, progress) => progress == null
                          ? child
                          : Container(
                              height: 300,
                              color: const Color(0xFFF3F4F6),
                              alignment: Alignment.center,
                              child: const CircularProgressIndicator()),
                      errorBuilder: (_, __, ___) =>
                          _noPhoto('Photo could not be loaded')),
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(p.title.isEmpty ? p.name : p.title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              StatusPill(_kindLabel[p.kind] ?? p.kind, tone: Tone.info),
            ]),
            const SizedBox(height: 4),
            Text(p.rep.isEmpty ? p.name : 'Captured by ${p.rep}',
                style: const TextStyle(fontSize: 12, color: kMuted)),
            if (p.hasCoords)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact),
                  onPressed: () => _map(p),
                  icon: const Icon(Icons.place_outlined, size: 18),
                  label: const Text('View on map'),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('No coordinates captured',
                    style: TextStyle(fontSize: 12, color: kMuted)),
              ),
            const SizedBox(height: 8),
            DecisionButtons(
              approveLabel: 'Verify',
              rejectLabel: 'Send back',
              // Nothing to verify without coordinates — the dashboard refuses
              // the same way.
              onApprove: busy(p) || !p.hasCoords
                  ? null
                  : () => decide(p, () => _write(p, true), 'Verified'),
              onReject: busy(p) ? null : () => _sendBack(p),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------- attendance ---

class _AttendanceQueue extends StatefulWidget {
  const _AttendanceQueue();
  @override
  State<_AttendanceQueue> createState() => _AttendanceQueueState();
}

class _AttendanceQueueState
    extends _QueueState<_AttendanceQueue, Map<String, dynamic>> {
  Map<String, Map<String, dynamic>> _logs = {};
  bool _logsFailed = false;

  @override
  Future<List<Map<String, dynamic>>> load() async {
    final list = await Api.getPendingRegularizationsForManager();
    try {
      _logs = await Api.attendanceLogsFor(list);
    } catch (_) {
      // Left unknown rather than shown as "nothing punched", which would be a
      // claim about the rep's day that nobody checked.
      _logs = const {};
      _logsFailed = true;
      return list;
    }
    _logsFailed = false;
    return list;
  }

  @override
  String keyOf(Map<String, dynamic> r) => '${r['name']}';
  @override
  String get emptyText => 'No attendance corrections waiting.';

  String _time(dynamic dt) {
    final d = DateTime.tryParse(textOf(dt).replaceFirst(' ', 'T'));
    if (d == null) return '—';
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _reject(Map<String, dynamic> r) async {
    final ok = await confirmAction(context,
        title: 'Reject this correction?',
        action: 'Reject',
        destructive: true);
    if (ok) {
      await decide(r, () => Api.approveRegularization(r, false), 'Rejected');
    }
  }

  @override
  Widget card(Map<String, dynamic> r) {
    final reason = textOf(r['reason']);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(textOf(r['sales_person']),
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          Text(shortDate(r['attendance_date']),
              style: const TextStyle(fontSize: 13, color: kMuted)),
        ]),
        const SizedBox(height: 10),
        _actualRow(r),
        const SizedBox(height: 8),
        const Text('Requested',
            style: TextStyle(fontSize: 12, color: kMuted)),
        const SizedBox(height: 4),
        Row(children: [
          _timeBox('In', _time(r['requested_punch_in'])),
          const SizedBox(width: 10),
          _timeBox('Out', _time(r['requested_punch_out'])),
        ]),
        if (reason.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(reason, style: const TextStyle(fontSize: 13)),
        ],
        const SizedBox(height: 12),
        DecisionButtons(
          onApprove: busy(r)
              ? null
              : () => decide(
                  r, () => Api.approveRegularization(r, true), 'Approved'),
          onReject: busy(r) ? null : () => _reject(r),
        ),
      ]),
    );
  }

  /// What the rep actually punched that day, beside what they now ask for.
  Widget _actualRow(Map<String, dynamic> r) {
    final Widget body;
    if (_logsFailed) {
      body = const Text('Could not read the punches for this day',
          style: TextStyle(fontSize: 13, color: kMuted));
    } else {
      final a = actualPunchOf(
          _logs['${r['sales_person']}|${r['attendance_date']}']);
      final bad = a.kind != ActualPunchKind.complete;
      body = Row(children: [
        Expanded(
          child: Text(
              a.kind == ActualPunchKind.none
                  ? 'No punch in or out'
                  : 'In ${_time(a.punchIn)}  ·  Out ${_time(a.punchOut)}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ),
        if (bad) StatusPill(a.label, tone: Tone.bad),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Actual', style: TextStyle(fontSize: 12, color: kMuted)),
      const SizedBox(height: 4),
      body,
    ]);
  }

  Widget _timeBox(String label, String value) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            Text(label, style: const TextStyle(fontSize: 12, color: kMuted)),
            const Spacer(),
            Text(value,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}

// --------------------------------------------------------------- leave ---

class _LeaveQueue extends StatefulWidget {
  const _LeaveQueue();
  @override
  State<_LeaveQueue> createState() => _LeaveQueueState();
}

class _LeaveQueueState extends _QueueState<_LeaveQueue, Map<String, dynamic>> {
  final Map<String, LeaveBalance> _balances = {};

  @override
  Future<List<Map<String, dynamic>>> load() async {
    final list = await Api.getPendingLeaveForManager();
    final reps = list.map((e) => '${e['sales_person']}').toSet();
    await Future.wait(reps.map((r) async {
      try {
        _balances[r] = await Api.getLeaveBalance(r);
      } catch (_) {}
    }));
    return list;
  }

  @override
  String keyOf(Map<String, dynamic> r) => '${r['name']}';
  @override
  String get emptyText => 'No leave requests waiting.';

  Future<void> _reject(Map<String, dynamic> l) async {
    final ok = await confirmAction(context,
        title: 'Reject this leave?', action: 'Reject', destructive: true);
    if (ok) {
      await decide(l, () => Api.approveLeave('${l['name']}', false), 'Rejected');
    }
  }

  @override
  Widget card(Map<String, dynamic> l) {
    final rep = textOf(l['sales_person']);
    final half = '${l['half_day'] ?? 0}' == '1';
    final reason = textOf(l['reason']);
    final bal = _balances[rep];
    final rem = bal?.remaining ?? 0.0;
    // Somebody off the scheme has no entitlement to measure against, and
    // "0 left" would read as having used it all.
    final unpaid = bal != null && (!bal.onScheme || rem <= 0);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(rep,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          Text(shortDate(l['leave_date']),
              style: const TextStyle(fontSize: 13, color: kMuted)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          StatusPill(
              half ? 'Half day · ${textOf(l['half_day_period'])}' : 'Full day',
              tone: Tone.info),
          if (unpaid) ...[
            const SizedBox(width: 6),
            const StatusPill('Unpaid', tone: Tone.bad),
          ],
        ]),
        if (bal != null && bal.onScheme) ...[
          const SizedBox(height: 8),
          Text('${rem.toStringAsFixed(1)} of ${bal.entitlement.toStringAsFixed(1)} days left',
              style: const TextStyle(fontSize: 12, color: kMuted)),
        ],
        if (reason.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(reason, style: const TextStyle(fontSize: 13)),
        ],
        const SizedBox(height: 12),
        DecisionButtons(
          onApprove: busy(l)
              ? null
              : () => decide(
                  l, () => Api.approveLeave('${l['name']}', true), 'Approved'),
          onReject: busy(l) ? null : () => _reject(l),
        ),
      ]),
    );
  }
}
