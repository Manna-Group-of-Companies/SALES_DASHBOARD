
import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/screens/leads/lead_order_detail_screen.dart';
import 'package:manna_field_sales/screens/orders/combined_order_screen.dart';
import 'package:manna_field_sales/screens/orders/order_detail_screen.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/sap_order_state.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/history_list.dart';
import 'package:manna_field_sales/widgets/order_complete_tick.dart';

class MyOrdersScreen extends StatelessWidget {
  const MyOrdersScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return HistoryList(
      title: 'My Orders',
      loader: Api.getMyOrders,
      cacheKey: CacheKeys.orders,
      tileBuilder: (ctx, r, _) {
        // A combined order arrives as one row standing for all of its orders.
        // Its members are not listed separately — see Api.getMyOrders — so the
        // same money is never counted twice down the screen.
        if (r['is_combined'] == true) {
          final count = (r['order_count'] ?? 0);

          // What made the group. Since 20 Aug 2026 that is a dispatch: the
          // customer's orders that went out on one van are one delivery to
          // them, and the van and the day are what they will ring about.
          // Groups made by the old "Close the week" carry a week instead, and
          // still have to read properly — they are what is already on phones.
          final vehicle = '${r['vehicle'] ?? ''}'.trim();
          final dispatchDate = '${r['dispatch_date'] ?? ''}'.trim();
          final String origin;
          if (dispatchDate.isNotEmpty && dispatchDate != 'null') {
            origin = vehicle.isEmpty || vehicle == 'null'
                ? 'dispatched $dispatchDate'
                : 'dispatched $dispatchDate  ·  vehicle $vehicle';
          } else {
            origin = 'week ${r['week_start'] ?? ''} to ${r['week_end'] ?? ''}';
          }

          return ListTile(
            leading: const Icon(Icons.merge_type, color: Color(0xFF6D4C41)),
            title: Text('${r['customer'] ?? r['name']}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
                '${r['name']}  ·  $origin'
                '\n$count ${count == 1 ? 'order' : 'orders'} combined  ·  '
                'Rs ${r['grand_total'] ?? 0}'),
            isThreeLine: true,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => CombinedOrderScreen(combined: r))),
          );
        }

        final isLead = r['is_lead'] == true;
        // Set once the production manager has closed the week this order fell
        // in. The rep sees it so that a customer asking about "last week's
        // order" and the office looking at one combined document are talking
        // about the same thing.
        final combinedRaw = '${r['custom_combined_order'] ?? ''}'.trim();
        final combined =
            (combinedRaw.isEmpty || combinedRaw == 'null') ? '' : combinedRaw;
        final dd = '${r['delivery_date'] ?? ''}';
        final ddText =
            (dd.isNotEmpty && dd != 'null') ? '  ·  Required by: $dd' : '';

