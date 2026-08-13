// Pulling the quality and the pattern out of an item's name.
//
// Neither is recorded anywhere. There is no quality field, no pattern field,
// `brand` is null on all 1,092 items and no Brand records exist — so the only
// place this information lives is inside the name itself:
//
//     TREAD RUBBER PRECURED  BLACK PEARL  130  VK  90
//     └─ prefix ───────────┘ └ quality ─┘ └w┘ └p┘ └d┘
//
// Reading a name to get at data is normally a bad trade. It is made here on the
// grounds that the alternative — two new Item fields and 1,092 rows to fill in
// by hand — is not going to happen soon, and a production manager needs to be
// able to say "show me the VK patterns" today.
//
// It is a *filter*, and nothing is priced or booked from it. When a name does
// not parse, the item keeps its place in the list with a blank quality and
// pattern rather than disappearing, so a naming style nobody anticipated costs
// visibility in a dropdown and never a row on the screen.
//
// Verified against every item in the master: all 164 minimum-stock items parse,
// and the only 16 that yield nothing are Bonding Gum, Compounded Rubber and the
// like, which carry no pattern to find.

/// Prefixes that describe the product family rather than the item, longest
/// first so the more specific one wins.
const List<String> _prefixes = [
  'TREAD RUBBER PRECURED ',
  'TREAD RUBBER HOT ',
  'TREAD RUBBER ',
  'PRECURED ',
  'PCTR ',
];

/// The quality and pattern read off an item name. Either may be blank.
class ItemNameParts {
  /// The grade — `BLACK PEARL`, `PLATINUM`, `SILVER`, `TRACTOR GOLD`…
  final String quality;

  /// The tread pattern — `VK`, `RTS`, `PM`, `AJAX`, `TVS`…
  final String pattern;

  const ItemNameParts({this.quality = '', this.pattern = ''});

  bool get isEmpty => quality.isEmpty && pattern.isEmpty;
}

/// Reads the quality and pattern out of [raw].
///
/// The width is the anchor: the first standalone number in the name. Whatever
/// precedes it is the quality, and the token straight after it is the pattern.
/// That holds because every name is written grade-then-size-then-pattern, and
/// it does not depend on knowing the list of grades or patterns in advance —
/// which matters, because new ones are added without anyone being told.
ItemNameParts parseItemName(String raw) {
  // Some names carry mojibake from an earlier import ("93Â€"). Anything that is
  // not a letter, digit or ordinary separator becomes a space rather than
  // being glued onto the token beside it.
  var s = raw.toUpperCase().replaceAll(RegExp(r'''[^A-Z0-9 .'"/-]'''), ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

  for (final p in _prefixes) {
    if (s.startsWith(p)) {
      s = s.substring(p.length).trim();
      break;
    }
  }

  final tokens = s.split(' ').where((t) => t.isNotEmpty).toList();
  final isNumber = RegExp(r'^\d+$');
  final width = tokens.indexWhere((t) => isNumber.hasMatch(t));
  if (width < 0) return const ItemNameParts();

  final quality = tokens.take(width).join(' ');
  // A name that opens with its width has no quality in it, but still has a
  // pattern worth finding — so this is not treated as a failure to parse.
  final next = width + 1;
  final pattern = (next < tokens.length && !isNumber.hasMatch(tokens[next]))
      ? tokens[next]
      : '';

  return ItemNameParts(quality: quality, pattern: pattern);
}

/// Every distinct quality across [names], sorted, blanks dropped.
List<String> qualitiesIn(Iterable<String> names) => _distinct(
    names.map((n) => parseItemName(n).quality));

/// Every distinct pattern across [names], sorted, blanks dropped.
List<String> patternsIn(Iterable<String> names) =>
    _distinct(names.map((n) => parseItemName(n).pattern));

List<String> _distinct(Iterable<String> values) {
  final set = values.where((v) => v.isNotEmpty).toSet().toList();
  set.sort();
  return set;
}
