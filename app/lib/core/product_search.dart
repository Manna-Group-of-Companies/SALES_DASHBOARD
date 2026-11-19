// How the order screen's search box matches a product.
//
// Two things the user asked for on 19 Nov 2026, which pull against each
// other:
//
//  * "bl 34 12" must show the 34*12 item only — not 134*12, 34*14, 34*120.
//  * However the rep types it, the product must still show: half a number
//    while typing ("13" on the way to 130), no spaces ("3412", "bp130"),
//    "34x12", "34*12", capitals, a short form for the grade.
//
// So the search is tried at three levels, strictest first, and the screen
// shows only the products found at the strictest level that found anything
// ([productSearchLevel]). A precise search gets the precise answer; a loose
// one still gets something rather than an empty screen.
//
//  0. Exact: a number matches a whole number in the name; letters match the
//     start of a word, or stand for a grade through the short forms below.
//  1. Loose: a number matches anywhere inside a number ("13" → 130, 113);
//     letters match anywhere in the name.
//  2. Squashed: the whole search, spaces and symbols dropped, is somewhere
//     in the name with its spaces and symbols dropped ("3412" → 34*12).
//
// The name and the search are both cut into runs of letters and runs of
// digits, so "34*12", "34 X 12", "34x12" and "130VK" all read the same way.

/// Short form → what it stands for, lower case. A grade spelt more than one
/// way in the item master gets every spelling: "POLYCOLD" is how some
/// Poly Gold items were imported. Add a grade here when the reps start using
/// a new abbreviation.
const Map<String, List<String>> kSearchShortForms = {
  'pl': ['platinum'],
  'bp': ['black pearl'],
  'bg': ['bonding gum'],
  'si': ['silver'],
  'md': ['medium'],
  'pg': ['poly gold', 'polycold'],
  'dm': ['diamond'],
};

final RegExp _runs = RegExp(r'[a-z]+|\d+');
final RegExp _digits = RegExp(r'^\d+$');
final RegExp _notAlnum = RegExp(r'[^a-z0-9]');

List<String> _runsOf(String s) =>
    _runs.allMatches(s.toLowerCase()).map((m) => m.group(0)!).toList();

/// The search as words. The "x" in "34x12" / "34 x 12" is the size's
/// separator, not a word to look for, and is dropped.
List<String> _queryWords(String query) {
  final r = _runsOf(query);
  return [
    for (var i = 0; i < r.length; i++)
      if (!(r[i] == 'x' &&
          i > 0 &&
          i < r.length - 1 &&
          _digits.hasMatch(r[i - 1]) &&
          _digits.hasMatch(r[i + 1])))
        r[i],
  ];
}

/// The strictest level (0, 1 or 2) at which [query] finds this product, or
/// null when it does not find it at all. An empty search finds everything at
/// level 0.
int? productSearchLevel(String query, String name, String code) {
  final hay = '$name $code'.toLowerCase();
  final runs = _runsOf(hay);
  final squashed = hay.replaceAll(_notAlnum, '');
  final words = _queryWords(query);
  if (words.isEmpty) return 0;

  bool shortForm(String w) =>
      kSearchShortForms[w]
          ?.any((l) => squashed.contains(l.replaceAll(' ', ''))) ??
      false;

  final exact = words.every((w) => _digits.hasMatch(w)
      ? runs.contains(w)
      : (runs.any((r) => r.startsWith(w)) || shortForm(w)));
  if (exact) return 0;

  final loose = words.every((w) => _digits.hasMatch(w)
      ? runs.any((r) => _digits.hasMatch(r) && r.contains(w))
      : (squashed.contains(w) || shortForm(w)));
  if (loose) return 1;

  if (squashed.contains(words.join())) return 2;
  return null;
}

/// True when [query] finds this product at any level.
bool productMatchesSearch(String query, String name, String code) =>
    productSearchLevel(query, name, code) != null;
