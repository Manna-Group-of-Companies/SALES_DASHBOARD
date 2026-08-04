import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/server_clock.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/leave/apply_leave_screen.dart';
import 'package:manna_field_sales/services/api.dart';

/// The day the app went live. Nobody was punching in before this, so days
/// earlier than it are never marked absent.
final DateTime kGoLiveDate = DateTime(2026, 7, 20);

class AttendanceCalendarScreen extends StatefulWidget {
  final String? rep; // defaults to logged-in person
  final String? label;

  /// Opens the regularization form for this day as soon as the month loads.
  /// Set when the rep arrives here from a punch the app had to refuse.
  final DateTime? regularizeDate;

  const AttendanceCalendarScreen(
      {super.key, this.rep, this.label, this.regularizeDate});
  @override
  State<AttendanceCalendarScreen> createState() =>
      _AttendanceCalendarScreenState();
}

class _AttendanceCalendarScreenState extends State<AttendanceCalendarScreen> {
  late int _year;
  late int _month;
  bool _loading = true;
  final Map<String, Map<String, dynamic>> _logs = {};
  final Map<String, Map<String, dynamic>> _regs = {};
  final Map<String, Map<String, dynamic>> _leaves = {};

  /// `regularizeDate` opens its form once, not on every month reload.
  bool _autoOpened = false;

  String get _rep => widget.rep ?? Session.I.salesPerson ?? '__none__';

  @override
  void initState() {
    super.initState();
    final now = widget.regularizeDate ?? ServerClock.I.now();
    _year = now.year;
    _month = now.month;
    _load();
  }

  String _key(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final logs = await Api.getAttendanceForMonth(_rep, _year, _month);
      final regs = await Api.getRegularizationsForMonth(_rep, _year, _month);
      final leaves = await Api.getLeavesForMonth(_rep, _year, _month);
      _logs.clear();
      _regs.clear();
      _leaves.clear();
      for (final l in logs) {
        _logs['${l['attendance_date']}'] = l;
      }
      for (final r in regs) {
        _regs['${r['attendance_date']}'] = r;
      }
      for (final lv in leaves) {
        _leaves['${lv['leave_date']}'] = lv;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _loading = false);
    final day = widget.regularizeDate;
    if (day != null && !_autoOpened && widget.rep == null) {
      _autoOpened = true;
      _regularize(day, _logs[_key(day)]);
    }
  }

  void _shiftMonth(int delta) {
    var y = _year, m = _month + delta;
    if (m < 1) {
      m = 12;
      y--;
    } else if (m > 12) {
      m = 1;
      y++;
    }
    setState(() {
      _year = y;
      _month = m;
    });
    _load();
  }

  // Returns one of: green / amber / orange / red / null(blank)
  Color? _dayColor(DateTime day) {
    final today = ServerClock.I.now();
    final d0 = DateTime(day.year, day.month, day.day);
    final t0 = DateTime(today.year, today.month, today.day);
    final leave = _leaves[_key(day)];
    if (leave != null) {
      final full = (leave['half_day'] ?? 0) != 1;
      return full ? const Color(0xFF2563EB) : const Color(0xFF60A5FA);
    }
    if (d0.isAfter(t0)) return null;
    final log = _logs[_key(day)];
    if (log == null) {
      if (d0.isAtSameMomentAs(t0)) return null; // today, not punched yet
      if (d0.isBefore(kGoLiveDate)) return null; // before the app existed
      return Colors.red; // absent
    }
    final pin = log['punch_in_time'];
    final pout = log['punch_out_time'];
    if (pin != null && pout == null) return const Color(0xFFF59E0B); // orange
    if (pin != null && pout != null) {
      final inDt = DateTime.tryParse('$pin'.replaceFirst(' ', 'T'));
      final outDt = DateTime.tryParse('$pout'.replaceFirst(' ', 'T'));
      final lateIn = inDt != null &&
          (inDt.hour > 9 || (inDt.hour == 9 && inDt.minute > 30));
      final earlyOut = outDt != null &&
          (outDt.hour < 18 || (outDt.hour == 18 && outDt.minute < 30));
      return (lateIn || earlyOut)
          ? const Color(0xFFFACC15) // yellow
          : const Color(0xFF16A34A); // green
    }
    return null;
  }

