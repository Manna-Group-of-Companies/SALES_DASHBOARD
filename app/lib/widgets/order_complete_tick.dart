// Whether an order is finished, said the same way to everyone.
//
// The rep, the sales manager, the production manager and accounts all need the
// same answer to "is this one done", and the fastest way for them to disagree
// is for each screen to work it out for itself. One widget, one rule: an order
// is complete when every line on it has been dispatched.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/production_stages.dart';
import 'package:manna_field_sales/core/sap_order_state.dart';
import 'package:manna_field_sales/services/api.dart';

class OrderCompleteTick extends StatelessWidget {
  /// The order as read from the backend. Only order-level fields are used —
  /// the rolled-up production status and `custom_sap_sales_order` /
  /// `custom_sap_invoice` — so this works on a list row without the lines.
  final Map<String, dynamic> order;

  /// Compact drops the word and leaves the tick, for dense list rows.
  final bool compact;

  const OrderCompleteTick(
      {super.key, required this.order, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final done = Api.isOrderComplete(order);
    // SAP's word once SAP has the order (Pushed to SAP / Dispatched), the
    // in-app status before — the rule isOrderComplete applies, so the word
    // and the tick cannot disagree. Needs the order's SAP fields fetched.
    final status = orderProgress(
        SapOrderState.fromOrder(order), order['custom_production_status']);

    final colour = done
        ? const Color(0xFF1B7F3B)
        : (status == 'Ready' ? const Color(0xFF8A6100) : Colors.black45);
    final icon = done
        ? Icons.check_box
        : (status.isEmpty || status == kStageNotStarted
            ? Icons.check_box_outline_blank
            : Icons.indeterminate_check_box_outlined);

    if (compact) {
      return Tooltip(
        message: done ? 'Complete' : (status.isEmpty ? 'Not started' : status),
        child: Icon(icon, size: 18, color: colour),
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18, color: colour),
      const SizedBox(width: 6),
      Text(
        // Named rather than just ticked or not: "Ready" and "In Production" are
        // both "not complete", and a rep chasing an order needs to know which.
        done ? 'Complete' : (status.isEmpty ? kStageNotStarted : status),
        style: TextStyle(
            fontSize: 12,
            fontWeight: done ? FontWeight.w700 : FontWeight.w600,
            color: colour),
      ),
    ]);
  }
}
