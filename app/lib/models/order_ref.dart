// Which order a document points at — a Sales Order, or a Lead Order.
//
// A rep takes the same order whether the party is a customer or a lead, so
// everything downstream has to work for both. What differs is only which
// doctype the order actually lives in.
//
// This type is what stops that choice being re-derived, and mis-derived, at
// every call site.

/// Who an order is being taken for.
///
/// A customer and a lead are the same thing to the order screen: same product
/// families, same rolls-and-belts arithmetic, same stock, same 1 pm edit
/// window. The difference surfaces once — at approval, where a lead has to be
/// complete enough to invoice and gets converted.
///
/// Wrapping the two here is what keeps that difference from leaking into every
/// widget as a null check on `customer_name`.
class OrderParty {
  final Map<String, dynamic> doc;
  final bool isLead;

  const OrderParty(this.doc, {this.isLead = false});

  factory OrderParty.customer(Map<String, dynamic> c) => OrderParty(c);
  factory OrderParty.lead(Map<String, dynamic> l) =>
      OrderParty(l, isLead: true);

  String get name => '${doc['name'] ?? ''}';

  /// What to put at the top of the order screen.
  String get label {
    if (!isLead) return '${doc['customer_name'] ?? doc['name'] ?? ''}';
    final company = '${doc['company_name'] ?? ''}'.trim();
    if (company.isNotEmpty && company != 'null') return company;
    return '${doc['lead_name'] ?? doc['name'] ?? ''}';
  }

  /// Shown beside the name so a rep is never unsure which they are ordering
  /// for — the approval path differs, and they should know that before they
  /// start rather than when it is refused.
  String get kindLabel => isLead ? 'Lead' : 'Customer';

  /// The delivery route this party sits on, blank when none is set.
  String get salesRoute {
    final r = '${doc['custom_sales_route'] ?? ''}'.trim();
    return (r.isEmpty || r == 'null') ? '' : r;
  }

  /// An order cannot be taken without one.
  ///
  /// The route is the only thing production is given about where an order is
  /// going — they never receive the customer's name. Without it the order
  /// reaches the floor with nowhere to send it, and nobody downstream can put
  /// it on a van. Everything else about a lead can be filled in later and is
  /// caught at the manager's approval; this cannot, because by then the order
  /// has already been made.
  bool get hasRoute => salesRoute.isNotEmpty;
}

class OrderRef {
  /// The document name — `SAL-ORD-2026-00123` or `LO-00042`.
  final String name;

  /// True when this is a Lead Order rather than a Sales Order.
  final bool isLead;

  const OrderRef(this.name, {this.isLead = false});

  /// An order taken from a lead.
  const OrderRef.lead(String name) : this(name, isLead: true);

  /// The doctype the order itself lives in.
  String get doctype => isLead ? 'Lead Order' : 'Sales Order';

  @override
  bool operator ==(Object other) =>
      other is OrderRef && other.name == name && other.isLead == isLead;

  @override
  int get hashCode => Object.hash(name, isLead);

  @override
  String toString() => name;
}