        // A lead order has no proforma and no production status — it is not a
        // Sales Order until the manager approves and the lead converts — so it
        // carries its own single status line rather than empty columns.
        final String statusLine;
        if (isLead) {
          statusLine = 'Lead order  ·  ${r['status'] ?? ''}';
        } else {
          final po = '${r['custom_po_status'] ?? '—'}';
          final approved = po == 'PO Approved - Ready for SAP';
          /*
           * Once approved, the floor is SAP's to report.
           *
           * The stage and the delivery come from SAP and the status is derived
           * from them in core/sap_order_state.dart, so an order that has
           * shipped says so even if the production record behind it is stale.
           * Where SAP has said nothing yet, the ERPNext field is used, which
           * is what every order placed before 11 September 2026 has.
           */
          final sap = SapOrderState.fromOrder(r);
          final prod = reachedSap(sap)
              ? productionStatusFromSap(sap)
              : '${r['custom_production_status'] ?? ''}';
          final fin = '${r['custom_production_finish_date'] ?? ''}';
          statusLine = 'Proforma: ${r['custom_proforma_status'] ?? '—'}  ·  '
              '${approved ? 'Production: ${prod.isEmpty ? 'Not Started' : prod}'
                  '${(fin.isNotEmpty && fin != 'null') ? '  ·  est. finish $fin' : ''}' : approvalLabel(po)}';
        }

        /*
         * A possible duplicate of another open order for the same customer.
         * Worked out when the order was saved and stored on it — see
         * core/duplicate_order.dart for why it is not computed here.
         *
         * A warning and never a block: a rep may genuinely want two open
         * orders for the same product. Dismissing writes to the order, so it
         * stays dismissed on every device.
         */
        final dupOf = '${r['custom_duplicate_of'] ?? ''}'.trim();
        final dupIgnored = '${r['custom_duplicate_ignored'] ?? 0}' == '1';
        final showDup =
            !isLead && dupOf.isNotEmpty && dupOf != 'null' && !dupIgnored;

        /*
         * What SAP knows, said in one line under the order.
         *
         * A rep's two questions are "did it reach the factory" and "when does
         * it come". Once a delivery exists this leads with it, because the
         * delivery date is the answer they repeat to a customer.
         *
         * Null when SAP has said nothing, so nothing is drawn rather than an
         * empty row — an order waiting to be picked up looks the same as one
         * that failed to push, and only the error below distinguishes them.
         */
        final sapLine = isLead ? null : sapSummary(SapOrderState.fromOrder(r));
        final sapErr =
            isLead ? '' : '${r['custom_sap_sync_error'] ?? ''}'.trim();

        final tile = ListTile(
          leading: Icon(isLead ? Icons.emoji_objects : Icons.shopping_cart,
              color: isLead ? const Color(0xFF5C6BC0) : null),
          title: Row(children: [
            Expanded(child: Text(r['customer'] ?? r['name'])),
            // A lead order is not a Sales Order yet, so it has no production
            // status to tick — showing an empty box against one would read as
            // "not finished" rather than "not applicable".
            if (!isLead) OrderCompleteTick(order: r, compact: true),
          ]),
          subtitle: Text('${r['transaction_date'] ?? ''}$ddText\n$statusLine'
              '${combined.isEmpty ? '' : '\nWeek order: $combined'}'
              // The delivery is what a rep repeats to a customer, so it gets
              // its own line rather than being run into the status.
              '${sapLine == null ? '' : '\n$sapLine'}'
              // A failed push reads exactly like an order not yet picked up.
              // Saying which is the whole point of keeping the error.
              '${sapErr.isEmpty ? '' : '\nSAP: $sapErr'}'),
          isThreeLine: true,
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            if (isLead) {
              Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => LeadOrderDetailScreen(
                        orderName: r['name'] as String,
                        lead: {
                          'name': r['lead'],
                          'lead_name': r['lead_name'],
                        },
                      )));
              return;
            }
            Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) =>
                    OrderDetailScreen(orderName: r['name'] as String)));
          },
        );

        if (!showDup) return tile;
        return Column(mainAxisSize: MainAxisSize.min, children: [
          tile,
          _DuplicateWarning(orderName: '${r['name']}', duplicateOf: dupOf),
        ]);
      },
    );
  }
}

/// The duplicate banner under an order row, with the way to make it go away.
///
/// Its own widget because dismissing has to redraw just this row — rebuilding
/// the whole list would scroll a rep back to the top mid-round.
class _DuplicateWarning extends StatefulWidget {
  final String orderName;
  final String duplicateOf;
  const _DuplicateWarning({required this.orderName, required this.duplicateOf});

  @override
  State<_DuplicateWarning> createState() => _DuplicateWarningState();
}

class _DuplicateWarningState extends State<_DuplicateWarning> {
  bool _gone = false;
  bool _busy = false;

  Future<void> _ignore() async {
    setState(() => _busy = true);
    try {
      await Api.ignoreDuplicate(widget.orderName);
      if (mounted) setState(() => _gone = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(humanError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFFCC80)),
      ),
      child: Row(children: [
        Icon(Icons.copy_all_outlined, size: 18, color: Colors.orange.shade900),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Possible duplicate — products here are also on '
            '${widget.duplicateOf}, which has not been dispatched yet.',
            style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
          ),
        ),
        TextButton(
          onPressed: _busy ? null : _ignore,
          child: const Text('Ignore'),
        ),
      ]),
    );
  }
}

