// Which order a stock booking is held against.
//
// A rep takes the same order whether the party is a customer or a lead, and it
// draws on the same minimum stock either way — so the booking machinery has to
// work for both. What differs is only where the booking points: a Sales Order
// for a customer, a Lead Order for a lead.
//
// Those are separate doctypes and `Manna Stock Reservation` links to each with
// its own field, so exactly one of `sales_order` / `lead_order` is set on any
// row. This type is what stops that choice being re-derived, and mis-derived,
// at every call site.
//
// When a lead order is approved the lead becomes a customer and a real Sales
// Order is raised. The bookings do not need to be released and re-taken — the
// stock was already held, and letting go of it mid-approval would put it back
// on offer for another rep to take. They are re-pointed instead; see
// `StockService.movePool`.

/// Who an order is being taken for.
///
/// A customer and a lead are the same thing to the order screen: same product
/// families, same rolls-and-belts arithmetic, same minimum stock, same 1 pm
/// edit window. The difference surfaces once — at approval, where a lead has to
/// be complete enough to invoice and gets converted.
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

  /// A booking against an order taken from a lead.
  const OrderRef.lead(String name) : this(name, isLead: true);

  /// The field on `Manna Stock Reservation` that carries this reference.
  String get field => isLead ? 'lead_order' : 'sales_order';

  /// The doctype the order itself lives in.
  String get doctype => isLead ? 'Lead Order' : 'Sales Order';

  /// The filter clause matching reservations held against this order.
  String get filter => '["$field","=","$name"]';

  @override
  bool operator ==(Object other) =>
      other is OrderRef && other.name == name && other.isLead == isLead;

  @override
  int get hashCode => Object.hash(name, isLead);

  @override
  String toString() => name;
}
