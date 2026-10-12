// Route recording, said in the top bar.
//
// Until 11 October 2026 this was a full-width card on the home screen — green
// while recording, orange while not — and on a manager's phone it pushed the
// approvals below the fold. The bar carries a red dot now; the detail is a tap
// away.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/services/trip_tracker.dart';

class TripRecordingIndicator extends StatelessWidget {
  /// The rep's active trip, when the screen has read it. Without one the
  /// indicator only ever shows a recording in progress, never one to resume.
  final Map<String, dynamic>? trip;

  const TripRecordingIndicator({super.key, this.trip});

  static const _red = Color(0xFFEF4444);
  static const _amber = Color(0xFFF59E0B);

  void _snack(BuildContext context, String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m)));

  Future<void> _resume(BuildContext context, String tripName) async {
    final err = await TripTracker.I.start(tripName);
    if (!context.mounted) return;
    if (err != null && err.contains('Location permission')) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Location is not allowed for this app. '
            'Allow it in Settings → Permissions → Location.'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
            label: 'Settings', onPressed: TripTracker.I.openLocationSettings),
      ));
      return;
    }
    _snack(context, err ?? 'Recording resumed.');
  }

  void _details(BuildContext context, {required bool recording}) {
    final t = trip;
    final tripName = t == null ? null : '${t['name']}';
    final purpose = t == null ? null : '${t['purpose'] ?? tripName}';
    // Recording on "while using the app" logs the route only while Android
    // feels like it. Said while the trip is running and can still be fixed,
    // rather than left for the rep to work out from an empty route tonight.
    final partial = recording && TripTracker.I.needsAlwaysPermission;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(recording ? Icons.fiber_manual_record : Icons.location_off,
                      color: recording ? _red : _amber),
                  const SizedBox(width: 8),
                  Text(
                      recording
                          ? 'Recording trip route'
                          : 'Route recording is off',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 6),
                Text(
                    [
                      if (purpose != null) purpose,
                      recording
                          ? 'a point about every 5 min'
                          : 'points are not being logged',
                    ].join(' · '),
                    style: const TextStyle(color: Colors.black54)),
                if (partial) ...[
                  const SizedBox(height: 12),
                  const Text(
                      'Location is set to "while using the app", so the route '
                      'may stop being recorded once your screen is off. Set it '
                      'to "Allow all the time" to record the whole trip.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF92400E))),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: TripTracker.I.openLocationSettings,
                    icon: const Icon(Icons.settings, size: 16),
                    label: const Text('Open settings'),
                  ),
                ],
                if (!recording && tripName != null) ...[
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _resume(context, tripName);
                      },
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Resume recording'),
                    ),
                  ),
                ],
              ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: TripTracker.I.activeTrip,
      builder: (context, active, _) {
        if (active != null) {
          final partial = TripTracker.I.needsAlwaysPermission;
          return Tooltip(
            message: 'Recording trip route',
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _details(context, recording: true),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.fiber_manual_record, color: _red, size: 14),
                  const SizedBox(width: 4),
                  const Text('REC',
                      style: TextStyle(
                          color: _red,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6)),
                  // Recording, but perhaps not with the screen off.
                  if (partial) ...[
                    const SizedBox(width: 3),
                    const Icon(Icons.error, color: _amber, size: 13),
                  ],
                ]),
              ),
            ),
          );
        }
        if (trip == null) return const SizedBox.shrink();
        return IconButton(
          tooltip: 'Route recording is off',
          icon: const Icon(Icons.location_off, color: _amber),
          onPressed: () => _details(context, recording: false),
        );
      },
    );
  }
}
