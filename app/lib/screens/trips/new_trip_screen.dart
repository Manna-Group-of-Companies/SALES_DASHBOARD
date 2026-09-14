import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/trip_rules.dart';
import 'package:manna_field_sales/screens/trips/trip_detail_screen.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/location_service.dart';
import 'package:manna_field_sales/services/trip_tracker.dart';

class NewTripScreen extends StatefulWidget {
  const NewTripScreen({super.key});
  @override
  State<NewTripScreen> createState() => _NewTripScreenState();
}

class _NewTripScreenState extends State<NewTripScreen> {
  DateTime _date = DateTime.now();
  final _purpose = TextEditingController();
  bool _busy = false;
  String? _error;

  // The Sales Route the trip covers — this rep's own runs, not the Territory
  // tree. Territory is a sales hierarchy; a trip covers a delivery route, and
  // the two drifted far enough apart that offering territories here had reps
  // naming trips after something nobody plans by.
  List<String> _routes = [];
  String? _route;
  bool _loadingRoutes = true;

  // Trips this rep has left running. Checked before the form is offered
  // rather than after it is filled in: being refused at the Start Trip button,
  // having typed a purpose and picked a route, teaches a rep to distrust the
  // button. Api.createTrip refuses too — see core/trip_rules.dart — and that
  // backstop is what actually holds.
  List<RunningTrip> _running = const [];
  bool _checkingRunning = true;

  @override
  void initState() {
    super.initState();
    _loadRoutes();
    _checkRunning();
  }

  Future<void> _checkRunning() async {
    setState(() => _checkingRunning = true);
    try {
      final r = await Api.getActiveTrips();
      if (mounted) setState(() => _running = r);
    } catch (_) {
      // Could not ask — no signal, most likely. The form opens and the rep
      // finds out at the button, which is the worse message but the honest
      // one: refusing to let anybody start a trip because the check itself
      // failed would ground the whole team over a lost bar of signal.
      if (mounted) setState(() => _running = const []);
    } finally {
      if (mounted) setState(() => _checkingRunning = false);
    }
  }

  Future<void> _loadRoutes() async {
    try {
      // Scoped to this rep. A trip is one person's day, and a list of every
      // route in the company is a list to scroll past rather than choose from.
      final r = await Api.getSalesRoutes(forRep: Session.I.salesPerson);
      if (mounted) setState(() => _routes = r);
    } catch (_) {
      // A missing route list shouldn't stop the rep starting a trip.
    } finally {
      if (mounted) setState(() => _loadingRoutes = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      double? lat, lng;
      try {
        final pos = await getCurrentLocation();
        lat = pos.latitude;
        lng = pos.longitude;
      } catch (_) {}
      final ds =
          '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';
      final name = await Api.createTrip(
        tripDate: ds,
        purpose: _purpose.text.trim(),
        route: _route,
        lat: lat,
        lng: lng,
      );
      final startErr = await TripTracker.I.start(name);
      if (mounted) {
        if (startErr != null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Trip created. Route recording off: $startErr')));
        }
        Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (_) => TripDetailScreen(tripName: name)));
      }
    } catch (e) {
      setState(() => _error = humanError(e));
      // The refusal may be the backstop in Api.createTrip — a trip started on
      // another device, or a second tap that beat this one. Re-asking swaps
      // this screen for the one that names the trip and opens it. When the
      // failure was the network the re-ask fails too, nothing changes, and the
      // rep is left with the error above, which is the right message for it.
      unawaited(_checkRunning());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// What the rep sees instead of the form when a trip is already running.
  ///
  /// Names the trip and opens it, because "end that trip first" is only useful
  /// to somebody who can find it — and with two trips started on the same day
  /// the Trips list gives them two identical-looking rows to choose between.
  Widget _blockedByRunningTrip(String refusal) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        color: const Color(0xFFFFF3E0),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: const [
              Icon(Icons.error_outline, color: Color(0xFFD97706)),
              SizedBox(width: 8),
              Expanded(
                child: Text('Finish your last trip first',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ]),
            const SizedBox(height: 10),
            Text(refusal, style: const TextStyle(fontSize: 14, height: 1.4)),
          ]),
        ),
      ),
      const SizedBox(height: 16),
      for (final t in _running)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: OutlinedButton.icon(
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => TripDetailScreen(tripName: t.name)));
              // They may have ended it while they were in there.
              if (mounted) _checkRunning();
            },
            icon: const Icon(Icons.directions_car),
            label: Text('Open ${describeRunningTrip(t)}',
                overflow: TextOverflow.ellipsis),
          ),
        ),
      const SizedBox(height: 8),
      TextButton.icon(
        onPressed: _checkingRunning ? null : _checkRunning,
        icon: const Icon(Icons.refresh),
        label: const Text('Check again'),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    // The check has to finish before the form is offered, or the rep starts
    // typing into a form that is about to be taken away.
    if (_checkingRunning) {
      return Scaffold(
        appBar: AppBar(title: const Text('New Trip')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final refusal = tripStartRefusal(_running);
    if (refusal != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('New Trip')),
        body: _blockedByRunningTrip(refusal),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('New Trip')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Trip date'),
          subtitle: Text('${_date.day}/${_date.month}/${_date.year}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          trailing: const Icon(Icons.calendar_today),
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: _date,
              firstDate: DateTime.now().subtract(const Duration(days: 365)),
              lastDate: DateTime.now(),
            );
            if (d != null) setState(() => _date = d);
          },
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _route,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Route',
            prefixIcon: const Icon(Icons.alt_route, size: 18),
            border: const OutlineInputBorder(),
            suffixIcon: _loadingRoutes
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : null,
          ),
          hint: Text(_loadingRoutes ? 'Loading routes…' : 'Select a route'),
          items: _routes
              .map((r) => DropdownMenuItem(
                  value: r, child: Text(r, overflow: TextOverflow.ellipsis)))
              .toList(),
          onChanged:
              _loadingRoutes ? null : (v) => setState(() => _route = v),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _purpose,
          decoration: const InputDecoration(
              labelText: 'Purpose (e.g. Ernakulam dealer round)',
              border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        const Text(
            'Odometer readings and photos are captured per vehicle leg (in "Add / switch vehicle") after the trip starts.',
            style: TextStyle(fontSize: 12, color: Colors.black45)),
        const SizedBox(height: 20),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Start Trip'),
        ),
      ]),
    );
  }
}

// -------------------- TRIP ROUTE TRACKER (foreground GPS) --------------------
// Records a GPS point ~every 5 min while a trip is Active. Uses geolocator's
// foreground-service notification so points keep logging with the screen off.
// Only one trip records at a time; state lives for the app session.
