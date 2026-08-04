import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/services/api.dart';

class ComplaintScreen extends StatefulWidget {
  final Map<String, dynamic> customer;
  const ComplaintScreen({super.key, required this.customer});
  @override
  State<ComplaintScreen> createState() => _ComplaintScreenState();
}

class _ComplaintScreenState extends State<ComplaintScreen> {
  static const _types = [
    'Product Quality',
    'Delivery / Logistics',
    'Billing',
    'Service',
    'Other'
  ];
  String _type = 'Product Quality';
  final _desc = TextEditingController();
  bool _busy = false;

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  Future<void> _submit() async {
    if (_desc.text.trim().isEmpty) {
      _snack('Please describe the complaint.');
      return;
    }
    setState(() => _busy = true);
    try {
      final name = await Api.createComplaint(
        customer: widget.customer['name'] as String,
        complaintType: _type,
        description: _desc.text.trim(),
      );
      _snack('Complaint logged ✓  $name');
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
    final cn = widget.customer['customer_name'] ?? widget.customer['name'];
    return Scaffold(
      appBar: AppBar(title: const Text('Raise Complaint')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('$cn',
              style:
              const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _type,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Complaint type',
              border: OutlineInputBorder(),
            ),
            items: _types
                .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                .toList(),
            onChanged: (v) => setState(() => _type = v ?? _type),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _desc,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Describe the issue *',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: _busy
                  ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
                  : const Text('Submit Complaint'),
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------- ORDER --------------------
