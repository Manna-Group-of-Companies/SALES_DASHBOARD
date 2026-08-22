// Whether an order repeats products the customer already has on order.
//
// WHY THIS EXISTS
//
// A rep takes an order in a shop, the phone loses signal or they navigate away,
// and they take it again. Two orders go in for the same rolls, and nothing
// notices until the customer is delivered twice or the second one is cancelled
// by hand. Asked for on 21 August 2026.
//
// WHAT COUNTS
//
// Only the customer's own **open** orders — not dispatched, not cancelled. A
// customer who buys the same tread every month is not making a mistake, and
// warning on their history would train reps to dismiss the thing blind, which
// is the failure mode that makes a warning worse than none.
//
// WHERE IT RUNS
//
// At **save** time, not at read time. `Sales Order Item` cannot be listed
// directly on this site — it answers 403, see app/CLAUDE.md section 4 — so
// there is no way to ask "which open orders contain this item". The app works
// it out while it still holds the order's lines, and stores the answer on
// `custom_duplicate_of`. My Orders then reads a field instead of fetching a
// document per row on a phone.
//
// It is a **warning, never a refusal**. A rep genuinely may want two open
// orders for the same product, and the one thing this must not do is stand
// between them and a customer. Dismissing it writes `custom_duplicate_ignored`
// on the order, so it stays dismissed on every device and after a reinstall.
//
// The rule is pinned by `shared/fixtures/duplicate_order.json`.

/// An overlap worth telling the rep about.
class DuplicateFinding {
  /// The other open order that shares products with this one.
  final String order;

  /// The products both carry, in a stable order.
  final List<String> items;

  const DuplicateFinding({required this.order, required this.items});
}

/// An unset Frappe value reads back as `null`, `''` or the string `'null'`.
/// None of those is a product.
String _code(String raw) {
  final s = raw.trim();
  return (s.isEmpty || s == 'null') ? '' : s;
}

Set<String> _codes(Iterable<String> raw) =>
    raw.map(_code).where((c) => c.isNotEmpty).toSet();

/// Which of [otherOpenOrders] this order repeats, if any.
///
/// [mine] is this order's item codes. [otherOpenOrders] maps another open
/// order's name to its item codes, and must already exclude this order and
/// anything dispatched or cancelled — deciding what "open" means belongs to
/// the caller, which is the only part that needs the network.
///
/// Returns null when nothing overlaps. When several orders overlap, the one
/// sharing the most products wins; ties break on the order name so the warning
/// reads identically every time the same data is loaded.
DuplicateFinding? findDuplicate({
  required List<String> mine,
  required Map<String, List<String>> otherOpenOrders,
}) {
  final want = _codes(mine);
  if (want.isEmpty) return null;

  DuplicateFinding? best;
  // Sorted so an equal overlap always resolves the same way round.
  final names = otherOpenOrders.keys.toList()..sort();

  for (final name in names) {
    final shared = _codes(otherOpenOrders[name] ?? const []).intersection(want);
    if (shared.isEmpty) continue;
    if (best == null || shared.length > best.items.length) {
      best = DuplicateFinding(
        order: name,
        items: shared.toList()..sort(),
      );
    }
  }
  return best;
}

/// What the rep is shown. Kept beside the rule so the two cannot disagree
/// about how many products "products" is.
String duplicateWarningText(DuplicateFinding f) {
  final n = f.items.length;
  final what = n == 1 ? '${f.items.first}' : '$n products';
  return 'Possible duplicate: $what already on ${f.order}, which has not been '
      'dispatched yet.';
}