  String _fmtTime(dynamic dt) {
    if (dt == null) return '—';
    final d = DateTime.tryParse('$dt'.replaceFirst(' ', 'T'));
    if (d == null) return '—';
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final monthName = const [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ][_month - 1];
    final daysInMonth = DateTime(_year, _month + 1, 0).day;
    final firstWeekday = DateTime(_year, _month, 1).weekday % 7; // Sun=0
    final cells = <Widget>[];
    for (int i = 0; i < firstWeekday; i++) {
      cells.add(const SizedBox());
    }
    for (int d = 1; d <= daysInMonth; d++) {
      final day = DateTime(_year, _month, d);
      final color = _dayColor(day);
      final hasReg = _regs.containsKey(_key(day));
      cells.add(InkWell(
        onTap: () => _openDay(day),
        child: Container(
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: color ?? Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: color == null
                    ? const Color(0xFFE5E7EB)
                    : Colors.transparent),
          ),
          child: Stack(children: [
            Center(
              child: Text('$d',
                  style: TextStyle(
                      color: color == null ? Colors.black87 : Colors.white,
                      fontWeight: FontWeight.w600)),
            ),
            if (hasReg)
              const Positioned(
                  right: 2,
                  top: 2,
                  child: Icon(Icons.flag, size: 10, color: Colors.white)),
          ]),
        ),
      ));
    }

    return Scaffold(
      appBar: AppBar(
          title: Text(widget.label == null
              ? 'My Attendance'
              : '${widget.label} — Attendance')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => _shiftMonth(-1)),
                Text('$monthName $_year',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => _shiftMonth(1)),
              ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
              children: const ['S', 'M', 'T', 'W', 'T', 'F', 'S']
                  .map((d) => Expanded(
                  child: Center(
                      child: Text(d,
                          style: const TextStyle(
                              color: Colors.black54,
                              fontWeight: FontWeight.w600)))))
                  .toList()),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: GridView.count(
              crossAxisCount: 7,
              children: cells,
            ),
          ),
        ),
        _legend(),
      ]),
    );
  }

  Widget _legend() {
    Widget chip(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
              color: c, borderRadius: BorderRadius.circular(3))),
      const SizedBox(width: 4),
      Text(t, style: const TextStyle(fontSize: 11)),
    ]);
    return Container(
      padding: const EdgeInsets.all(12),
      child: Wrap(spacing: 14, runSpacing: 8, children: [
        chip(const Color(0xFF16A34A), 'On time'),
        chip(const Color(0xFFFACC15), 'Late in / early out'),
        chip(const Color(0xFFF59E0B), 'Missed punch-out'),
        chip(Colors.red, 'Absent'),
        chip(const Color(0xFF2563EB), 'On leave'),
      ]),
    );
  }

  void _openDay(DateTime day) {
    final log = _logs[_key(day)];
    final reg = _regs[_key(day)];
    final leave = _leaves[_key(day)];
    final isFuture = DateTime(day.year, day.month, day.day)
        .isAfter(ServerClock.I.now());
    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${day.day}/${day.month}/${day.year}',
              style:
              const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            Column(children: [
              const Text('Punch In', style: TextStyle(color: Colors.black54)),
              Text(_fmtTime(log?['punch_in_time']),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ]),
            Column(children: [
              const Text('Punch Out', style: TextStyle(color: Colors.black54)),
              Text(_fmtTime(log?['punch_out_time']),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ]),
          ]),
          const SizedBox(height: 16),
          if (leave != null)
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                  color: const Color(0xFFDBEAFE),
                  borderRadius: BorderRadius.circular(8)),
              child: Text(
                  (leave['half_day'] ?? 0) == 1
                      ? 'On leave — ${leave['half_day_period'] ?? 'half'} half'
                      : 'On leave — full day',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E40AF))),
            ),
          if (reg != null)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(8)),
              child: Text(
                  'Regularization: ${reg['status']}'
                      '${reg['status'] == 'Pending Approval' ? ' (awaiting approval)' : ''}',
                  style: const TextStyle(fontSize: 13)),
            )
          else if (!isFuture && widget.rep == null)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _regularize(day, log);
              },
              icon: const Icon(Icons.edit_calendar),
              label: const Text('Request Regularization'),
            ),
          if (isFuture && leave == null && widget.rep == null)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _applyLeave(day);
              },
              icon: const Icon(Icons.beach_access),
              label: const Text('Apply Leave'),
            ),
        ]),
      ),
    );
  }

  Future<void> _applyLeave(DateTime day) async {
    final applied = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => ApplyLeaveScreen(initialDate: day)));
    if (applied == true) _load();
  }

  Future<void> _regularize(DateTime day, Map<String, dynamic>? log) async {
    // Seed from whatever the day already has, so a rep fixing a missed
    // punch-out only has to touch the one time that is actually wrong.
    TimeOfDay pick(dynamic stamp, TimeOfDay fallback) {
      final d = DateTime.tryParse('$stamp'.replaceFirst(' ', 'T'));
      return d == null ? fallback : TimeOfDay(hour: d.hour, minute: d.minute);
    }

    TimeOfDay inT =
    pick(log?['punch_in_time'], const TimeOfDay(hour: 9, minute: 30));
    TimeOfDay outT =
    pick(log?['punch_out_time'], const TimeOfDay(hour: 18, minute: 30));
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setL) => AlertDialog(
          title: Text('Regularize ${day.day}/${day.month}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              dense: true,
              title: const Text('Punch In'),
              trailing: Text(inT.format(ctx),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              onTap: () async {
                final t = await showTimePicker(context: ctx, initialTime: inT);
                if (t != null) setL(() => inT = t);
              },
            ),
            ListTile(
              dense: true,
              title: const Text('Punch Out'),
              trailing: Text(outT.format(ctx),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              onTap: () async {
                final t = await showTimePicker(context: ctx, initialTime: outT);
                if (t != null) setL(() => outT = t);
              },
            ),
            TextField(
              controller: reason,
              decoration: const InputDecoration(
                  labelText: 'Reason', border: OutlineInputBorder()),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Submit')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    String stamp(TimeOfDay t) =>
        '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')} '
            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00';
    try {
      await Api.createRegularization(
        attendanceDate: _key(day),
        punchIn: stamp(inT),
        punchOut: stamp(outT),
        reason: reason.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Regularization submitted for approval')));
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    }
  }
}

// -------------------- REGULARIZATION APPROVALS --------------------
