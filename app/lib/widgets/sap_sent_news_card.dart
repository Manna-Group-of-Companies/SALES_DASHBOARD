// "Sent to SAP" news on a sales manager's or the GM's home screen (the user,
// 26 Nov 2026: for now only the manager and the GM are told; reps are not).
//
// No server push exists and the app has no notification plugin, so this is
// the phone's twin of the dashboard's bell: each look reads the orders
// changed in the last week, `sapSentNews` says which have a SAP number they
// did not have at the last look, and those stay on the card until the
// manager clears them. The first look on a phone only takes the baseline.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/sap_sent.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/manager/manager_order_review_screen.dart';
import 'package:manna_field_sales/services/api.dart';

class SapSentNewsCard extends StatefulWidget {
  const SapSentNewsCard({super.key});
  @override
  State<SapSentNewsCard> createState() => _SapSentNewsCardState();
}

class _SapSentNewsCardState extends State<SapSentNewsCard> {
  static const _seenCap = 3000;
  static const _shownCap = 30;
  List<Map<String, dynamic>> _shown = const [];

  String get _seenKey => 'sapSentSeen:${Session.I.email}';
  String get _shownKey => 'sapSentShown:${Session.I.email}';

  @override
  void initState() {
    super.initState();
    _look();
  }

  Future<void> _look() async {
    try {
      final p = await SharedPreferences.getInstance();
      final shown = _decode(p.getString(_shownKey));
      if (mounted) setState(() => _shown = shown);

      final orders = await Api.getSentToSapCandidates();
      final seenRaw = p.getString(_seenKey);
      final seen = seenRaw == null
          ? null
          : (json.decode(seenRaw) as List).map((e) => '$e').toList();
      final r = sapSentNews(seen, orders);
      final keep = r.seen.length > _seenCap
          ? r.seen.sublist(r.seen.length - _seenCap)
          : r.seen;
      await p.setString(_seenKey, json.encode(keep));
      if (r.news.isEmpty) return;

      final next = [
        for (final o in r.news)
          {
            'name': o['name'],
            'customer': o['customer_name'] ?? o['customer'],
            'rep': o['custom_sales_person'],
            'headline': sapSentHeadline(o),
          },
        ...shown,
      ].take(_shownCap).toList();
      await p.setString(_shownKey, json.encode(next));
      if (mounted) setState(() => _shown = next);
    } catch (_) {
      // A failed read is quiet: the next look catches up, and nothing on
      // screen may say the network is gone.
    }
  }

  List<Map<String, dynamic>> _decode(String? raw) {
    if (raw == null) return const [];
    try {
      return (json.decode(raw) as List)
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _clear() async {
    setState(() => _shown = const []);
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_shownKey);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_shown.isEmpty) return const SizedBox.shrink();
    const green = Color(0xFF2E7D32);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        color: green.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.cloud_done_rounded, color: green),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        '${_shown.length} order${_shown.length == 1 ? '' : 's'} sent to SAP',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, color: green)),
                  ),
                  TextButton(onPressed: _clear, child: const Text('Clear')),
                ]),
                for (final o in _shown)
                  InkWell(
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => ManagerOrderReviewScreen(
                                orderName: '${o['name']}'))),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${o['customer'] ?? o['name']}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            Text(
                                [
                                  '${o['headline'] ?? ''}',
                                  '${o['name']}',
                                  '${o['rep'] ?? ''}',
                                ].where((s) => s.isNotEmpty && s != 'null').join(' · '),
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.black54)),
                          ]),
                    ),
                  ),
              ]),
        ),
      ),
    );
  }
}
