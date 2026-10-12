// The team's customers and leads.
//
// The dashboard's Customers and Leads pages, on a phone: search, a rep filter,
// the same quick filters (no route, over the credit limit, overdue past terms;
// leads awaiting a location check), and putting a party on a route — which is
// the one thing a manager does to these records. A party with no route cannot
// be ordered from.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:manna_field_sales/core/credit.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/manager/manager_ui.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/core/visibility.dart';
import 'package:manna_field_sales/widgets/sync_all_button.dart';

enum _Filter { all, noRoute, overLimit, overdue, toVerify }

const Map<_Filter, String> _filterLabel = {
  _Filter.all: 'All',
  _Filter.noRoute: 'No route',
  _Filter.overLimit: 'Over limit',
  _Filter.overdue: 'Overdue',
  _Filter.toVerify: 'To verify',
};

class TeamPartiesView extends StatefulWidget {
  final bool showCustomers;
  final bool showLeads;
  const TeamPartiesView(
      {super.key, required this.showCustomers, required this.showLeads});

  @override
  State<TeamPartiesView> createState() => _TeamPartiesViewState();
}

class _TeamPartiesViewState extends State<TeamPartiesView> {
  late bool _leads = !widget.showCustomers;
  _Filter _filter = _Filter.all;
  String? _rep;
  String _query = '';
  late Future<List<Map<String, dynamic>>> _future = _load();

  @override
  void initState() {
    super.initState();
    SapSyncAll.epoch.addListener(_reload);
  }

  @override
  void dispose() {
    SapSyncAll.epoch.removeListener(_reload);
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _load() =>
      _leads ? Api.getTeamLeads() : Api.getTeamCustomers();

  void _reload() {
    if (mounted) setState(() => _future = _load());
  }

  String _ownerOf(Map<String, dynamic> r) =>
      textOf(r[_leads ? kFieldLeadOwner : kFieldCustomerOwner]);
  String _nameOf(Map<String, dynamic> r) => _leads
      ? [textOf(r['lead_name']), textOf(r['company_name'])]
          .firstWhere((s) => s.isNotEmpty, orElse: () => '${r['name']}')
      : (textOf(r['customer_name']).isEmpty
          ? '${r['name']}'
          : textOf(r['customer_name']));

  bool _noRoute(Map<String, dynamic> r) => textOf(r['custom_sales_route']).isEmpty;
  bool _overLimit(Map<String, dynamic> r) => overCreditLimit(r, 0);
  bool _overdue(Map<String, dynamic> r) => overduePastTerms(r) >= 1;
  bool _toVerify(Map<String, dynamic> r) =>
      textOf(r['custom_location_status']) == 'Pending Verification';

  bool _passes(Map<String, dynamic> r, _Filter f) => switch (f) {
        _Filter.all => true,
        _Filter.noRoute => _noRoute(r),
        _Filter.overLimit => _overLimit(r),
        _Filter.overdue => _overdue(r),
        _Filter.toVerify => _toVerify(r),
      };

  bool _matches(Map<String, dynamic> r) {
    if (_rep != null && _ownerOf(r) != _rep) return false;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [
      _nameOf(r),
      r['name'],
      r['custom_sales_route'],
      r['custom_gstin'],
      r['city'],
      r['mobile_no'],
      _ownerOf(r)
    ].any((v) => textOf(v).toLowerCase().contains(q));
  }

  List<_Filter> get _filters => _leads
      ? const [_Filter.all, _Filter.noRoute, _Filter.toVerify]
      : const [_Filter.all, _Filter.noRoute, _Filter.overLimit, _Filter.overdue];

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snap) {
        final loading = snap.connectionState != ConnectionState.done;
        final scoped = (snap.data ?? const <Map<String, dynamic>>[])
            .where(_matches)
            .toList();
        final counts = {
          for (final f in _filters) f: scoped.where((r) => _passes(r, f)).length
        };
        final rows = scoped.where((r) => _passes(r, _filter)).toList();
        return RefreshIndicator(
          onRefresh: () async {
            _reload();
            await _future.catchError((_) => <Map<String, dynamic>>[]);
          },
          child: CustomScrollView(slivers: [
            SliverToBoxAdapter(child: _header(counts)),
            if (loading)
              const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()))
            else if (snap.hasError)
              SliverFillRemaining(
                  hasScrollBody: false,
                  child: ErrorState(error: snap.error, onRetry: _reload))
            else if (rows.isEmpty)
              SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                      icon: _leads ? Icons.person_search : Icons.storefront,
                      text: _leads ? 'No leads here.' : 'No customers here.'))
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                sliver: SliverList.builder(
                  itemCount: rows.length,
                  itemBuilder: (_, i) => _tile(rows[i]),
                ),
              ),
          ]),
        );
      },
    );
  }

  Widget _header(Map<_Filter, int> counts) {
    final reps = [...Session.I.teamReps]..sort();
    return Container(
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.showCustomers && widget.showLeads) ...[
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('Customers')),
              ButtonSegment(value: true, label: Text('Leads')),
            ],
            selected: {_leads},
            onSelectionChanged: (s) {
              _leads = s.first;
              _filter = _Filter.all;
              _reload();
            },
          ),
          const SizedBox(height: 8),
        ],
        Row(children: [
          Expanded(
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                isDense: true,
                hintText: _leads ? 'Search leads' : 'Search customers',
                prefixIcon: const Icon(Icons.search, size: 20),
                filled: true,
                fillColor: const Color(0xFFF3F4F6),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String?>(
            tooltip: 'Rep',
            initialValue: _rep,
            onSelected: (r) => setState(() => _rep = r),
            itemBuilder: (_) => [
              const PopupMenuItem(value: null, child: Text('All reps')),
              for (final r in reps) PopupMenuItem(value: r, child: Text(r)),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                  border: Border.all(color: kLine),
                  borderRadius: BorderRadius.circular(12)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.person_outline, size: 18),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 90),
                  child: Text(_rep ?? 'All reps',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                ),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final f in _filters)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text('${_filterLabel[f]}  ${counts[f] ?? 0}'),
                  selected: _filter == f,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _filter = f),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _tile(Map<String, dynamic> r) {
    final route = textOf(r['custom_sales_route']);
    final a = _leads ? null : agingOf(r);
    final converted = _leads && textOf(r['customer']).isNotEmpty;
    return Panel(
      onTap: () => _details(r),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_nameOf(r),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(
                [
                  _ownerOf(r),
                  route.isEmpty ? 'No route' : route,
                ].where((s) => s.isNotEmpty).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    color: route.isEmpty ? toneColor(Tone.warn) : kMuted)),
          ]),
        ),
        const SizedBox(width: 8),
        if (a != null && a.total != 0)
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(money(a.total),
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _overLimit(r) ? toneColor(Tone.bad) : null)),
            if (_overLimit(r))
              const Text('Over limit',
                  style: TextStyle(fontSize: 11, color: kMuted))
            else if (_overdue(r))
              const Text('Overdue',
                  style: TextStyle(fontSize: 11, color: kMuted)),
          ])
        else if (converted)
          const StatusPill('Converted', tone: Tone.good)
        else if (_toVerify(r))
          const StatusPill('To verify', tone: Tone.warn),
      ]),
    );
  }

  Future<void> _details(Map<String, dynamic> r) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PartySheet(
          party: r, lead: _leads, name: _nameOf(r), owner: _ownerOf(r)),
    );
    if (changed == true) _reload();
  }
}

