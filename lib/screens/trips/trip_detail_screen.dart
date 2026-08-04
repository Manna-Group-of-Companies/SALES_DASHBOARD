import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/location_service.dart';
import 'package:manna_field_sales/services/map_service.dart';
import 'package:manna_field_sales/services/trip_tracker.dart';

class TripDetailScreen extends StatefulWidget {
  final String tripName;
  const TripDetailScreen({super.key, required this.tripName});
  @override
  State<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<TripDetailScreen> {
  Map<String, dynamic>? _trip;
  bool _loading = true;
  // Loaded once and shared by the visits list and the route map.
  List<Map<String, dynamic>> _visits = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _trip = await Api.getTrip(widget.tripName);
    } catch (_) {}
    try {
      _visits = await Api.getVisitsForTrip(widget.tripName);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  double _num(dynamic v) => (v is num) ? v.toDouble() : 0.0;

  // Only the trip owner can edit. Tagged members and HR are read-only.
  bool get _canEdit =>
      _trip != null && '${_trip!['sales_person']}' == Session.I.salesPerson;

  Future<void> _endTrip() async {
    if (_legs.isEmpty) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (dctx) => AlertDialog(
            title: const Text('Add a vehicle leg first'),
            content: const Text(
                'A trip needs at least one vehicle leg before you can end it. Use "Start leg" to record how you travelled.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dctx),
                  child: const Text('OK')),
            ],
          ),
        );
      }
      return;
    }
    final openLeg = _legs.any((l) {
      final m = '${l['mode']}';
      final isOdo = m == 'Own Vehicle' ||
          m == 'Bike' ||
          m == 'Company Vehicle (Car)' ||
          m == 'Company Vehicle (Bike)';
      return isOdo && _num(l['end_odometer']) == 0;
    });
    if (openLeg) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('Vehicle leg still open'),
          content: const Text(
              'A vehicle leg is still in progress — its closing odometer has not been recorded. End the leg first so the distance is captured.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dctx, false),
                child: const Text('Go end the leg')),
            TextButton(
                onPressed: () => Navigator.pop(dctx, true),
                child: const Text('End trip anyway')),
          ],
        ),
      );
      if (proceed != true) return;
    }
    List<Map<String, dynamic>> visits = const [];
    try {
      visits = await Api.getVisitsForTrip(widget.tripName);
    } catch (_) {}
    if (!mounted) return;
    final msg = visits.isEmpty
        ? 'This trip has no visits recorded. End the trip anyway?'
        : 'End this trip now? Route recording will stop.';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('End Trip'),
        content: Text(msg),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Not yet')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('End Trip')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      double? lat, lng;
      try {
        final pos = await getCurrentLocation();
        lat = pos.latitude;
        lng = pos.longitude;
      } catch (_) {}
      await Api.endTrip(name: widget.tripName, lat: lat, lng: lng);
      if (TripTracker.I.isRecording(widget.tripName)) {
        await TripTracker.I.stop();
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    }
  }

  Future<void> _cancelTrip() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Cancel this trip?'),
        content: const Text(
            'The trip will be marked Cancelled and route recording will stop. Anything already added stays on the record, but the trip won\'t count as completed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Keep trip')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('Cancel trip')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.cancelTrip(widget.tripName);
      if (TripTracker.I.isRecording(widget.tripName)) {
        await TripTracker.I.stop();
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    }
  }

  Future<void> _editCore() async {
    final t = _trip!;
    final purpose = TextEditingController(text: '${t['purpose'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Trip'),
        content: TextField(
            controller: purpose,
            decoration: const InputDecoration(labelText: 'Purpose')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.updateTrip(widget.tripName, {'purpose': purpose.text.trim()});
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    }
  }

  List<Map<String, dynamic>> get _legs =>
      ((_trip?['legs'] as List?) ?? []).cast<Map<String, dynamic>>();

  Future<void> _saveLegs(List<Map<String, dynamic>> legs) async {
    try {
      await Api.saveTripLegs(widget.tripName, legs);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    }
  }

  Future<void> _deleteLeg(int index) async {
    final legs = List<Map<String, dynamic>>.from(_legs);
    legs.removeAt(index);
    await _saveLegs(legs);
  }

  Future<void> _startLeg() async {
    String mode = 'Own Vehicle';
    final vehicleNo = TextEditingController();
    final startOdo = TextEditingController();
    final dist = TextEditingController();
    final claimed = TextEditingController();
    final remarks = TextEditingController();
    String? startPhoto;
    bool isOdoMode(String m) =>
        m == 'Own Vehicle' ||
            m == 'Bike' ||
            m == 'Company Vehicle (Car)' ||
            m == 'Company Vehicle (Bike)';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setL) {
          final odoMode = isOdoMode(mode);
          final isMixed = mode == 'Mixed';
          Future<void> shoot() async {
            final s = await ImagePicker()
                .pickImage(source: ImageSource.camera, imageQuality: 60);
            if (s != null) {
              setL(() => startPhoto = s.path);
            }
          }
          return AlertDialog(
            title: const Text('Start vehicle leg'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                DropdownButtonFormField<String>(
                  value: mode,
                  decoration: const InputDecoration(labelText: 'Mode'),
                  items: const [
                    DropdownMenuItem(
                        value: 'Own Vehicle',
                        child: Text('Own Vehicle (car)')),
                    DropdownMenuItem(value: 'Bike', child: Text('Bike (own)')),
                    DropdownMenuItem(
                        value: 'Company Vehicle (Car)',
                        child: Text('Company Vehicle (Car)')),
                    DropdownMenuItem(
                        value: 'Company Vehicle (Bike)',
                        child: Text('Company Vehicle (Bike)')),
                    DropdownMenuItem(value: 'Bus', child: Text('Bus / Train')),
                    DropdownMenuItem(value: 'Taxi', child: Text('Taxi')),
                    DropdownMenuItem(value: 'Mixed', child: Text('Mixed')),
                  ],
                  onChanged: (v) => setL(() => mode = v ?? 'Own Vehicle'),
                ),
                if (odoMode) ...[
                  TextField(
                      controller: vehicleNo,
                      decoration: const InputDecoration(
                          labelText: 'Vehicle no (optional)')),
                  TextField(
                      controller: startOdo,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Start odometer')),
                  const SizedBox(height: 8),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: shoot,
                    icon: Icon(
                        startPhoto == null
                            ? Icons.camera_alt
                            : Icons.check_circle,
                        size: 18),
                    label: Text(startPhoto == null
                        ? 'Start odometer photo'
                        : 'Start photo ✓'),
                  ),
                ],
                if (isMixed)
                  TextField(
                      controller: claimed,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'Amount you are claiming ₹')),
                if (mode == 'Bus' || mode == 'Taxi')
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                        'No per-km rate. Enter the ticket/fare amount under Expenses (attach the bill).',
                        style: TextStyle(fontSize: 11, color: Colors.black54)),
                  ),
                TextField(
                    controller: remarks,
                    decoration:
                    const InputDecoration(labelText: 'Remarks (optional)')),
              ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Start')),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    final odoMode = isOdoMode(mode);
    String? startUrl;
    if (startPhoto != null) {
      try {
        startUrl = await Api.uploadFileGetUrl(
            filePath: startPhoto!,
            doctype: 'Trip',
            docname: widget.tripName,
            filename: 'start_odo.jpg');
      } catch (_) {}
    }
    final leg = <String, dynamic>{
      'mode': mode,
      'vehicle_no': vehicleNo.text.trim(),
      'has_odometer': odoMode ? 1 : 0,
      'start_odometer': double.tryParse(startOdo.text.trim()) ?? 0,
      'end_odometer': 0,
      'leg_distance_km': double.tryParse(dist.text.trim()) ?? 0,
      'claimed_amount': double.tryParse(claimed.text.trim()) ?? 0,
      'start_odometer_photo': startUrl,
      'end_odometer_photo': null,
      'remarks': remarks.text.trim(),
    };
    final legs = List<Map<String, dynamic>>.from(_legs)..add(leg);
    await _saveLegs(legs);
  }

  String _fmtTime(dynamic dt) {
    if (dt == null) return '';
    final d = DateTime.tryParse('$dt'.replaceFirst(' ', 'T'));
    if (d == null) return '';
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  // Headline shown while ending a leg: distance and, when a rate is set for
  // the mode, what that distance is worth.
  String _legEstimateLine(double km, double rate, bool valid) {
    if (!valid) return 'Enter a reading higher than the start odometer.';
    final dist = '${km.toStringAsFixed(0)} km';
    if (rate <= 0) return '$dist — no per-km rate set for this mode';
    return '$dist  ·  ₹${(km * rate).toStringAsFixed(0)}';
  }

  Future<void> _endLeg(int idx) async {
    final l = _legs[idx];
    final startO = _num(l['start_odometer']);
    final endOdo = TextEditingController();
    String? endPhoto;
    // Per-km rate for this leg's mode, so the rep sees the claim as they type.
    double rate = 0;
    try {
      rate = Api.rateForMode(await Api.getTripRates(), l['mode'] as String?);
    } catch (_) {}
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setL) {
        Future<void> shoot() async {
          final s = await ImagePicker()
              .pickImage(source: ImageSource.camera, imageQuality: 60);
          if (s != null) setL(() => endPhoto = s.path);
        }
        final typed = double.tryParse(endOdo.text.trim()) ?? 0;
        final valid = typed > startO;
        final km = valid ? typed - startO : 0.0;
        return AlertDialog(
          title: const Text('End vehicle leg'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Align(
                alignment: Alignment.centerLeft,
                child: Text('Start odometer: ${startO.toStringAsFixed(0)}',
                    style: const TextStyle(fontWeight: FontWeight.w600))),
            const SizedBox(height: 8),
            TextField(
                controller: endOdo,
                keyboardType: TextInputType.number,
                onChanged: (_) => setL(() {}),
                decoration:
                const InputDecoration(labelText: 'End odometer')),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: shoot,
              icon: Icon(
                  endPhoto == null ? Icons.camera_alt : Icons.check_circle,
                  size: 18),
              label: Text(
                  endPhoto == null ? 'End odometer photo' : 'End photo ✓'),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: valid
                    ? const Color(0xFFE7F6EC)
                    : const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_legEstimateLine(km, rate, valid),
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15)),
                    if (valid && rate > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                            '${km.toStringAsFixed(0)} km × ₹${rate.toStringAsFixed(2)}/km',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.black54)),
                      ),
                  ]),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: valid ? () => Navigator.pop(ctx, true) : null,
                child: const Text('End leg')),
          ],
        );
      }),
    );
    if (ok != true) return;
    final endO = double.tryParse(endOdo.text.trim()) ?? 0;
    if (endO <= startO) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'End odometer must be greater than start (${startO.toStringAsFixed(0)}).')));
      }
      return;
    }
    String? endUrl;
    if (endPhoto != null) {
      try {
        endUrl = await Api.uploadFileGetUrl(
            filePath: endPhoto!,
            doctype: 'Trip',
            docname: widget.tripName,
            filename: 'end_odo.jpg');
      } catch (_) {}
    }
    final list = List<Map<String, dynamic>>.from(_legs);
    // Stamp the moment the leg was actually closed, not when it is next saved.
    final endedAt =
        DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    list[idx] = {
      ...list[idx],
      'end_odometer': endO,
      'leg_distance_km': endO - startO,
      'custom_end_time': endedAt,
      if (endUrl != null) 'end_odometer_photo': endUrl,
    };
    await _saveLegs(list);
    if (mounted) {
      final km = endO - startO;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Leg completed at ${_fmtTime(endedAt)} — ${_legEstimateLine(km, rate, true)}')));
    }
  }

  Future<void> _editLeg(int idx) async {
    final l = _legs[idx];
    final mode = '${l['mode']}';
    final isOdo = mode == 'Own Vehicle' ||
        mode == 'Bike' ||
        mode == 'Company Vehicle (Car)' ||
        mode == 'Company Vehicle (Bike)';
    final isMixed = mode == 'Mixed';
    final startOdo = TextEditingController(
        text: _num(l['start_odometer']) == 0
            ? ''
            : _num(l['start_odometer']).toStringAsFixed(0));
    final endOdo = TextEditingController(
        text: _num(l['end_odometer']) == 0
            ? ''
            : _num(l['end_odometer']).toStringAsFixed(0));
    final claimed = TextEditingController(
        text: _num(l['claimed_amount']) == 0
            ? ''
            : _num(l['claimed_amount']).toStringAsFixed(0));
    final vehicleNo = TextEditingController(text: '${l['vehicle_no'] ?? ''}');
    final remarks = TextEditingController(text: '${l['remarks'] ?? ''}');
    String? newStartPhoto, newEndPhoto;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setL) {
        Future<void> shoot(bool start) async {
          final s = await ImagePicker()
              .pickImage(source: ImageSource.camera, imageQuality: 60);
          if (s != null) {
            setL(() => start ? newStartPhoto = s.path : newEndPhoto = s.path);
          }
        }
        return AlertDialog(
          title: Text('Edit $mode leg'),
          content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (mode != 'Bus' && mode != 'Taxi')
                  TextField(
                      controller: vehicleNo,
                      decoration: const InputDecoration(labelText: 'Vehicle no')),
                if (isMixed) ...[
                  const SizedBox(height: 8),
                  TextField(
                      controller: claimed,
                      keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'Amount to be claimed (₹)')),
                ],
                if (mode == 'Bus' || mode == 'Taxi')
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                          'Fare for this leg goes under Expenses (attach the bill).',
                          style: TextStyle(fontSize: 12, color: Colors.black54))),
                if (isOdo) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                        child: TextField(
                            controller: startOdo,
                            keyboardType: TextInputType.number,
                            decoration:
                            const InputDecoration(labelText: 'Start odo'))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: TextField(
                            controller: endOdo,
                            keyboardType: TextInputType.number,
                            decoration:
                            const InputDecoration(labelText: 'End odo'))),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => shoot(true),
                          icon: Icon(
                              newStartPhoto == null
                                  ? Icons.camera_alt
                                  : Icons.check_circle,
                              size: 18),
                          label: Text(
                              newStartPhoto == null ? 'Retake start' : 'Start ✓',
                              overflow: TextOverflow.ellipsis),
                        )),
                    const SizedBox(width: 8),
                    Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => shoot(false),
                          icon: Icon(
                              newEndPhoto == null
                                  ? Icons.camera_alt
                                  : Icons.check_circle,
                              size: 18),
                          label: Text(newEndPhoto == null ? 'Retake end' : 'End ✓',
                              overflow: TextOverflow.ellipsis),
                        )),
                  ]),
                ],
                TextField(
                    controller: remarks,
                    decoration: const InputDecoration(labelText: 'Remarks')),
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save')),
          ],
        );
      }),
    );
    if (ok != true) return;
    String? startUrl, endUrl;
    if (newStartPhoto != null) {
      try {
        startUrl = await Api.uploadFileGetUrl(
            filePath: newStartPhoto!,
            doctype: 'Trip',
            docname: widget.tripName,
            filename: 'start_odo.jpg');
      } catch (_) {}
    }
    if (newEndPhoto != null) {
      try {
        endUrl = await Api.uploadFileGetUrl(
            filePath: newEndPhoto!,
            doctype: 'Trip',
            docname: widget.tripName,
            filename: 'end_odo.jpg');
      } catch (_) {}
    }
    final so = double.tryParse(startOdo.text.trim()) ?? 0;
    final eo = double.tryParse(endOdo.text.trim()) ?? 0;
    final list = List<Map<String, dynamic>>.from(_legs);
    final updated = {
      ...list[idx],
      'vehicle_no': vehicleNo.text.trim(),
      'remarks': remarks.text.trim(),
    };
    if (isOdo) {
      updated['start_odometer'] = so;
      updated['end_odometer'] = eo;
      updated['leg_distance_km'] =
      (eo > so) ? eo - so : _num(l['leg_distance_km']);
      if (startUrl != null) updated['start_odometer_photo'] = startUrl;
      if (endUrl != null) updated['end_odometer_photo'] = endUrl;
    }
    if (isMixed) {
      updated['claimed_amount'] = double.tryParse(claimed.text.trim()) ?? 0;
    }
    list[idx] = updated;
    await _saveLegs(list);
  }

  Widget _legsSection() {
    final legs = _legs;
    IconData legIcon(String? m) {
      switch (m) {
        case 'Bus':
          return Icons.directions_bus;
        case 'Taxi':
          return Icons.local_taxi;
        case 'Bike':
        case 'Company Vehicle (Bike)':
          return Icons.two_wheeler;
        case 'Mixed':
          return Icons.alt_route;
        default:
          return Icons.directions_car;
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Vehicle legs',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        if (_canEdit)
          TextButton.icon(
              onPressed: _startLeg,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Start leg')),
      ]),
      if (legs.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
              'No legs yet. Add one to set the vehicle mode and compute cost.',
              style: TextStyle(color: Colors.black45, fontSize: 12)),
        )
      else
        ...legs.asMap().entries.map((e) {
          final l = e.value;
          final mode = '${l['mode']}';
          final d = _num(l['leg_distance_km']);
          final claimed = _num(l['claimed_amount']);
          final startO = _num(l['start_odometer']);
          final endO = _num(l['end_odometer']);
          final isOdo = mode == 'Own Vehicle' ||
              mode == 'Bike' ||
              mode == 'Company Vehicle (Car)' ||
              mode == 'Company Vehicle (Bike)';
          final open = isOdo && endO == 0;
          final appr = (l['custom_approved_amount'] is num)
              ? (l['custom_approved_amount'] as num).toDouble()
              : 0.0;
          final vno = '${l['vehicle_no'] ?? ''}'.trim();
          String detail;
          if (mode == 'Mixed') {
            detail = '₹${claimed.toStringAsFixed(0)} (self-claimed)';
          } else if (mode == 'Bus' || mode == 'Taxi') {
            detail = 'bill in expenses';
          } else if (open) {
            detail = 'odo ${startO.toStringAsFixed(0)} → in progress';
          } else if (isOdo && startO > 0) {
            detail =
            '${startO.toStringAsFixed(0)} → ${endO.toStringAsFixed(0)}  (${d.toStringAsFixed(0)} km)';
          } else {
            detail = '${d.toStringAsFixed(0)} km';
          }
          final lstatus = '${l['status'] ?? 'Pending'}';
          final lrem = '${l['custom_approval_remarks'] ?? ''}'.trim();
          final bits = <String>[];
          if (vno.isNotEmpty) bits.add(vno);
          if (appr > 0) bits.add('Approved ₹${appr.toStringAsFixed(0)}');
          if (lstatus != 'Pending') bits.add(lstatus);
          var sub = bits.join('  ·  ');
          if (lrem.isNotEmpty) {
            sub = sub.isEmpty ? 'Note: $lrem' : '$sub\nNote: $lrem';
          }
          Widget? trail;
          if (Session.I.isHR) {
            trail = const Icon(Icons.rate_review_outlined,
                color: Color(0xFF4338CA));
          } else if (_canEdit) {
            if (open) {
              trail = FilledButton(
                onPressed: () => _endLeg(e.key),
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF46A21),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 34)),
                child: const Text('End leg'),
              );
            } else {
              final menu = PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'edit') _editLeg(e.key);
                  if (v == 'delete') _deleteLeg(e.key);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit readings')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              );
              // A finished odometer leg reads "Completed" in place of the
              // "End leg" button it replaces, stamped with the time it ended.
              final endedAt = _fmtTime(l['custom_end_time']);
              trail = isOdo
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE7F6EC),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                            endedAt.isEmpty
                                ? 'Completed'
                                : 'Completed $endedAt',
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF166534))),
                      ),
                      menu,
                    ])
                  : menu;
            }
          }
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              dense: true,
              leading: Icon(legIcon(mode),
                  color: open ? Colors.orange : const Color(0xFFF46A21)),
              title: Text('$mode · $detail'),
              subtitle: sub.isEmpty
                  ? null
                  : Text(sub,
                  style: TextStyle(
                      fontSize: 12,
                      color: lstatus == 'Approved'
                          ? Colors.green
                          : (lstatus == 'Rejected'
                          ? Colors.red
                          : Colors.black54))),
              trailing: trail,
              onTap: Session.I.isHR
                  ? () => _reviewLeg(e.key)
                  : (_canEdit && !open ? () => _editLeg(e.key) : null),
            ),
          );
        }),
    ]);
  }

  List<Map<String, dynamic>> get _expenses =>
      ((_trip?['expenses'] as List?) ?? []).cast<Map<String, dynamic>>();

  double _expensesTotal() {
    double t = 0;
    for (final e in _expenses) {
      if (e['amount'] is num) t += (e['amount'] as num).toDouble();
    }
    return t;
  }

  Future<void> _saveExpenses(List<Map<String, dynamic>> expenses) async {
    try {
      await Api.saveTripExpenses(widget.tripName, expenses);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    }
  }

  Future<void> _deleteExpense(int index) async {
    final list = List<Map<String, dynamic>>.from(_expenses);
    list.removeAt(index);
    await _saveExpenses(list);
  }

  Future<void> _addExpense() async {
    String category = 'Food';
    final expenseName = TextEditingController();
    final amount = TextEditingController();
    final remarks = TextEditingController();
    String? photoPath;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setL) => AlertDialog(
          title: const Text('Add expense'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: category,
                decoration: const InputDecoration(labelText: 'Category'),
                items: const [
                  DropdownMenuItem(value: 'Fuel', child: Text('Fuel')),
                  DropdownMenuItem(
                      value: 'Accommodation', child: Text('Accommodation')),
                  DropdownMenuItem(value: 'Food', child: Text('Food')),
                  DropdownMenuItem(
                      value: 'Daily Allowance', child: Text('Daily Allowance')),
                  DropdownMenuItem(value: 'Toll', child: Text('Toll')),
                  DropdownMenuItem(
                      value: 'Bus ticket', child: Text('Bus ticket')),
                  DropdownMenuItem(value: 'Taxi', child: Text('Taxi')),
                  DropdownMenuItem(value: 'Other', child: Text('Other')),
                ],
                onChanged: (v) => setL(() => category = v ?? 'Food'),
              ),
              if (category == 'Other')
                TextField(
                    controller: expenseName,
                    textCapitalization: TextCapitalization.words,
                    decoration:
                    const InputDecoration(labelText: 'Expense name')),
              TextField(
                  controller: amount,
                  keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Amount ₹')),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final shot = await ImagePicker()
                      .pickImage(source: ImageSource.camera, imageQuality: 70);
                  if (shot != null) setL(() => photoPath = shot.path);
                },
                icon: Icon(
                    photoPath == null ? Icons.camera_alt : Icons.check_circle),
                label: Text(photoPath == null
                    ? 'Attach bill photo (optional)'
                    : 'Bill attached'),
              ),
              TextField(
                  controller: remarks,
                  decoration:
                  const InputDecoration(labelText: 'Remarks (optional)')),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final amt = double.tryParse(amount.text.trim()) ?? 0;
    final nm = category == 'Other' ? expenseName.text.trim() : category;
    String? billUrl;
    if (photoPath != null) {
      try {
        billUrl = await Api.uploadFileGetUrl(
            filePath: photoPath!,
            doctype: 'Trip',
            docname: widget.tripName,
            filename: 'bill.jpg');
      } catch (_) {}
    }
    final exp = <String, dynamic>{
      'category': category,
      'expense_name': nm,
      'amount': amt,
      'has_bill': billUrl != null ? 1 : 0,
      'bill_photo': billUrl,
      'status': 'Submitted',
      'remarks': remarks.text.trim(),
    };
    final list = List<Map<String, dynamic>>.from(_expenses)..add(exp);
    await _saveExpenses(list);
  }

  Future<void> _reviewExpense(int idx) async {
    final x = _expenses[idx];
    final claimed =
    (x['amount'] is num) ? (x['amount'] as num).toDouble() : 0.0;
    String status = '${x['status'] ?? 'Pending'}';
    final cur = (x['custom_approved_amount'] is num)
        ? (x['custom_approved_amount'] as num).toDouble()
        : 0.0;
    final amtCtrl =
    TextEditingController(text: (cur > 0 ? cur : claimed).toStringAsFixed(0));
    final remCtrl =
    TextEditingController(text: '${x['custom_approval_remarks'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          title: const Text('Review expense'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Align(
                alignment: Alignment.centerLeft,
                child: Text('Claimed: ₹${claimed.toStringAsFixed(0)}',
                    style: const TextStyle(fontWeight: FontWeight.w600))),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: status,
              decoration: const InputDecoration(
                  labelText: 'Status', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'Pending', child: Text('Pending')),
                DropdownMenuItem(value: 'Approved', child: Text('Approved')),
                DropdownMenuItem(value: 'Rejected', child: Text('Rejected')),
              ],
              onChanged: (v) => setD(() => status = v ?? status),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amtCtrl,
              keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Approved amount (₹)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: remCtrl,
              decoration: const InputDecoration(
                  labelText: 'Remarks (optional)',
                  border: OutlineInputBorder()),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save')),
          ],
        );
      }),
    );
    if (ok == true) {
      final appr = double.tryParse(amtCtrl.text.trim()) ?? 0;
      final list = List<Map<String, dynamic>>.from(_expenses);
      list[idx] = {
        ...list[idx],
        'status': status,
        'custom_approved_amount': appr,
        'custom_approval_remarks': remCtrl.text.trim(),
      };
      await _saveExpenses(list);
    }
  }

  Future<void> _reviewLeg(int idx) async {
    final l = _legs[idx];
    final claimed = _num(l['claimed_amount']);
    String status = '${l['status'] ?? 'Pending'}';
    final cur = (l['custom_approved_amount'] is num)
        ? (l['custom_approved_amount'] as num).toDouble()
        : 0.0;
    final base = cur > 0 ? cur : claimed;
    final amtCtrl =
    TextEditingController(text: base > 0 ? base.toStringAsFixed(0) : '');
    final remCtrl =
    TextEditingController(text: '${l['custom_approval_remarks'] ?? ''}');
    bool notVerified = (l['custom_not_verified'] ?? 0) == 1;
    final startO = _num(l['start_odometer']);
    final endO = _num(l['end_odometer']);
    final asCtrl = TextEditingController(
        text: _num(l['custom_actual_start_odometer']) > 0
            ? _num(l['custom_actual_start_odometer']).toStringAsFixed(0)
            : '');
    final aeCtrl = TextEditingController(
        text: _num(l['custom_actual_end_odometer']) > 0
            ? _num(l['custom_actual_end_odometer']).toStringAsFixed(0)
            : '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          title: const Text('Review vehicle leg'),
          content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                DropdownButtonFormField<String>(
                  value: status,
                  decoration: const InputDecoration(
                      labelText: 'Status', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'Pending', child: Text('Pending')),
                    DropdownMenuItem(value: 'Approved', child: Text('Approved')),
                    DropdownMenuItem(value: 'Rejected', child: Text('Rejected')),
                  ],
                  onChanged: (v) => setD(() => status = v ?? status),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amtCtrl,
                  keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Approved amount (₹)',
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 4),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: notVerified,
                  title: const Text('Reading not verified (photo mismatch)',
                      style: TextStyle(fontSize: 13)),
                  onChanged: (v) => setD(() => notVerified = v ?? false),
                ),
                if (notVerified) ...[
                  Text(
                      'Typed: ${startO.toStringAsFixed(0)} → ${endO.toStringAsFixed(0)}. Enter the actual readings from the photo:',
                      style:
                      const TextStyle(fontSize: 11, color: Colors.black54)),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(
                        child: TextField(
                            controller: asCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                                labelText: 'Actual initial',
                                border: OutlineInputBorder()))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: TextField(
                            controller: aeCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                                labelText: 'Actual final',
                                border: OutlineInputBorder()))),
                  ]),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: remCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Remarks (optional)',
                      border: OutlineInputBorder()),
                ),
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save')),
          ],
        );
      }),
    );
    if (ok == true) {
      final appr = double.tryParse(amtCtrl.text.trim()) ?? 0;
      final list = List<Map<String, dynamic>>.from(_legs);
      list[idx] = {
        ...list[idx],
        'status': status,
        'custom_approved_amount': appr,
        'custom_approval_remarks': remCtrl.text.trim(),
        'custom_not_verified': notVerified ? 1 : 0,
        'custom_actual_start_odometer':
        double.tryParse(asCtrl.text.trim()) ?? 0,
        'custom_actual_end_odometer': double.tryParse(aeCtrl.text.trim()) ?? 0,
      };
      await _saveLegs(list);
    }
  }

  Widget _expensesSection() {
    final exp = _expenses;
    Color stColor(String s) {
      switch (s) {
        case 'Approved':
          return Colors.green;
        case 'Paid':
          return const Color(0xFF2563EB);
        case 'Rejected':
          return Colors.red;
        default:
          return Colors.orange;
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Expenses',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        if (_canEdit)
          TextButton.icon(
              onPressed: _addExpense,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add')),
      ]),
      if (exp.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
              'No expenses yet. Add fuel, food, accommodation, allowance, bus/taxi ticket etc.',
              style: TextStyle(color: Colors.black45, fontSize: 12)),
        )
      else
        ...exp.asMap().entries.map((e) {
          final x = e.value;
          final amt =
          (x['amount'] is num) ? (x['amount'] as num).toDouble() : 0.0;
          final appr = (x['custom_approved_amount'] is num)
              ? (x['custom_approved_amount'] as num).toDouble()
              : 0.0;
          final hasBill = (x['has_bill'] ?? 0) == 1;
          final nm = '${x['expense_name'] ?? ''}'.trim();
          final label = nm.isNotEmpty ? nm : '${x['category'] ?? 'Expense'}';
          final status = '${x['status'] ?? 'Pending'}';
          final apprText =
          appr > 0 ? '  ·  Approved ₹${appr.toStringAsFixed(0)}' : '';
          final erem = '${x['custom_approval_remarks'] ?? ''}'.trim();
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              dense: true,
              leading:
              const Icon(Icons.receipt_long, color: Color(0xFFF46A21)),
              title: Text('$label · ₹${amt.toStringAsFixed(0)}'),
              subtitle: Text(
                  '${hasBill ? 'Bill attached · ' : ''}$status$apprText'
                      '${erem.isNotEmpty ? '\nNote: $erem' : ''}',
                  style: TextStyle(fontSize: 12, color: stColor(status))),
              trailing: Session.I.isHR
                  ? const Icon(Icons.rate_review_outlined,
                  color: Color(0xFF4338CA))
                  : (_canEdit
                  ? IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: Colors.red),
                onPressed: () => _deleteExpense(e.key),
              )
                  : null),
              onTap: Session.I.isHR ? () => _reviewExpense(e.key) : null,
            ),
          );
        }),
    ]);
  }

  Widget _moneySummary() {
    final est = _num(_trip!['estimated_cost']);
    final exp = _expensesTotal();
    final grand = est + exp;
    Widget line(String k, String v, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child:
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(k,
            style: TextStyle(
                fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        Text(v,
            style: TextStyle(
                fontWeight: bold ? FontWeight.bold : FontWeight.w600)),
      ]),
    );
    return Card(
      color: const Color(0xFFFFF7ED),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Money',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          line('Per-km estimate', '₹${est.toStringAsFixed(0)}'),
          line('Actual expenses', '₹${exp.toStringAsFixed(0)}'),
          const Divider(),
          line('Grand total', '₹${grand.toStringAsFixed(0)}', bold: true),
        ]),
      ),
    );
  }

  List<String> get _taggedReps => (((_trip?['tagged_reps'] as List?) ?? [])
      .map((e) => '${(e as Map)['sales_person']}')
      .where((s) => s.isNotEmpty && s != 'null')
      .toList());

  Future<void> _editTags() async {
    List<Map<String, dynamic>> all = [];
    try {
      all = await Api.getAllSalesPersons();
    } catch (_) {}
    final me = Session.I.salesPerson;
    final selected = <String>{..._taggedReps};
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setL) => AlertDialog(
          title: const Text('Tag people on this trip'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(shrinkWrap: true, children: [
              for (final sp in all)
                if ('${sp['name']}' != me)
                  CheckboxListTile(
                    dense: true,
                    value: selected.contains('${sp['name']}'),
                    title: Text('${sp['name']}'),
                    onChanged: (v) => setL(() {
                      if (v == true) {
                        selected.add('${sp['name']}');
                      } else {
                        selected.remove('${sp['name']}');
                      }
                    }),
                  ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await Api.saveTripTaggedReps(widget.tripName, selected.toList());
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    }
  }

  Widget _taggedSection() {
    final reps = _taggedReps;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Tagged people',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        if (_canEdit)
          TextButton.icon(
              onPressed: _editTags,
              icon: const Icon(Icons.person_add, size: 18),
              label: const Text('Edit')),
      ]),
      if (reps.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
              'No one tagged. Tag teammates who travelled with you — this trip\'s visits are shared with them.',
              style: TextStyle(color: Colors.black45, fontSize: 12)),
        )
      else
        Wrap(
            spacing: 8,
            runSpacing: 4,
            children: reps
                .map((r) => Chip(
                label: Text(r),
                avatar: const Icon(Icons.person, size: 16)))
                .toList()),
    ]);
  }

  Widget _visitsSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Visits on this trip',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      const SizedBox(height: 4),
      if (_visits.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
              'No visits linked yet. Visits you check into during this trip appear here.',
              style: TextStyle(color: Colors.black45, fontSize: 12)),
        )
      else
        ..._visits.map((v) => Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                dense: true,
                leading: Icon(
                    Api.isLeadVisit(v)
                        ? Icons.person_pin_circle
                        : Icons.store,
                    color: const Color(0xFFF46A21)),
                title: Text(Api.visitParty(v)),
                subtitle: Text(
                    '${Api.isLeadVisit(v) ? 'Lead · ' : ''}'
                        '${v['visit_date']} · ${v['visit_status']} · ${v['sales_person']}'),
              ),
            )),
    ]);
  }

  Widget _recordRouteControl() {
    return ValueListenableBuilder<String?>(
      valueListenable: TripTracker.I.activeTrip,
      builder: (context, active, _) {
        final recording = active == widget.tripName;
        final otherActive = active != null && active != widget.tripName;
        if (recording) {
          return const Card(
            color: Color(0xFFE8F5E9),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Row(children: [
                Icon(Icons.fiber_manual_record, color: Colors.red, size: 18),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                      'Recording route — a point saves about every 5 min. It stops automatically when you End Trip; keep the notification running.',
                      style: TextStyle(fontSize: 13)),
                ),
              ]),
            ),
          );
        }
        return Card(
          color: const Color(0xFFFFF3E0),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: const [
                    Icon(Icons.location_off,
                        color: Color(0xFFD97706), size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          'Route recording is OFF for this active trip.',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.bold)),
                    ),
                  ]),
                  if (otherActive)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                          'Another trip ($active) is recording. End that trip first.',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.deepOrange)),
                    ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: otherActive
                        ? null
                        : () async {
                      final err =
                      await TripTracker.I.start(widget.tripName);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content:
                              Text(err ?? 'Recording resumed.')));
                      if (err == null) _load();
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Resume recording'),
                  ),
                ]),
          ),
        );
      },
    );
  }

  Widget _routeSection() {
    final raw =
    ((_trip?['gps_points'] as List?) ?? []).cast<Map<String, dynamic>>();
    final pts = raw
        .where((p) =>
    isMappableLatLng(_num(p['latitude']), _num(p['longitude'])))
        .toList()
      ..sort((a, b) => '${a['timestamp']}'.compareTo('${b['timestamp']}'));
    final latlngs = pts
        .map((p) => LatLng(_num(p['latitude']), _num(p['longitude'])))
        .toList();
    // Where each visit was checked in — drawn on top of the recorded drive.
    final visitPts = _visits
        .where((v) => isMappableLatLng(
            _num(v['check_in_latitude']), _num(v['check_in_longitude'])))
        .toList();
    final visitLatLngs = visitPts
        .map((v) =>
            LatLng(_num(v['check_in_latitude']), _num(v['check_in_longitude'])))
        .toList();
    final hasMap = latlngs.length >= 2 || visitLatLngs.isNotEmpty;
    final cz = mapCenterZoom([...latlngs, ...visitLatLngs]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Route',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      const SizedBox(height: 4),
      if (!hasMap)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
              latlngs.isEmpty
                  ? 'No route points yet. Use "Record route" on an active trip to log the drive.'
                  : 'Only one point so far — the route line shows once there are at least two.',
              style: const TextStyle(color: Colors.black45, fontSize: 12)),
        )
      else
        SizedBox(
          height: 240,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: FlutterMap(
              options: MapOptions(
                initialCenter: cz.center,
                initialZoom: cz.zoom,
              ),
              children: [
                TileLayer(
                  urlTemplate: mapTileUrl(),
                  userAgentPackageName: 'com.manna.fieldsales',
                ),
                if (latlngs.length >= 2)
                  PolylineLayer(polylines: [
                    Polyline(
                        points: latlngs,
                        strokeWidth: 4,
                        color: const Color(0xFF2563EB)),
                  ]),
                MarkerLayer(markers: [
                  if (latlngs.length >= 2) ...[
                    Marker(
                      point: latlngs.first,
                      width: 36,
                      height: 36,
                      child: const Icon(Icons.play_circle_fill,
                          color: Color(0xFF16A34A), size: 30),
                    ),
                    Marker(
                      point: latlngs.last,
                      width: 36,
                      height: 36,
                      child: const Icon(Icons.flag,
                          color: Color(0xFF7C3AED), size: 30),
                    ),
                  ],
                  ...visitPts.map((v) {
                    final isLead = Api.isLeadVisit(v);
                    return Marker(
                      point: LatLng(_num(v['check_in_latitude']),
                          _num(v['check_in_longitude'])),
                      width: 40,
                      height: 40,
                      child: GestureDetector(
                        onTap: () => _showVisitPoint(v),
                        child: Icon(
                            isLead ? Icons.person_pin_circle : Icons.store,
                            color: isLead
                                ? const Color(0xFF0F766E)
                                : const Color(0xFFF46A21),
                            size: 34),
                      ),
                    );
                  }),
                ]),
              ],
            ),
          ),
        ),
      if (pts.isNotEmpty || visitPts.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
              [
                if (pts.isNotEmpty) '${pts.length} route point(s) logged',
                if (visitPts.isNotEmpty) '${visitPts.length} visit(s) on map',
              ].join('  ·  '),
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ),
      if (_visits.length > visitPts.length)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
              '${_visits.length - visitPts.length} visit(s) have no check-in GPS.',
              style: const TextStyle(fontSize: 12, color: Colors.black45)),
        ),
    ]);
  }

  void _showVisitPoint(Map<String, dynamic> v) {
    final lat = _num(v['check_in_latitude']);
    final lng = _num(v['check_in_longitude']);
    final isLead = Api.isLeadVisit(v);
    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(isLead ? Icons.person_pin_circle : Icons.store,
                  color: isLead
                      ? const Color(0xFF0F766E)
                      : const Color(0xFFF46A21)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(Api.visitParty(v),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            ]),
            const SizedBox(height: 6),
            Text([
              isLead ? 'Lead visit' : 'Visit',
              '${v['visit_date']}',
              if (_fmtTime(v['check_in_time']).isNotEmpty)
                _fmtTime(v['check_in_time']),
              '${v['visit_status']}',
            ].join(' · ')),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                navigateTo(lat, lng);
              },
              icon: const Icon(Icons.directions),
              label: const Text('Navigate here'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [
      SizedBox(
          width: 140,
          child: Text(k, style: const TextStyle(color: Colors.black54))),
      Expanded(
          child: Text(v,
              style: const TextStyle(fontWeight: FontWeight.w600))),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.tripName), actions: [
        if (_trip != null && _canEdit)
          IconButton(icon: const Icon(Icons.edit), onPressed: _editCore),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _trip == null
          ? const Center(child: Text('Could not load trip.'))
          : ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text('${_trip!['purpose'] ?? 'Trip'}',
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold)),
                    ),
                    Chip(
                      label: Text('${_trip!['status']}'),
                      backgroundColor: _trip!['status'] == 'Active'
                          ? const Color(0xFFFFE8DC)
                          : (_trip!['status'] == 'Cancelled'
                          ? const Color(0xFFF3F4F6)
                          : const Color(0xFFE7F6EC)),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  _row('Date', '${_trip!['trip_date']}'),
                  _row('Distance',
                      '${_num(_trip!['total_distance_km']).toStringAsFixed(0)} km'),
                  _row('Primary mode',
                      '${_trip!['primary_mode'] ?? '—'}'),
                  _row(
                      'Estimated cost',
                      _num(_trip!['estimated_cost']) == 0
                          ? '—'
                          : '₹${_num(_trip!['estimated_cost']).toStringAsFixed(0)}'),
                  _row(
                      'Start GPS',
                      _num(_trip!['start_latitude']) == 0
                          ? '—'
                          : '${_num(_trip!['start_latitude']).toStringAsFixed(4)}, ${_num(_trip!['start_longitude']).toStringAsFixed(4)}'),
                ]),
          ),
        ),
        if (!_canEdit)
          const Card(
            color: Color(0xFFEEF2FF),
            child: ListTile(
              leading: Icon(Icons.visibility, color: Color(0xFF4338CA)),
              title: Text('Shared trip — view only',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                  'You are tagged on this trip. Only the person who created it can make changes.'),
            ),
          ),
        if (_trip!['status'] == 'Active' && _canEdit)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: FilledButton.icon(
              onPressed: _endTrip,
              icon: const Icon(Icons.flag),
              label: const Text('End Trip'),
            ),
          ),
        if (_trip!['status'] == 'Active' && _canEdit)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: _cancelTrip,
              icon: const Icon(Icons.cancel_outlined, color: Colors.red),
              label: const Text('Cancel Trip',
                  style: TextStyle(color: Colors.red)),
              style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.red)),
            ),
          ),
        if (_trip!['status'] == 'Active' && _canEdit)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _recordRouteControl(),
          ),
        const SizedBox(height: 20),
        _legsSection(),
        const SizedBox(height: 20),
        _expensesSection(),
        const SizedBox(height: 20),
        _moneySummary(),
        const SizedBox(height: 20),
        _taggedSection(),
        const SizedBox(height: 20),
        _visitsSection(),
        const SizedBox(height: 24),
        _routeSection(),
      ]),
    );
  }
}

