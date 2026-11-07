import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:manna_field_sales/core/customer_search.dart';
import 'package:manna_field_sales/core/party_location.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/core/visibility.dart';
import 'package:manna_field_sales/services/pending_punches.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/screens/customers/customer_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/map_service.dart';

class CustomerListScreen extends StatefulWidget {
  const CustomerListScreen({super.key});
  @override
  State<CustomerListScreen> createState() => _CustomerListScreenState();
}

class _CustomerListScreenState extends State<CustomerListScreen> {
  static const String _allRoutes = '__all__';

  List<Map<String, dynamic>> _all = [];
  /// Search text per row, keyed by docname — see core/customer_search.dart.
  Map<String, String> _hay = const {};
  List<Map<String, dynamic>> _reps = [];
  // Routes (Territories) the rep actually has customers on — taken from the
  // loaded list rather than a Territory fetch, so the dropdown never offers a
  // route that would come back empty.
  List<String> _routes = [];
  bool _loading = true;

  /// True while the copy on screen is the last synced one and the live list
  /// is on its way. Drawn as a thin bar, not a spinner: the rows are usable.
  bool _refreshing = false;
  String? _error;

  /// Set when the list came off the phone rather than the server. Shown, never
  /// hidden — an outstanding balance a rep quotes to a customer should not be
  /// silently three days old.
  String _staleNotice = '';

  String _q = '';
  String _route = _allRoutes;