class _PartySheet extends StatefulWidget {
  final Map<String, dynamic> party;
  final bool lead;
  final String name;
  final String owner;
  const _PartySheet(
      {required this.party,
      required this.lead,
      required this.name,
      required this.owner});

  @override
  State<_PartySheet> createState() => _PartySheetState();
}

class _PartySheetState extends State<_PartySheet> {
  bool _saving = false;

  Map<String, dynamic> get p => widget.party;

  Future<void> _setRoute() async {
    final current = textOf(p['custom_sales_route']);
    List<String> routes;
    try {
      routes = await Api.getSalesRoutes(
          forRep: widget.owner);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
      return;
    }
    if (!mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Choose a route'),
        children: routes.isEmpty
            ? [
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('This rep has no routes yet.'),
                )
              ]
            : [
                for (final r in routes)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, r),
                    child: Row(children: [
                      Expanded(child: Text(r)),
                      if (r == current)
                        const Icon(Icons.check, size: 18, color: kBrand),
                    ]),
                  ),
              ],
      ),
    );
    if (picked == null || picked == current || !mounted) return;
    setState(() => _saving = true);
    try {
      await Api.assignRoute(
          lead: widget.lead, name: '${p['name']}', route: picked);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Route set to $picked')));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(humanError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final route = textOf(p['custom_sales_route']);
    final phone = textOf(p[widget.lead ? 'mobile_no' : 'custom_phone']);
    final a = widget.lead ? null : agingOf(p);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.name,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text('${p['name']}',
                  style: const TextStyle(fontSize: 12, color: kMuted)),
              const SizedBox(height: 14),
              _row('Rep', widget.owner.isEmpty ? '—' : widget.owner),
              _row('Route', route.isEmpty ? 'Not set' : route),
              if (!widget.lead) _row('GSTIN', textOf(p['custom_gstin']).isEmpty ? '—' : textOf(p['custom_gstin'])),
              if (widget.lead && textOf(p['city']).isNotEmpty)
                _row('Place', textOf(p['city'])),
              _row('Location', textOf(p['custom_location_status']).isEmpty
                  ? '—'
                  : textOf(p['custom_location_status'])),
              if (a != null) ...[
                const Divider(height: 24),
                _row('Outstanding', money(a.total)),
                _row('Credit limit',
                    a.creditLimit > 0 ? money(a.creditLimit) : 'None'),
                if (a.bucketsKnown) ...[
                  _row('0–30 days', money(a.current)),
                  _row('30–60 days', money(a.d30)),
                  _row('60–90 days', money(a.d60)),
                  _row('90+ days', money(a.d90)),
                ],
                if (overduePastTerms(p) >= 1)
                  _row('Overdue past terms', money(overduePastTerms(p)),
                      tone: Tone.bad),
              ],
              // As on the dashboard: a route is set where there is none, and
              // only for a party with a rep, whose routes are the choices.
              // Moving a party between routes is the rep's call on their own
              // round, not a manager's from a list.
              if (phone.isNotEmpty || (route.isEmpty && widget.owner.isNotEmpty)) ...[
                const SizedBox(height: 18),
                Row(children: [
                  if (phone.isNotEmpty)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => launchUrl(Uri.parse('tel:$phone')),
                        icon: const Icon(Icons.call_outlined, size: 18),
                        label: const Text('Call'),
                      ),
                    ),
                  if (phone.isNotEmpty && route.isEmpty && widget.owner.isNotEmpty)
                    const SizedBox(width: 10),
                  if (route.isEmpty && widget.owner.isNotEmpty)
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _saving ? null : _setRoute,
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.alt_route, size: 18),
                        label: const Text('Set route'),
                      ),
                    ),
                ]),
              ],
            ]),
      ),
    );
  }

  Widget _row(String k, String v, {Tone? tone}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(
              width: 120,
              child: Text(k,
                  style: const TextStyle(fontSize: 13, color: kMuted))),
          Expanded(
            child: Text(v,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: tone == null ? null : toneColor(tone))),
          ),
        ]),
      );
}
