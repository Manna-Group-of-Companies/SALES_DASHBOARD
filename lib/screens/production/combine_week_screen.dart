// Closing a week: one combined order per customer.
//
// The production manager runs this once a week has finished. Everything that
// completed in that week is gathered per customer, so a customer who took four
// deliveries over the week is looked at once afterwards instead of four times.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/week.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/order_complete_tick.dart';

class CombineWeekScreen extends StatefulWidget {
  const CombineWeekScreen({super.key});
  @override
  State<CombineWeekScreen> createState() => _CombineWeekScreenState();
}

class _CombineWeekScreenState extends State<CombineWeekScreen> {
  late DateTime _week;
  late Future<List<Map<String, dynamic>>> _fut;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _week = lastClosedWeekStart();
    _reload();
  }

  void _reload() {
    _fut = Api.groupableOrders(
      weekStartIso: isoDate(_week),
      weekEndIso: isoDate(weekEnd(_week)),
    );
  }

  void _shiftWeek(int weeks) {
    final next = _week.add(Duration(days: 7 * weeks));
    // A week still running cannot be grouped: orders would keep arriving after
    // the combined order was made, and nothing goes back to add them.
    if (!isWeekClosed(next)) return;
    setState(() {
      _week = next;
      _reload();
    });
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  Future<void> _combine(List<Map<String, dynamic>> orders) async {
    final customers = orders.map((o) => '${o['customer']}').toSet().length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close this week?'),
        content: Text(
          '${orders.length} completed ${orders.length == 1 ? 'order' : 'orders'} '
          'from ${weekLabel(_week)} will be grouped into $customers combined '
          '${customers == 1 ? 'order' : 'orders'}, one per customer.\n\n'
          'Everyone will see the combined order against these orders.',
          style: const TextStyle(fontSize: 13.5, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Group them')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final made = await Api.combineWeek(
        weekStartIso: isoDate(_week),
        weekEndIso: isoDate(weekEnd(_week)),
      );
      _snack('Made ${made.length} combined '
          '${made.length == 1 ? 'order' : 'orders'}.');
      setState(_reload);
    } catch (e) {
      // The run is repeatable: anything already grouped is skipped next time,
      // so a half-finished run is fixed by running it again.
      _snack('${humanError(e)} — run it again to finish the rest.');
      setState(_reload);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canGoForward = isWeekClosed(_week.add(const Duration(days: 7)));
    return Scaffold(
      appBar: AppBar(title: const Text('Close the week')),
      body: Column(children: [
        Card(
          margin: const EdgeInsets.all(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(children: [
              IconButton(
                  onPressed: _busy ? null : () => _shiftWeek(-1),
                  icon: const Icon(Icons.chevron_left)),
              Expanded(
                child: Column(children: [
                  Text(weekLabel(_week),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const Text('Monday to Sunday',
                      style: TextStyle(fontSize: 11, color: Colors.black54)),
                ]),
              ),
              IconButton(
                  onPressed: (_busy || !canGoForward)
                      ? null
                      : () => _shiftWeek(1),
                  icon: const Icon(Icons.chevron_right)),
            ]),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _fut,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(child: Text(humanError(snap.error)));
              }
              final orders = snap.data!;
              if (orders.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Nothing left to group for this week.\n\n'
                      'Only completed orders are grouped, and anything already '
                      'grouped is not offered again.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54, height: 1.5),
                    ),
                  ),
                );
              }
              // Shown grouped the way they will be combined, so the manager
              // sees the outcome before agreeing to it rather than after.
              final byCustomer = <String, List<Map<String, dynamic>>>{};
              for (final o in orders) {
                byCustomer
                    .putIfAbsent('${o['customer_name'] ?? o['customer']}', () => [])
                    .add(o);
              }
              final names = byCustomer.keys.toList()..sort();
              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: names.length,
                itemBuilder: (ctx, i) {
                  final rows = byCustomer[names[i]]!;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(names[i],
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            Text(
                                '${rows.length} '
                                '${rows.length == 1 ? 'order' : 'orders'} → 1 combined order',
                                style: const TextStyle(
                                    fontSize: 11.5, color: Colors.black54)),
                            const Divider(height: 16),
                            ...rows.map((o) => Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Row(children: [
                                    OrderCompleteTick(order: o, compact: true),
                                    const SizedBox(width: 8),
                                    Expanded(
                                        child: Text('${o['name']}',
                                            style: const TextStyle(
                                                fontSize: 12))),
                                    Text('${o['transaction_date'] ?? ''}',
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.black54)),
                                    const SizedBox(width: 10),
                                    Text(
                                        'Rs ${(o['grand_total'] ?? 0)}',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600)),
                                  ]),
                                )),
                          ]),
                    ),
                  );
                },
              );
            },
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _fut,
              builder: (context, snap) {
                final orders = snap.data ?? const <Map<String, dynamic>>[];
                return SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: (_busy || orders.isEmpty)
                        ? null
                        : () => _combine(orders),
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.merge_type),
                    label: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(orders.isEmpty
                          ? 'Nothing to group'
                          : 'Group ${orders.length} into combined orders'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ]),
    );
  }
}
