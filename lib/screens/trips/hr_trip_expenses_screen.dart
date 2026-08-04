import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/screens/trips/trip_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';

class HRTripExpensesScreen extends StatefulWidget {
  const HRTripExpensesScreen({super.key});
  @override
  State<HRTripExpensesScreen> createState() => _HRTripExpensesScreenState();
}

class _HRTripExpensesScreenState extends State<HRTripExpensesScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  @override
  void initState() {
    super.initState();
    _future = Api.getAllTripsForHR();
  }

  void _reload() => setState(() {
    _future = Api.getAllTripsForHR();
  });
  double _n(dynamic v) => (v is num) ? v.toDouble() : 0.0;

  List<String> _tagged(String? csv) {
    if (csv == null || csv.isEmpty) return [];
    return csv.split('|').where((s) => s.trim().isNotEmpty).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trip Expenses'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text(humanError(snap.error)));
          final trips = snap.data ?? [];
          if (trips.isEmpty) return const Center(child: Text('No trips yet.'));
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: trips.length,
            itemBuilder: (_, i) {
              final t = trips[i];
              final est = _n(t['estimated_cost']);
              final exp = _n(t['total_expenses']);
              final fin = _n(t['final_cost']);
              final grand = fin > 0 ? fin : est + exp;
              final tags = _tagged(t['tagged_csv'] as String?);
              return Card(
                child: ListTile(
                  isThreeLine: true,
                  leading: const Icon(Icons.directions_car,
                      color: Color(0xFFF46A21)),
                  title: Text('${t['trip_date']} · ${t['purpose'] ?? t['name']}'),
                  subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            'By ${t['sales_person']}  ·  ${_n(t['total_distance_km']).toStringAsFixed(0)} km'),
                        Text(
                            'Est ₹${est.toStringAsFixed(0)}  ·  Expenses ₹${exp.toStringAsFixed(0)}  ·  Total ₹${grand.toStringAsFixed(0)}',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        if (tags.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text('Tagged: ${tags.join(', ')}',
                                style: const TextStyle(
                                    fontSize: 11, color: Color(0xFF4338CA))),
                          ),
                      ]),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              TripDetailScreen(tripName: t['name']))),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// -------------------- DAY MAP --------------------
