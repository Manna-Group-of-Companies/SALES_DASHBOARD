// No route, no order.
//
// The route is the one detail an order cannot be taken without. Production is
// never told who a customer is — the route *is* the destination, the only thing
// on the order that says where the goods go. An order raised without one
// reaches the floor with nowhere to send it, and the gap is only noticed at the
// point somebody tries to load a van.
//
// Everything else a lead is missing — GST number, address, payment terms — is
// caught at the manager's approval, because it can still be filled in
// afterwards. A route cannot be treated that way: by the time the order is in
// front of the manager it has already been made, already reserved stock, and
// already reached production as "no route set".

import 'package:flutter/material.dart';

import 'package:manna_field_sales/models/order_ref.dart';

/// Refuses the order and explains why when [party] has no route.
/// Returns true only when a route is set.
Future<bool> ensureRouteSet(BuildContext context, OrderParty party) async {
  if (party.hasRoute) return true;

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(children: const [
        Icon(Icons.alt_route, color: Color(0xFFB3261E)),
        SizedBox(width: 8),
        Expanded(child: Text('Route needed first')),
      ]),
      content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${party.label} is not on a delivery route, so an order cannot '
              'be taken for them yet.',
              style: const TextStyle(fontSize: 13.5, height: 1.4),
            ),
            const SizedBox(height: 10),
            const Text(
              'The route is the only thing the factory is told about where an '
              'order is going. Without it the goods cannot be put on a van.',
              style: TextStyle(fontSize: 12.5, height: 1.4, color: Colors.black54),
            ),
            const SizedBox(height: 10),
            Text(
              party.isLead
                  ? 'Edit the lead and set its route, then take the order.'
                  : 'Set the route on the customer, then take the order.',
              style: const TextStyle(
                  fontSize: 12.5, height: 1.4, fontWeight: FontWeight.w600),
            ),
          ]),
      actions: [
        FilledButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
      ],
    ),
  );
  return false;
}
