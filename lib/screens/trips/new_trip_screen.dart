import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/screens/trips/trip_detail_screen.dart';
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

  // Route (Territory) the trip covers — same list the day map filters by.
  List<String> _routes = [];
  String? _route;
  bool _loadingRoutes = true;

  @override
  void initState() {
    super.initState();
    _loadRoutes();
  }

  Future<void> _loadRoutes() async {
    try {
      final r = await Api.getRoutes();
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
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
