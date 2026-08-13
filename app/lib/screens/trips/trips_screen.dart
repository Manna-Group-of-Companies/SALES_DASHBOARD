import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/screens/trips/new_trip_screen.dart';
import 'package:manna_field_sales/screens/trips/trip_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/offline_banner.dart';

class TripsScreen extends StatefulWidget {
  const TripsScreen({super.key});
  @override
  State<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends State<TripsScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  @override
  void initState() {
    super.initState();
    _future = Api.getMyTrips();
  }

  void _reload() => setState(() {
    _future = Api.getMyTrips();
  });
  double _num(dynamic v) => (v is num) ? v.toDouble() : 0.0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trips'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const NewTripScreen()));
          _reload();
        },
        icon: const Icon(Icons.add),
        label: const Text('New Trip'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text(humanError(snap.error)));
          final trips = snap.data ?? [];
          if (trips.isEmpty) {
            return Column(children: [
              OfflineBanner.forKey(CacheKeys.trips),
              const Expanded(
                  child: Center(child: Text('No trips yet. Tap New Trip.'))),
            ]);
          }
          return Column(children: [
            OfflineBanner.forKey(CacheKeys.trips),
            Expanded(child: _tripList(trips)),
          ]);
        },
      ),
    );
  }

  Widget _tripList(List<Map<String, dynamic>> trips) {
          return ListView.separated(
            itemCount: trips.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final t = trips[i];
              final active = t['status'] == 'Active';
              final dist = _num(t['total_distance_km']);
              final shared = t['_shared'] == true;
              return ListTile(
                leading: Icon(shared ? Icons.group : Icons.directions_car,
                    color: active ? const Color(0xFFF46A21) : Colors.grey),
                title: Text('${t['trip_date']} · ${t['purpose'] ?? t['name']}'),
                subtitle: Text(
                    (active
                        ? 'Active · recording'
                        : '${dist.toStringAsFixed(0)} km · ${t['primary_mode'] ?? '—'}') +
                        (shared ? '  ·  by ${t['sales_person']}' : '')),
                trailing: shared
                    ? const Chip(
                    label: Text('Shared', style: TextStyle(fontSize: 11)),
                    backgroundColor: Color(0xFFE0E7FF))
                    : (active
                    ? const Chip(
                    label: Text('Active'),
                    backgroundColor: Color(0xFFFFE8DC))
                    : const Icon(Icons.chevron_right)),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => TripDetailScreen(tripName: t['name'])));
                  _reload();
                },
              );
            },
          );
  }
}

