// Which grade a tread-rubber product is: Black Pearl, Platinum, Silver,
// Poly Gold, Diamond.
//
// No field holds it. The item names carry it in two styles — the old
// "TREAD RUBBER PRECURED BLACK PEARL 140 MSR 93" and SAP's own
// "PCTR MANNA DOUBLE BLUE MSR 140 93 (BLACK PEARL)" — and the item group
// often does too ("FG - TRP - Black Pearl"). Spellings are not consistent
// ("POLY GOLD", "POLYGOLD", "POLYCOLD"), so names are compared with spaces
// and punctuation squeezed out.
//
// Used to match an old order's item to today's (core/order_copy.dart) and
// to colour each product on the order screen (23 Nov 2026). A name that
// names no grade, or more than one, has none: a guessed grade would put the
// wrong colour on a product, or copy an order onto the wrong one.

/// Squeezed spelling → the grade's name.
const Map<String, String> kGradeSpellings = {
  'BLACKPEARL': 'BLACK PEARL',
  'PLATINUM': 'PLATINUM',
  'POLYGOLD': 'POLY GOLD',
  'POLYCOLD': 'POLY GOLD',
  'SILVER': 'SILVER',
  'DIAMOND': 'DIAMOND',
  'MEDIUM': 'MEDIUM',
};

String _squeeze(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');

/// Every grade [text] names.
Set<String> gradesIn(String text) {
  final s = _squeeze(text);
  return {
    for (final e in kGradeSpellings.entries)
      if (s.contains(e.key)) e.value,
  };
}

/// The one grade a product is in, from its name, else its item group; null
/// when neither names exactly one.
String? productGrade(String name, [String? itemGroup]) {
  final byName = gradesIn(name);
  if (byName.length == 1) return byName.first;
  if (byName.length > 1) return null;
  final byGroup = gradesIn(itemGroup ?? '');
  return byGroup.length == 1 ? byGroup.first : null;
}
