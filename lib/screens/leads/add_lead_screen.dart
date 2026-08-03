import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/route_picker.dart';

class AddLeadScreen extends StatefulWidget {
  /// Pass an existing lead row to edit it; omit it to create a new one.
  final Map<String, dynamic>? lead;
  const AddLeadScreen({super.key, this.lead});
  @override
  State<AddLeadScreen> createState() => _AddLeadScreenState();
}

class _AddLeadScreenState extends State<AddLeadScreen> {
  late Future<List<String>> _terrFut;
  final _name = TextEditingController();
  final _company = TextEditingController();
  final _mobile = TextEditingController();
  final _email = TextEditingController();
  final _gstin = TextEditingController();
  final _address = TextEditingController();
  String? _terms;
  String? _territory;
  String? _route;
  List<String> _routes = [];
  bool _busy = false;

  bool get _editing => widget.lead != null;

  @override
  void initState() {
    super.initState();
    _terrFut = Api.getRoutes();
    final l = widget.lead;
    _route = ((l?['custom_sales_route'] ?? '').toString().isEmpty ||
            '${l?['custom_sales_route']}' == 'null')
        ? null
        : '${l!['custom_sales_route']}';
    // A lead needs a route for the same reason a customer does: once it starts
    // ordering, production has nothing else to plan a delivery by.
    loadSalesRoutes(current: _route).then((r) {
      if (mounted) setState(() => _routes = r);
    });
    if (l != null) {
      String s(String k) => (l[k] ?? '').toString();
      _name.text = s('lead_name');
      _company.text = s('company_name');
      _mobile.text = s('mobile_no');
      _email.text = s('email_id');
      _gstin.text = s('custom_gstin');
      _address.text = s('custom_address');
      _terms = s('custom_payment_terms').isEmpty
          ? null
          : s('custom_payment_terms');
      _territory = s('territory').isEmpty ? null : s('territory');
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _snack('Enter a lead name.');
      return;
    }
    setState(() => _busy = true);
    try {
      if (_editing) {
        final updated = await Api.updateLead(
            name: widget.lead!['name'] as String,
            leadName: _name.text.trim(),
            company: _company.text,
            mobile: _mobile.text,
            email: _email.text,
            gstin: _gstin.text,
            address: _address.text,
            paymentTerms: _terms,
            territory: _territory,
            salesRoute: _route);
        _snack('Lead updated ✓');
        await Future.delayed(const Duration(milliseconds: 500));
        if (mounted) Navigator.pop(context, updated);
      } else {
        final n = await Api.createLead(
            leadName: _name.text.trim(),
            company: _company.text,
            mobile: _mobile.text,
            email: _email.text,
            gstin: _gstin.text,
            address: _address.text,
            paymentTerms: _terms,
            territory: _territory,
            salesRoute: _route);
        _snack('Lead created ✓  $n');
        await Future.delayed(const Duration(milliseconds: 500));
        if (mounted) Navigator.pop(context, true);
      }
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Edit Lead' : 'Add Lead')),
      body: FutureBuilder<List<String>>(
        future: _terrFut,
        builder: (context, snap) {
          final terrs = [...?snap.data];
          // The saved value may not be in the list (still loading, or the
          // territory was removed) — keep it selectable so it isn't lost.
          if (_territory != null && !terrs.contains(_territory)) {
            terrs.insert(0, _territory!);
          }
          final terms = ['Cash', 'Net 15', 'Net 30'];
          if (_terms != null && !terms.contains(_terms)) {
            terms.insert(0, _terms!);
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Name *',
                    border: OutlineInputBorder())),
            const SizedBox(height: 14),
            TextField(
                controller: _company,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Company (optional)',
                    border: OutlineInputBorder())),
            const SizedBox(height: 14),
            TextField(
                controller: _mobile,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                    labelText: 'Mobile (optional)',
                    border: OutlineInputBorder())),
            const SizedBox(height: 14),
            TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                    labelText: 'Email (optional)',
                    border: OutlineInputBorder())),
            const SizedBox(height: 14),
            TextField(
                controller: _gstin,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                    labelText: 'GST number (optional)',
                    border: OutlineInputBorder())),
            const SizedBox(height: 14),
            TextField(
                controller: _address,
                minLines: 2,
                maxLines: 3,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Address (optional)',
                    border: OutlineInputBorder())),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              value: _terms,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Terms of payment (optional)',
                  border: OutlineInputBorder()),
              items: terms
                  .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                  .toList(),
              onChanged: (v) => setState(() => _terms = v),
            ),
            const SizedBox(height: 14),
            SalesRouteField(
              value: _route,
              routes: _routes,
              enabled: !_busy,
              emptyHint:
                  'Production plans deliveries from this once the lead orders',
              onChanged: (v) => setState(() => _route = v),
            ),
            const SizedBox(height: 12),
            if (!_editing)
              Text(
                  'Lead is assigned to you (${Session.I.salesPersonLabel ?? 'you'}). Take an order next — your manager approves it before you can send the proforma.',
                  style: const TextStyle(fontSize: 13, color: Colors.black54)),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: _busy
                    ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                    : Text(_editing ? 'Save Changes' : 'Save Lead'),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

