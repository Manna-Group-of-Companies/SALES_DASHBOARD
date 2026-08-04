import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/widgets/offline_banner.dart';

class HistoryList extends StatefulWidget {
  final String title;
  final Future<List<Map<String, dynamic>>> Function() loader;
  final Widget Function(BuildContext, Map<String, dynamic>) tileBuilder;

  /// The cache key [loader] reads through, so the list can say when it is
  /// showing data from the last sync rather than from now. Omit for a loader
  /// that is not cached.
  final String? cacheKey;

  const HistoryList(
      {required this.title,
      required this.loader,
      required this.tileBuilder,
      this.cacheKey});
  @override
  State<HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends State<HistoryList> {
  late Future<List<Map<String, dynamic>>> _future;
  String _q = '';
  @override
  void initState() {
    super.initState();
    _future = widget.loader();
  }

  bool _match(Map<String, dynamic> r) {
    if (_q.isEmpty) return true;
    final hay = r.values.map((e) => (e ?? '').toString().toLowerCase()).join(' ');
    return hay.contains(_q.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [
        IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() { _future = widget.loader(); })),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search…',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(
                    child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(humanError(snap.error))));
              }
              final all = snap.data!;
              final rows = all.where(_match).toList();
              // The banner is built after the load, so it reflects the read
              // that just happened rather than the one before it.
              final banner = widget.cacheKey == null
                  ? const SizedBox.shrink()
                  : OfflineBanner.forKey(widget.cacheKey!);
              if (all.isEmpty) {
                return Column(children: [
                  banner,
                  const Expanded(child: Center(child: Text('Nothing here yet.'))),
                ]);
              }
              if (rows.isEmpty) {
                return Column(children: [
                  banner,
                  const Expanded(child: Center(child: Text('No matches.'))),
                ]);
              }
              return Column(children: [
                banner,
                Expanded(
                  child: ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, i) => widget.tileBuilder(ctx, rows[i]),
                  ),
                ),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

