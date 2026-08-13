// Correcting a customer's details from the field.
//
// The route is the reason this screen exists. It is the only thing production
// is given to plan a delivery by — they never see who the order is for — so a
// customer with no route reaches the factory floor as "No route set" and
// nobody can plan a van. Setting it has to be possible before an order is
// taken, not a job for the office afterwards.
//
// The rest is the detail a rep is best placed to fix while standing in the
// shop: the phone number that has changed, the address that was never right,
// the GSTIN the proforma needs.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';

class CustomerEditScreen extends StatefulWidget {
  final Map<String, dynamic> customer;
  const CustomerEditScreen({super.key, required this.customer});
  @override
  State<CustomerEditScreen> createState() => _CustomerEditScreenState();
}

class _CustomerEditScreenState extends State<CustomerEditScreen> {
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late final TextEditingController _gstin;
  late final TextEditingController _state;

  String? _route;
  String? _group;
  List<String> _routes = [];
  List<String> _groups = [];
  late Future<void> _init;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final c = widget.customer;
    _phone = TextEditingController(text: _str(c['custom_phone']));
    _address = TextEditingController(text: _str(c['custom_address']));
    _gstin = TextEditingController(text: _str(c['custom_gstin']));
    _state = TextEditingController(text: _str(c['custom_state']));
    _route = _str(c['custom_sales_route']).isEmpty
        ? null
        : _str(c['custom_sales_route']);
    _group =
        _str(c['customer_group']).isEmpty ? null : _str(c['customer_group']);
    _init = _load();
  }

  static String _str(dynamic v) {
    final s = '${v ?? ''}';
    return (s == 'null') ? '' : s;
  }

  @override
  void dispose() {
    _phone.dispose();
    _address.dispose();
    _gstin.dispose();
    _state.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      Api.getSalesRoutes(forRep: Session.I.salesPerson),
      Api.getCustomerGroups(),
    ]);
    _routes = results[0];
    _groups = results[1];
    // A customer already sitting on a route this rep is not offered must not
    // silently lose it just because the dropdown cannot show it.
    if (_route != null && !_routes.contains(_route)) {
      _routes = [_route!, ..._routes];
    }
    if (_group != null && !_groups.contains(_group)) {
      _groups = [_group!, ..._groups];
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m)));

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await Api.updateCustomer(
        name: '${widget.customer['name']}',
        salesRoute: _route,
        customerGroup: _group,
        phone: _phone.text,
        address: _address.text,
        gstin: _gstin.text,
        state: _state.text,
      );
      _snack('Customer updated ✓');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(
              'Edit ${widget.customer['customer_name'] ?? widget.customer['name']}')),
      body: FutureBuilder<void>(
        future: _init,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(8)),
              child: const Row(children: [
                Icon(Icons.route, size: 18, color: Colors.black54),
                SizedBox(width: 8),
                Expanded(
                    child: Text(
                        'The route is what production uses to plan delivery. '
                        'Set it before taking an order.',
                        style: TextStyle(fontSize: 12))),
              ]),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _route,
              isExpanded: true,
              decoration: InputDecoration(
                  labelText: 'Sales route',
                  helperText: _routes.isEmpty
                      ? 'No sales routes exist yet — ask the office to create them'
                      : null,
                  border: const OutlineInputBorder(),
                  isDense: true),
              items: [
                for (final r in _routes)
                  DropdownMenuItem(value: r, child: Text(r))
              ],
              onChanged: _saving ? null : (v) => setState(() => _route = v),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _group,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Customer group',
                  border: OutlineInputBorder(),
                  isDense: true),
              items: [
                for (final g in _groups)
                  DropdownMenuItem(value: g, child: Text(g))
              ],
              onChanged: _saving ? null : (v) => setState(() => _group = v),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  labelText: 'Phone',
                  border: OutlineInputBorder(),
                  isDense: true),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _address,
              maxLines: 3,
              decoration: const InputDecoration(
                  labelText: 'Address',
                  helperText: 'Prints on the proforma',
                  border: OutlineInputBorder(),
                  isDense: true),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _gstin,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                  labelText: 'GSTIN',
                  helperText: 'Prints on the proforma',
                  border: OutlineInputBorder(),
                  isDense: true),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _state,
              decoration: const InputDecoration(
                  labelText: 'State',
                  helperText: 'Place of supply on the proforma',
                  border: OutlineInputBorder(),
                  isDense: true),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: _saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Save'),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
