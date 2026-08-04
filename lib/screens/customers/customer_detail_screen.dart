import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/collections/collection_screen.dart';
import 'package:manna_field_sales/screens/customers/customer_edit_screen.dart';
import 'package:manna_field_sales/screens/complaints/complaint_screen.dart';
import 'package:manna_field_sales/screens/orders/order_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/location_service.dart';
import 'package:manna_field_sales/services/map_service.dart';
import 'package:manna_field_sales/widgets/photo_source_sheet.dart';
import 'package:manna_field_sales/widgets/route_picker.dart';
import 'package:manna_field_sales/widgets/visit_punch_card.dart';

class CustomerDetailScreen extends StatefulWidget {
  final Map<String, dynamic> customer;
  final List<Map<String, dynamic>> reps;
  const CustomerDetailScreen(
      {super.key, required this.customer, required this.reps});
  @override
  State<CustomerDetailScreen> createState() => _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends State<CustomerDetailScreen> {
  late Map<String, dynamic> c;
  bool _busy = false;
  List<Map<String, dynamic>> _sites = [];
  bool _sitesLoading = true;

  @override
  void initState() {
    super.initState();
    c = Map<String, dynamic>.from(widget.customer);
    _loadSites();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  /// Lets a rep fix the details while they are standing in the shop — above
  /// all the route, which production needs before an order is worth taking.
  /// The customer is re-read afterwards rather than patched locally, so the
  /// screen shows what the server actually stored.
  Future<void> _edit() async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => CustomerEditScreen(customer: c)));
    if (saved != true) return;
    setState(() => _busy = true);
    try {
      final fresh = await Api.getCustomerDoc(c['name'] as String);
      if (mounted) setState(() => c = {...c, ...fresh});
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _status =>
      (c['custom_location_status'] ?? 'Not Captured').toString();

  /// A visit can only start once the shop location is on record. Awaiting the
  /// manager's verification is enough — the rep isn't blocked by that queue.
  /// 'Rejected' does not count: that location has to be captured again.
  bool get _locationCaptured =>
      _status == 'Pending Verification' || _status == 'Verified';

  /// Captures the shop location once. This never logs a visit — punching in
  /// on the visit card is the only thing that creates a Sales Visit.
  Future<void> _capture() async {
    final rep = Session.I.salesPerson;
    if (rep == null) return _snack('No rep linked to this login.');
    final img = await pickPhoto(context, title: 'Shop banner photo');
    if (img == null) return _snack('A shop banner photo is required.');
    setState(() => _busy = true);
    _snack('Getting GPS...');
    try {
      final pos = await getCurrentLocation();
      await Api.captureCustomerLocation(
        customer: c['name'],
        salesPerson: rep,
        lat: pos.latitude,
        lng: pos.longitude,
      );
      await Api.uploadPhoto(
        doctype: 'Customer',
        docname: c['name'],
        fieldname: 'custom_banner_photo',
        filePath: img.path,
        filename: 'banner.jpg',
      );
      setState(() {
        c['custom_location_status'] = 'Pending Verification';
        c['custom_latitude'] = pos.latitude;
        c['custom_longitude'] = pos.longitude;
      });
      _snack('Captured - sent for manager verification.');
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadSites() async {
    try {
      final s = await Api.getCustomerSites(c['name'] as String);
      if (mounted) {
        setState(() {
          _sites = s;
          _sitesLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _sitesLoading = false);
    }
  }

  Future<void> _addSite() async {
    final rep = Session.I.salesPerson;
    if (rep == null) return _snack('No rep linked to this login.');
    final ctrl = TextEditingController();
    final siteName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New site name'),
        content: TextField(
          controller: ctrl,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'e.g. Godown, Branch 2'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Next')),
        ],
      ),
    );
    if (siteName == null || siteName.isEmpty) return;
    if (!mounted) return;
    final img = await pickPhoto(context, title: 'Site banner photo');
    if (img == null) return _snack('A site banner photo is required.');
    setState(() => _busy = true);
    _snack('Getting GPS...');
    try {
      final pos = await getCurrentLocation();
      final created = await Api.createCustomerSite(
        customer: c['name'],
        siteName: siteName,
        lat: pos.latitude,
        lng: pos.longitude,
      );
      await Api.uploadPhoto(
        doctype: 'Customer Site',
        docname: created,
        fieldname: 'banner_photo',
        filePath: img.path,
        filename: 'site_banner.jpg',
      );
      _snack('Site "$siteName" captured — sent for manager verification.');
      await _loadSites();
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _sitesSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Sites',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        TextButton.icon(
            onPressed: _busy ? null : _addSite,
            icon: const Icon(Icons.add_location_alt, size: 18),
            label: const Text('Add site')),
      ]),
      if (_sitesLoading)
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('Loading sites…',
              style: TextStyle(fontSize: 12, color: Colors.black45)),
        )
      else if (_sites.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
              'No extra sites. The main location is used for check-in; add a site for a second shop or godown.',
              style: TextStyle(fontSize: 12, color: Colors.black45)),
        )
      else
        ..._sites.map((s) {
          final st = '${s['location_status']}';
          Color col;
          IconData ic;
          if (st == 'Verified') {
            col = Colors.green;
            ic = Icons.verified;
          } else if (st == 'Pending Verification') {
            col = Colors.orange;
            ic = Icons.hourglass_top;
          } else if (st == 'Rejected') {
            col = Colors.red;
            ic = Icons.cancel;
          } else {
            col = Colors.grey;
            ic = Icons.location_off;
          }
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              dense: true,
              leading: Icon(ic, color: col),
              title: Text('${s['site_name']}'),
              // Each site is its own drop. A customer's second yard can sit on
              // a completely different run from their office, so the route is
              // set per site rather than inherited from the customer.
              subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(st),
                    RouteChip(
                      route: '${s['route'] ?? ''}',
                      onTap: _busy ? null : () => _setSiteRoute(s),
                    ),
                  ]),
            ),
          );
        }),
    ]);
  }

  /// Puts one site on a route. Sites are separate places with separate runs,
  /// so this never touches the customer's own route.
  Future<void> _setSiteRoute(Map<String, dynamic> site) async {
    final current = '${site['route'] ?? ''}';
    final picked = await pickSalesRoute(context,
        current: current.isEmpty || current == 'null' ? null : current,
        title: 'Route for ${site['site_name']}');
    if (picked == null) return;
    setState(() => _busy = true);
    try {
      await Api.setSiteRoute('${site['name']}', picked);
      setState(() => site['route'] = picked);
      _snack('Site route set.');
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static double _num(dynamic v) =>
      (v is num) ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

  Future<void> _call(String phone) async {
    final uri = Uri.parse('tel:${phone.replaceAll(RegExp(r'[^0-9+]'), '')}');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      _snack('No dialler available.');
    }
  }

  /// The customer's own particulars — route, group, phone, ERP id and, once
  /// the shop has been captured, its coordinates with a way to navigate there.
  Widget _detailsSection() {
    final lat = _num(c['custom_latitude']);
    final lng = _num(c['custom_longitude']);
    final mappable = isMappableLatLng(lat, lng);
    final phone = '${c['custom_phone'] ?? ''}'.trim();

    Widget row(IconData ic, String label, String value, {Widget? action}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(ic, size: 18, color: Colors.black45),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.black45)),
                    Text(value, style: const TextStyle(fontSize: 14)),
                  ]),
            ),
            ?action,
          ]),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(children: [
          row(Icons.alt_route, 'Route',
              '${c['territory'] ?? ''}'.isEmpty ? '—' : '${c['territory']}'),
          row(
              Icons.category_outlined,
              'Group',
              '${c['customer_group'] ?? ''}'.isEmpty
                  ? '—'
                  : '${c['customer_group']}'),
          row(Icons.phone, 'Phone', phone.isEmpty ? '—' : phone,
              action: phone.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Call',
                      icon: const Icon(Icons.call, color: Colors.green),
                      onPressed: () => _call(phone))),
          row(Icons.badge_outlined, 'Customer ID', '${c['name']}'),
          row(
              Icons.location_on_outlined,
              'Location',
              mappable
                  ? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
                  : 'Not captured',
              action: mappable
                  ? IconButton(
                      tooltip: 'Navigate',
                      icon: const Icon(Icons.directions, color: Colors.blue),
                      onPressed: () => navigateTo(lat, lng))
                  : null),
        ]),
      ),
    );
  }

  Widget _creditSection() {
    final out = (c['custom_outstanding_balance'] is num)
        ? (c['custom_outstanding_balance'] as num).toDouble()
        : 0.0;
    final lim = (c['custom_credit_limit'] is num)
        ? (c['custom_credit_limit'] as num).toDouble()
        : 0.0;
    final over = lim > 0 && out > lim;
    Widget box(String label, String value, Color? bg) => Expanded(
      child: Card(
        color: bg,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 4),
            Text(value,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
          ]),
        ),
      ),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        box('Outstanding', '₹${out.toStringAsFixed(0)}',
            out > 0 ? const Color(0xFFFFF3E0) : null),
        box('Credit Limit', lim > 0 ? '₹${lim.toStringAsFixed(0)}' : '—',
            over ? const Color(0xFFFFEBEE) : null),
      ]),
      if (over)
        Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: const Color(0xFFFFEBEE),
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: const [
            Icon(Icons.warning_amber, color: Colors.red, size: 20),
            SizedBox(width: 8),
            Expanded(
                child: Text(
                    'Over credit limit — proforma will need manager release.',
                    style: TextStyle(color: Colors.red))),
          ]),
        ),
    ]);
  }

  /// One-time shop location capture, independent of visits. Once submitted the
  /// rep cannot recapture — the button only reports where the location sits in
  /// the manager's verification queue.
  Widget _locationSection() {
    final s = _status;
    final submitted = s == 'Pending Verification';
    final verified = s == 'Verified';

    final Color col = verified
        ? Colors.green
        : submitted
            ? Colors.orange
            : Colors.grey;
    final IconData ic = verified
        ? Icons.verified
        : submitted
            ? Icons.hourglass_top
            : Icons.my_location;
    final String label = verified
        ? 'Verified'
        : submitted
            ? 'Submitted for verification'
            : 'Capture Location';

    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor:
              verified || submitted ? col.withValues(alpha: 0.12) : null,
          foregroundColor: verified || submitted ? col : null,
          disabledBackgroundColor: col.withValues(alpha: 0.12),
          disabledForegroundColor: col,
        ),
        onPressed: (_busy || verified || submitted) ? null : _capture,
        icon: Icon(ic),
        label: Padding(padding: const EdgeInsets.all(12), child: Text(label)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(c['customer_name'] ?? c['name']),
        actions: [
          IconButton(
            tooltip: 'Edit customer',
            icon: const Icon(Icons.edit),
            onPressed: _busy ? null : _edit,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child:
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(c['customer_name'] ?? c['name'],
              style:
              const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text([c['customer_group'], c['custom_sales_route']]
              .where((x) => x != null && '$x'.isNotEmpty && '$x' != 'null')
              .join(' - ')),
          // The route is what production plans deliveries by, so its absence
          // is worth saying out loud rather than showing an empty line.
          if ('${c['custom_sales_route'] ?? ''}'.isEmpty ||
              '${c['custom_sales_route']}' == 'null')
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                Icon(Icons.route, size: 14, color: Colors.orange.shade800),
                const SizedBox(width: 4),
                Expanded(
                  child: Text('No sales route set — production cannot plan a '
                      'delivery for this customer.',
                      style: TextStyle(
                          fontSize: 11, color: Colors.orange.shade800)),
                ),
              ]),
            ),
          const SizedBox(height: 16),
          _detailsSection(),
          const SizedBox(height: 16),
          _creditSection(),
          const SizedBox(height: 16),
          _locationSection(),
          const SizedBox(height: 16),
          VisitPunchCard(
              customer: c['name'] as String,
              locationCaptured: _locationCaptured),
          const SizedBox(height: 16),
          _sitesSection(),
          const SizedBox(height: 16),
          if (Session.I.company != 'Manna Tyre Retreads') ...[
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => OrderScreen(customer: c))),
              icon: const Icon(Icons.shopping_cart),
              label: const Padding(
                  padding: EdgeInsets.all(12), child: Text('New Order')),
            ),
            const SizedBox(height: 16),
          ],
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    CollectionScreen(customer: c, reps: widget.reps))),
            icon: const Icon(Icons.payments),
            label: const Padding(
                padding: EdgeInsets.all(12), child: Text('Record Collection')),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.deepOrange),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ComplaintScreen(customer: c))),
            icon: const Icon(Icons.report_problem_outlined),
            label: const Padding(
                padding: EdgeInsets.all(12), child: Text('Raise Complaint')),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 20),
              child: Center(child: CircularProgressIndicator()),
            ),
        ]),
      ),
    );
  }
}

// -------------------- PROFORMA / PO PDF --------------------