  /*
   * The customer this rep is currently punched in at, pinned to the top of
   * the list until they punch out.
   *
   * A rep checks in at a shop, does an hour's work, and then has to find that
   * same customer again to check out — through a filter, a search box and six
   * hundred names. Since only one visit can be open at a time (see
   * Api.getAnyOpenVisit) there is at most ever one pinned row, and it is the
   * one they are most likely to want.
   *
   * Pinned ABOVE the filters rather than within them: the whole point is to
   * reach it without searching, so a route filter or a half-typed query must
   * not hide it. The badge on the row says why it is there.
   */
  String? _punchedInAt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _all.isEmpty;
      _refreshing = _all.isNotEmpty;
      _error = null;
    });
    // The last synced copy goes up first and the live list replaces it — see
    // Api.peekCustomers for why a rep should not watch a spinner while six
    // hundred rows cross a rural connection. The thin bar under the filters
    // says the copy is being refreshed. It is not the amber offline notice:
    // that still means the refresh failed and this IS the copy.
    if (_all.isEmpty) {
      final peeked = await Api.peekCustomers();
      if (!mounted) return;
      if (peeked != null && peeked.value.isNotEmpty) {
        setState(() {
          _index(peeked.value);
          _loading = false;
          _refreshing = true;
        });
      }
    }

    // Sales persons only decorate the list, so a failure there must not cost
    // the rep their customers when the cached copy would have served.
    Future<List<Map<String, dynamic>>> reps() async {
      try {
        return await Api.getSalesPersons();
      } catch (_) {
        return _reps;
      }
    }

    // Best-effort, like the sales persons above: a rep must not lose their
    // customer list because the visit lookup failed. Without the label — this
    // screen has every customer's name in hand and pins by docname.
    Future<String?> punched() async {
      try {
        // With the punch queue laid over it, so a shop punched in at with no
        // signal is pinned like any other.
        final open = PendingPunches.visitView(
          serverAny: await Api.getAnyOpenVisit(withLabel: false),
          pending: await PendingPunches.all(),
          today: today(),
        ).elsewhere;
        final code = '${open?['customer'] ?? ''}'.trim();
        return (code.isEmpty || code == 'null') ? null : code;
      } catch (_) {
        return _punchedInAt;
      }
    }

    try {
      // Started together. Awaited one after another they were three round
      // trips in a row before the first row drew.
      final customersF = Api.getCustomersCached();
      final repsF = reps();
      final punchedF = punched();
      final cached = await customersF;
      final repRows = await repsF;
      final pinned = await punchedF;
      if (!mounted) return;
      setState(() {
        _index(cached.value);
        _reps = repRows;
        _punchedInAt = pinned;
        _staleNotice = cached.ageLabel;
        _loading = false;
        _refreshing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        // With nothing on screen the error is the screen. With the synced
        // copy already up, the copy stays — but the failure is still said,
        // because a refused request is a real problem, not a weak signal.
        if (_all.isEmpty) _error = humanError(e);
      });
      if (_all.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not refresh: ${humanError(e)}')));
      }
    }
  }

  /// Takes a list on board: the rows, their search text, and the routes the
  /// dropdown may offer. Callers wrap it in setState.
  void _index(List<Map<String, dynamic>> rows) {
    _all = rows;
    _hay = {for (final c in rows) '${c['name']}': customerHaystack(c)};
    _routes = rows
        .map((c) => (c['custom_sales_route'] ?? '').toString())
        .where((t) => t.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    if (_route != _allRoutes && !_routes.contains(_route)) {
      _route = _allRoutes;
    }
  }

  static double _num(dynamic v) =>
      (v is num) ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

  Widget _filters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(children: [
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Search customers…',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => _q = v),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _route,
          isExpanded: true,
          isDense: true,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.alt_route, size: 18),
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(value: _allRoutes, child: Text('All routes')),
            ..._routes.map((r) => DropdownMenuItem(value: r, child: Text(r))),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _route = v);
          },
        ),
      ]),
    );
  }

  // Where the shop location sits: captured and verified, waiting on the
  // manager, rejected, or never captured at all.
  ({Color color, IconData icon, String label}) _locationBadge(
      Map<String, dynamic> c) {
    final s = (c['custom_location_status'] ?? 'Not Captured').toString();
    if (s == 'Verified') {
      return (color: Colors.green, icon: Icons.verified, label: 'Verified');
    }
    if (s == 'Pending Verification') {
      return (
        color: Colors.orange,
        icon: Icons.hourglass_top,
        label: 'Pending verification'
      );
    }
    if (s == 'Rejected') {
      return (color: Colors.red, icon: Icons.cancel, label: 'Rejected');
    }
    return (
      color: Colors.grey,
      icon: Icons.location_off,
      label: 'No location'
    );
  }

  /// Opens the customer, then re-reads the open visit on the way back.
  ///
  /// Punching out happens on the detail screen, so returning from it is
  /// exactly when a pin should clear. Awaited for that reason — it used to be
  /// fire-and-forget.
  Future<void> _open(Map<String, dynamic> c) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CustomerDetailScreen(customer: c, reps: _reps)));
    if (!mounted) return;
    try {
      final open = PendingPunches.visitView(
        serverAny: await Api.getAnyOpenVisit(withLabel: false),
        pending: await PendingPunches.all(),
        today: today(),
      ).elsewhere;
      final code = '${open?['customer'] ?? ''}'.trim();
      final next = (code.isEmpty || code == 'null') ? null : code;
      if (mounted && next != _punchedInAt) setState(() => _punchedInAt = next);
    } catch (_) {
      // Leave the pin as it was rather than dropping it on a failed read —
      // a rep still in the shop should not lose their way back.
    }
  }

  Future<void> _call(String phone) async {
    final uri = Uri.parse('tel:${phone.replaceAll(RegExp(r'[^0-9+]'), '')}');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('No dialler available.')));
      }
    }
  }

  /// Lets a UAE rep set or change who a customer belongs to.
  ///
  /// Only offered in a pooled unit (`Session.I.sharesUnit`) — everywhere else
  /// a customer has always belonged to one rep and reassignment is not
  /// something the app hands out. Any pool member may pick any pool member,
  /// including themselves, which is exactly what lets a freshly imported,
  /// unowned customer be claimed by whoever gets to it first.
  Future<void> _assignRep(Map<String, dynamic> c) async {
    final current = '${c[kFieldCustomerOwner] ?? ''}';
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Assign to'),
        children: [
          for (final name in Session.I.unitPeers)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, name),
              child: Row(children: [
                Icon(
                    name == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: const Color(0xFF1A56A8)),
                const SizedBox(width: 10),
                Text(name),
              ]),
            ),
        ],
      ),
    );
    if (chosen == null || chosen == current || !mounted) return;

    try {
      await Api.assignCustomerOwner('${c['name']}', chosen);
      if (!mounted) return;
      setState(() => c[kFieldCustomerOwner] = chosen);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Assigned to $chosen.')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    }
  }

  /// Quick look at one customer without leaving the list — the fields a rep
  /// checks while working down a route, plus call/navigate shortcuts.
  void _showDetails(Map<String, dynamic> c) {
    final badge = _locationBadge(c);
    final pos = partyLatLng(c);
    final lat = pos?.lat ?? 0, lng = pos?.lng ?? 0;
    final mappable = pos != null && isMappableLatLng(lat, lng);
    final phone = '${c['custom_phone'] ?? ''}'.trim();
    final route = '${c['custom_sales_route'] ?? ''}';
    final bal = _num(c['custom_outstanding_balance']);
    final lim = _num(c['custom_credit_limit']);

    Widget row(String label, String value, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
                width: 110,
                child: Text(label,
                    style:
                        const TextStyle(fontSize: 13, color: Colors.black54))),
            Expanded(
                child: Text(value,
                    style: TextStyle(
                        fontSize: 14,
                        color: color,
                        fontWeight:
                            color == null ? FontWeight.normal : FontWeight.bold))),
          ]),
        );

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${c['customer_name'] ?? c['name']}',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                // The sales route itself. This checked the route and then
                // printed the territory, so the row read blank or wrong for
                // exactly the customers whose route had been set.
                row('Route', route.isEmpty || route == 'null' ? '—' : route),
                row(
                    'Group',
                    '${c['customer_group'] ?? ''}'.isEmpty
                        ? '—'
                        : '${c['customer_group']}'),
                row('Phone', phone.isEmpty ? '—' : phone),
                row('Outstanding', '₹${bal.toStringAsFixed(0)}',
                    color: bal > 0 ? Colors.red : null),
                row('Credit limit', lim > 0 ? '₹${lim.toStringAsFixed(0)}' : '—'),
                row('Location', badge.label, color: badge.color),
                if (mappable)
                  row('Coordinates',
                      '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'),
                if (Session.I.sharesUnit) ...[
                  row(
                      'Assigned to',
                      '${c[kFieldCustomerOwner] ?? ''}'.isEmpty
                          ? 'Unassigned'
                          : '${c[kFieldCustomerOwner]}',
                      color: '${c[kFieldCustomerOwner] ?? ''}'.isEmpty
                          ? Colors.orange
                          : null),
                  const SizedBox(height: 4),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(sheet);
                      _assignRep(c);
                    },
                    icon: const Icon(Icons.person_add_alt, size: 16),
                    label: const Text('Assign rep'),
                  ),
                ],
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: phone.isEmpty
                          ? null
                          : () {
                              Navigator.pop(sheet);
                              _call(phone);
                            },
                      icon: const Icon(Icons.call),
                      label: const Text('Call'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: mappable
                          ? () {
                              Navigator.pop(sheet);
                              navigateTo(lat, lng);
                            }
                          : null,
                      icon: const Icon(Icons.directions),
                      label: const Text('Navigate'),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(sheet);
                    _open(c);
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open full details'),
                ),
              ]),
        ),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> c) {
    final badge = _locationBadge(c);
    final pos = partyLatLng(c);
    final lat = pos?.lat ?? 0, lng = pos?.lng ?? 0;
    final mappable = pos != null && isMappableLatLng(lat, lng);
    final bal = _num(c['custom_outstanding_balance']);
    final sub = [c['customer_group'], c['custom_sales_route']]
        .where((x) => x != null && '$x'.isNotEmpty)
        .join(' · ');

    /*
     * Whose customer this is.
     *
     * Only shown in a pooled unit, where seeing a record and owning it are
     * different things for the first time. A shared list with no owner on it
     * is a list nobody is responsible for — and a rep needs to know they are
     * covering before they ring somebody else's customer.
     */
    final owner = '${c[kFieldCustomerOwner] ?? ''}';
    final covering =
        Session.I.sharesUnit && owner.isNotEmpty && owner != Session.I.salesPerson;
    final unassigned = Session.I.sharesUnit && owner.isEmpty;

    final punchedIn = _punchedInAt != null && '${c['name']}' == _punchedInAt;

    return ListTile(
      // Tinted and labelled, so a row sitting above the filters explains
      // itself rather than looking like a sorting bug.
      tileColor: punchedIn ? const Color(0xFFE8F5E9) : null,
      title: Row(children: [
        Expanded(child: Text(c['customer_name'] ?? c['name'])),
        if (punchedIn)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
                color: Colors.green.shade600,
                borderRadius: BorderRadius.circular(4)),
            child: const Text('CHECKED IN',
                style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
          ),
      ]),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (sub.isNotEmpty) Text(sub),
        if (covering) ...[
          const SizedBox(height: 2),
          Row(children: [
            Icon(Icons.people_alt_outlined,
                size: 13, color: Colors.indigo.shade400),
            const SizedBox(width: 4),
            Text('$owner’s customer',
                style: TextStyle(fontSize: 11.5, color: Colors.indigo.shade400)),
          ]),
        ],
        if (unassigned) ...[
          const SizedBox(height: 2),
          Row(children: [
            Icon(Icons.person_off_outlined,
                size: 13, color: Colors.orange.shade700),
            const SizedBox(width: 4),
            Text('Unassigned — tap to assign',
                style: TextStyle(fontSize: 11.5, color: Colors.orange.shade700)),
          ]),
        ],
        const SizedBox(height: 2),
        Row(children: [
          Icon(badge.icon, size: 14, color: badge.color),
          const SizedBox(width: 4),
          Text(badge.label,
              style: TextStyle(fontSize: 12, color: badge.color)),
          if (mappable) ...[
            const SizedBox(width: 6),
            Expanded(
              child: Text('${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.black45)),
            ),
          ],
        ]),
      ]),
      isThreeLine: sub.isNotEmpty,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (bal > 0)
          Text('₹${bal.toStringAsFixed(0)}',
              style: const TextStyle(
                  color: Colors.red, fontWeight: FontWeight.bold)),
        IconButton(
          tooltip: 'Details',
          icon: const Icon(Icons.info_outline),
          color: Colors.blueGrey,
          onPressed: () => _showDetails(c),
        ),
      ]),
      onTap: () => unawaited(_open(c)),
      onLongPress: () => _showDetails(c),
    );
  }

  /// The rows actually rendered, in order.
  ///
  /// The shop the rep is punched in at goes first, whatever the filters say.
  /// Removed from its place before being put on top so it never appears
  /// twice, and included even when the current filter would exclude it —
  /// having to clear a filter to punch out is the problem this solves.
  ///
  /// One method rather than two, because the header counts these rows: worked
  /// out separately, the count and the list disagree by one exactly when a
  /// pinned customer falls outside the filter.
  List<Map<String, dynamic>> _visible() {
    final filter =
        CustomerFilter(query: _q, route: _route == _allRoutes ? null : _route);
    final rows = _all
        .where((c) =>
            filter.matches(c, _hay['${c['name']}'] ?? customerHaystack(c)))
        .toList();
    final pinned = _punchedInAt;
    if (pinned == null) return rows;

    rows.removeWhere((c) => '${c['name']}' == pinned);
    final match = _all.where((c) => '${c['name']}' == pinned).toList();
    if (match.isNotEmpty) rows.insert(0, match.first);
    return rows;
  }

  Widget _list(List<Map<String, dynamic>> customers) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(20), child: Text('Error: $_error')));
    }
    if (_all.isEmpty) return const Center(child: Text('No customers found.'));
    if (customers.isEmpty) {
      return Center(
          child: Text(_route == _allRoutes
              ? 'No matches.'
              : 'No matches on $_route.'));
    }
    return ListView.separated(
      itemCount: customers.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) => _tile(customers[i]),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Filtered once per build. The header count and the list used to each
    // filter the six hundred rows for themselves, on every keystroke.
    final customers = _loading ? const <Map<String, dynamic>>[] : _visible();
    final shown = customers.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Customers'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
      ]),
      body: Column(children: [
        _filters(),
        if (_refreshing) const LinearProgressIndicator(minHeight: 2),
        if (_staleNotice.isNotEmpty && !_loading)
          Container(
            width: double.infinity,
            color: const Color(0xFFFFF4E5),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              const Icon(Icons.cloud_off, size: 15, color: Color(0xFFB35309)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_staleNotice,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFFB35309))),
              ),
            ]),
          ),
        if (!_loading && _error == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  _route == _allRoutes
                      ? '$shown customers'
                      : '$shown on $_route',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ),
          ),
        Expanded(child: _list(customers)),
      ]),
    );
  }
}
