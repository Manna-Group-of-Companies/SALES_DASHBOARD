import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/services/api.dart';

class HRAddLeaveScreen extends StatefulWidget {
  const HRAddLeaveScreen({super.key});
  @override
  State<HRAddLeaveScreen> createState() => _HRAddLeaveScreenState();
}

class _HRAddLeaveScreenState extends State<HRAddLeaveScreen> {
  late Future<List<Map<String, dynamic>>> _reps;
  String? _rep;
  DateTime? _date;
  bool _halfDay = false;
  String _halfPeriod = 'Morning';
  final _reason = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reps = Api.getPickableReps();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d != null) setState(() => _date = d);
  }

  Future<void> _save() async {
    if (_rep == null) return _snack('Pick a sales person.');
    if (_date == null) return _snack('Pick a date.');
    setState(() => _busy = true);
    try {
      final ds =
          '${_date!.year}-${_date!.month.toString().padLeft(2, '0')}-${_date!.day.toString().padLeft(2, '0')}';
      final name = await Api.hrCreateLeave(
        rep: _rep!,
        leaveDate: ds,
        halfDay: _halfDay,
        halfPeriod: _halfPeriod,
        reason: _reason.text.trim(),
      );
      _snack('Leave added (approved)  $name');
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Leave (HR)')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _reps,
        builder: (context, snap) {
          final reps = snap.data ?? [];
          return ListView(padding: const EdgeInsets.all(16), children: [
            const Text(
                'Mark leave on behalf of a rep (e.g. phoned-in). Recorded as already approved; any date is allowed.',
                style: TextStyle(fontSize: 13, color: Colors.black54)),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _rep,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Sales Person', border: OutlineInputBorder()),
              items: reps
                  .map((r) => DropdownMenuItem(
                value: r['name'] as String,
                child: Text('${r['label']}',
                    overflow: TextOverflow.ellipsis),
              ))
                  .toList(),
              onChanged: (v) => setState(() => _rep = v),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Leave date'),
              subtitle: Text(
                  _date == null
                      ? 'Tap to choose (any date)'
                      : '${_date!.day}/${_date!.month}/${_date!.year}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              trailing: const Icon(Icons.calendar_today),
              onTap: _pickDate,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Half day'),
              value: _halfDay,
              onChanged: (v) => setState(() => _halfDay = v),
            ),
            if (_halfDay)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
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
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: _busy
                    ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                    : const Text('Add Leave'),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

// -------------------- PRODUCTION (approved POs -> key into SAP) --------------------
