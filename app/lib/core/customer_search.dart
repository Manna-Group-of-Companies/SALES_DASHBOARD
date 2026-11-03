// Finding one customer among six hundred.
//
// The search used to rebuild every row's lowercase text on every keystroke,
// and did it twice per frame — once to count the rows for the header, once
// to draw them. Nothing on a desktop; on the phones in the field it was a
// visible pause between typing a letter and the list moving. The text is
// built once per row when the list loads, and the query is lowered once per
// change, so a keystroke is one string scan per row and nothing else.

/// The text a customer can be found by: name, ERP id, group and route.
/// Built once per row, when the list loads.
String customerHaystack(Map<String, dynamic> c) => [
      c['customer_name'],
      c['name'],
      c['customer_group'],
      c['custom_sales_route'],
    ].map((e) => '${e ?? ''}'.toLowerCase()).join(' ');

/// What the rep has asked to see.
class CustomerFilter {
  final String _query;

  /// A sales route, or null for every route.
  final String? route;

  CustomerFilter({String query = '', this.route})
      : _query = query.trim().toLowerCase();

  /// Whether [c] belongs in the list. [haystack] is [customerHaystack] of
  /// [c], prebuilt by the caller.
  bool matches(Map<String, dynamic> c, String haystack) {
    if (route != null && '${c['custom_sales_route'] ?? ''}' != route) {
      return false;
    }
    if (_query.isEmpty) return true;
    return haystack.contains(_query);
  }
}
