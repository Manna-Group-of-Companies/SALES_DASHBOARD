// Choosing a sales route.
//
// Three things carry a route now — a customer, a lead, and every site captured
// against either — and production plans deliveries from whichever one applies.
// They all pick from the same list, in the same way, so this is one widget
// rather than three that drift apart.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';

/// Loads the routes this rep can offer, once, and hands back a sorted list.
///
/// Routes are named per rep ("Jaimon D - Adoor"), so a rep sees their own. They
/// are still being created, though, and a rep with none yet would be shown an
/// empty dropdown and be unable to set a route at all — so in that case every
/// active route is offered instead.
Future<List<String>> loadSalesRoutes({String? current}) async {
  var routes = await Api.getSalesRoutes(forRep: Session.I.salesPerson);
  // Something already sitting on a route this rep is not offered must not
  // silently lose it just because the dropdown cannot show it.
  if (current != null &&
      current.isNotEmpty &&
      current != 'null' &&
      !routes.contains(current)) {
    routes = [current, ...routes];
  }
  return routes;
}

class SalesRouteField extends StatelessWidget {
  final String? value;
  final List<String> routes;
  final ValueChanged<String?> onChanged;
  final bool enabled;
  final String label;

  /// Shown under the field when nothing is selected. The absence of a route is
  /// worth saying out loud — production cannot plan a delivery without one.
  final String? emptyHint;

  const SalesRouteField({
    super.key,
    required this.value,
    required this.routes,
    required this.onChanged,
    this.enabled = true,
    this.label = 'Sales route',
    this.emptyHint,
  });

  @override
  Widget build(BuildContext context) {
    final noneExist = routes.isEmpty;
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
        helperText: noneExist
            ? 'No sales routes exist yet — ask the office to create them'
            : (value == null ? emptyHint : null),
        helperMaxLines: 2,
      ),
      items: [
        for (final r in routes) DropdownMenuItem(value: r, child: Text(r))
      ],
      onChanged: enabled && !noneExist ? onChanged : null,
    );
  }
}

/// A compact one-line route display with a tap-to-change affordance, for rows
/// in a list where a full form field would be too heavy.
class RouteChip extends StatelessWidget {
  final String? route;
  final VoidCallback? onTap;
  const RouteChip({super.key, required this.route, this.onTap});

  @override
  Widget build(BuildContext context) {
    final set = route != null && route!.isNotEmpty && route != 'null';
    final colour = set ? Colors.blue.shade700 : Colors.orange.shade800;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.route, size: 13, color: colour),
          const SizedBox(width: 4),
          Flexible(
            child: Text(set ? route! : 'No route set',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    color: colour,
                    fontWeight: set ? FontWeight.w500 : FontWeight.bold)),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.edit, size: 11, color: colour),
          ],
        ]),
      ),
    );
  }
}

/// Asks for a route in a dialog. Used where there is no room for a form —
/// changing the route on one site in a list, for instance.
Future<String?> pickSalesRoute(
  BuildContext context, {
  String? current,
  String title = 'Set route',
}) async {
  final routes = await loadSalesRoutes(current: current);
  if (!context.mounted) return null;
  if (routes.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'No sales routes exist yet — ask the office to create them.')));
    return null;
  }
  return showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(title),
      children: [
        for (final r in routes)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, r),
            child: Row(children: [
              Icon(
                  r == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 16,
                  color: r == current ? Colors.blue.shade700 : Colors.black38),
              const SizedBox(width: 8),
              Expanded(child: Text(r)),
            ]),
          ),
      ],
    ),
  );
}
