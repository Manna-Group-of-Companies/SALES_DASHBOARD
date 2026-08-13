import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/services/api.dart';

class TripRatesScreen extends StatefulWidget {
  const TripRatesScreen({super.key});
  @override
  State<TripRatesScreen> createState() => _TripRatesScreenState();
}

class _TripRatesScreenState extends State<TripRatesScreen> {
  final _car = TextEditingController();
  final _bike = TextEditingController();
  final _companyCar = TextEditingController();
  final _companyBike = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  double _n(dynamic v) => (v is num) ? v.toDouble() : 0.0;

  Future<void> _load() async {
    try {
      final r = await Api.getTripRates();
      _car.text = _n(r['rate_own_car']).toStringAsFixed(2);
      _bike.text = _n(r['rate_own_bike']).toStringAsFixed(2);
      _companyCar.text = _n(r['rate_company_car']).toStringAsFixed(2);
      _companyBike.text = _n(r['rate_company_bike']).toStringAsFixed(2);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await Api.saveTripRates({
        'rate_own_car': double.tryParse(_car.text.trim()) ?? 0,
        'rate_own_bike': double.tryParse(_bike.text.trim()) ?? 0,
        'rate_company_car': double.tryParse(_companyCar.text.trim()) ?? 0,
        'rate_company_bike': double.tryParse(_companyBike.text.trim()) ?? 0,
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Trip rates saved')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _rate(String label, TextEditingController c) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
          labelText: label,
          prefixText: '₹ ',
          suffixText: '/km',
          border: const OutlineInputBorder()),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trip Rates')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
            'Per-kilometre reimbursement rates used to estimate trip cost.',
            style: TextStyle(color: Colors.black54)),
        const SizedBox(height: 12),
        _rate('Own vehicle — car', _car),
        _rate('Own vehicle — bike', _bike),
        _rate('Company vehicle — car', _companyCar),
        _rate('Company vehicle — bike', _companyBike),
        const SizedBox(height: 8),
        const Text(
            'Bus / train and taxi have no per-km rate — the fare is entered as a trip expense with the bill. For "Mixed", the rep enters the amount they are claiming.',
            style: TextStyle(fontSize: 12, color: Colors.black45)),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save rates'),
        ),
      ]),
    );
  }
}

