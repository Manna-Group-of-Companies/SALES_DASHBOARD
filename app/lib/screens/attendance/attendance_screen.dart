import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/location_service.dart';

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});
  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  late Future<List<Map<String, dynamic>>> _reps;
  String? _rep;
  Map<String, dynamic>? today;
  bool _loadingToday = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reps = Api.getSalesPersons();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _loadToday() async {
    if (_rep == null) return;
    setState(() {
      _loadingToday = true;
      today = null;
    });
    try {
      final list = await Api.getTodayAttendance(_rep!);
      setState(() => today = list.isNotEmpty ? list.first : null);
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _loadingToday = false);
    }
  }

  Future<void> _punchIn() async {
    if (_rep == null) return _snack('Pick a sales person.');
    setState(() => _busy = true);
    _snack('Getting GPS…');
    try {
      final pos = await getCurrentLocation();
      await Api.punchIn(salesPerson: _rep!, lat: pos.latitude, lng: pos.longitude);
      _snack('Punched in ✓');
      await _loadToday();
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _punchOut() async {
    if (today == null) return;
    setState(() => _busy = true);
    _snack('Getting GPS…');
    try {
      final pos = await getCurrentLocation();
      final hours = await Api.punchOut(
        name: today!['name'],
        punchInTime: (today!['punch_in_time'] ?? '').toString(),
        lat: pos.latitude,
        lng: pos.longitude,
      );
      _snack('Punched out ✓  ${hours.toStringAsFixed(2)} h');
      await _loadToday();
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmtTime(dynamic dt) {
    if (dt == null) return '—';
    final s = dt.toString();
    return s.length >= 16 ? s.substring(11, 16) : s;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Attendance')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _reps,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text(humanError(snap.error)));
          final reps = snap.data ?? [];
          return Padding(
            padding: const EdgeInsets.all(20),
            child: ListView(children: [
              DropdownButtonFormField<String>(
                value: _rep,
                decoration: const InputDecoration(
                    labelText: 'Sales Person', border: OutlineInputBorder()),
                items: reps
                    .map((r) => DropdownMenuItem(
                    value: r['name'] as String,
                    child: Text(r['sales_person_name'] ?? r['name'])))
                    .toList(),
                onChanged: (v) {
                  setState(() => _rep = v);
                  _loadToday();
                },
              ),
              const SizedBox(height: 24),
              if (_rep == null)
                const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: Center(
                      child: Text(
                          'Select a sales person to mark attendance.')),
                )
              else if (_loadingToday)
                const Padding(
                    padding: EdgeInsets.only(top: 40),
                    child: Center(child: CircularProgressIndicator()))
              else
                _statusCard(),
            ]),
          );
        },
      ),
    );
  }

  Widget _statusCard() {
    final rec = today;
    if (rec == null) {
      return Column(children: [
        const Card(
          child: ListTile(
            leading: Icon(Icons.schedule, color: Colors.orange),
            title: Text('Not punched in today'),
            subtitle: Text('Tap below to start your day.'),
          ),
        ),
        const SizedBox(height: 20),
        _bigButton('Punch In', Icons.login, _busy ? null : _punchIn),
      ]);
    }
    if (rec['status'] == 'Punched In') {
      return Column(children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.login, color: Colors.green),
            title: Text('Punched in at ${_fmtTime(rec['punch_in_time'])}'),
            subtitle: const Text('You are currently on duty.'),
          ),
        ),
        const SizedBox(height: 20),
        _bigButton('Punch Out', Icons.logout, _busy ? null : _punchOut),
      ]);
    }
    final wh =
    (rec['working_hours'] is num) ? (rec['working_hours'] as num).toDouble() : 0.0;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.check_circle, color: Color(0xFFF46A21)),
        title: Text('Day complete · ${wh.toStringAsFixed(2)} h'),
        subtitle: Text(
            'In ${_fmtTime(rec['punch_in_time'])}  ·  Out ${_fmtTime(rec['punch_out_time'])}'),
      ),
    );
  }

  Widget _bigButton(String label, IconData icon, VoidCallback? onTap) {
    return FilledButton.icon(
      onPressed: onTap,
      icon: _busy
          ? const SizedBox(
          height: 18,
          width: 18,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Colors.white))
          : Icon(icon),
      label: Padding(
          padding: const EdgeInsets.all(12), child: Text(label)),
    );
  }
}

// -------------------- EXPENSES --------------------
