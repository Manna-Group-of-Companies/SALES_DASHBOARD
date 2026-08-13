import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';

class ApplyLeaveScreen extends StatefulWidget {
  final DateTime? initialDate; // pre-filled when opened from the calendar
  const ApplyLeaveScreen({super.key, this.initialDate});
  @override
  State<ApplyLeaveScreen> createState() => _ApplyLeaveScreenState();
}

class _ApplyLeaveScreenState extends State<ApplyLeaveScreen> {
  DateTime? _date;
  bool _halfDay = false;
  String _halfPeriod = 'Morning';
  final _reason = TextEditingController();
  bool _busy = false;
  Map<String, double>? _balance;

  @override
  void initState() {
    super.initState();
    final d = widget.initialDate;
    if (d != null) _date = DateTime(d.year, d.month, d.day);
    _loadBalance();
  }

  Future<void> _loadBalance() async {
    final me = Session.I.salesPerson ?? '__none__';
    try {
      final b = await Api.getLeaveBalance(me);
      if (mounted) setState(() => _balance = b);
    } catch (_) {}
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d != null) setState(() => _date = d);
  }

  Future<void> _submit() async {
    if (_date == null) return _snack('Pick a leave date.');
    final now = DateTime.now();
    if (_halfDay && _sameDay(_date!, now) && now.hour >= 12) {
      return _snack('A half-day for today must be applied before 12 pm.');
    }
    setState(() => _busy = true);
    try {
      final ds =
          '${_date!.year}-${_date!.month.toString().padLeft(2, '0')}-${_date!.day.toString().padLeft(2, '0')}';
      await Api.createLeaveRequest(
          leaveDate: ds,
          halfDay: _halfDay,
          halfPeriod: _halfPeriod,
          reason: _reason.text.trim());
      _snack('Leave applied — sent for approval.');
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final days = _halfDay ? 0.5 : 1.0;
    final taken = _balance?['taken'] ?? 0;
    final willBeOver = _balance != null && (taken + days) > 12;
    return Scaffold(
      appBar: AppBar(title: const Text('Apply for Leave')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (_balance != null)
          Card(
            color: const Color(0xFFF7F7F8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                  'Remaining this year: ${(_balance!['remaining'] ?? 0).toStringAsFixed(1)} of 12'
                      '${(_balance!['pending'] ?? 0) > 0 ? '   ·   ${(_balance!['pending'])!.toStringAsFixed(1)} pending' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Leave date'),
          subtitle: Text(
              _date == null
                  ? 'Tap to choose (today or later)'
                  : '${_date!.day}/${_date!.month}/${_date!.year}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          trailing: const Icon(Icons.calendar_today),
          onTap: _pickDate,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Half day'),
          subtitle: const Text(
              'Counts as 0.5. For today, allowed only before 12 pm.'),
          value: _halfDay,
          onChanged: (v) => setState(() => _halfDay = v),
        ),
        if (_halfDay)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'Morning',
                    label: Text('Morning'),
                    icon: Icon(Icons.wb_twilight)),
                ButtonSegment(
                    value: 'Afternoon',
                    label: Text('Afternoon'),
                    icon: Icon(Icons.wb_sunny)),
              ],
              selected: {_halfPeriod},
              onSelectionChanged: (s) =>
                  setState(() => _halfPeriod = s.first),
            ),
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _reason,
          maxLines: 2,
          decoration: const InputDecoration(
              labelText: 'Reason (optional)', border: OutlineInputBorder()),
        ),
        if (willBeOver)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: const Color(0xFFFFEBEE),
                  borderRadius: BorderRadius.circular(8)),
              child: Row(children: const [
                Icon(Icons.info_outline, color: Colors.red, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                      'This goes beyond your 12-day allowance — it will be treated as without pay (LOP). You can still apply.',
                      style: TextStyle(color: Colors.red, fontSize: 13)),
                ),
              ]),
            ),
          ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _busy
                ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
                : const Text('Submit Leave'),
          ),
        ),
      ]),
    );
  }
}

