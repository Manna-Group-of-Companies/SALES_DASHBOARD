// Which parts of the manager workspace a sales manager may open.
//
// Not every team runs the same way. Pareeth's team raises the orders, so that
// manager needs the whole order pipeline. Saneesh and Renjith are asked, for
// now, to work the party records and their own people — customers, leads,
// location checks and attendance corrections — and nothing else.
//
// Until 11 October 2026 the phone offered every manager everything while the
// dashboard offered this, so a manager could approve on the phone an order the
// dashboard would not show them. Both read `shared/fixtures/manager_scope.json`
// now; the TypeScript twin is `screensFor` in `client/src/domain/sales.ts`.

enum ManagerScreen { customers, leads, locations, regularizations, orders, stock }

const List<ManagerScreen> _full = ManagerScreen.values;

const List<ManagerScreen> _partyOnly = [
  ManagerScreen.customers,
  ManagerScreen.leads,
  ManagerScreen.locations,
  ManagerScreen.regularizations,
];

/// Keyed by the team token on `Sales Person.custom_team_manager`.
const Map<String, List<ManagerScreen>> _byTeam = {
  'Pareeth': _full,
  'Saneesh': _partyOnly,
  'Renjith': _partyOnly,
};

/// What a manager of [managedTeam] may open.
///
/// An unrecognised team gets the reduced set, not the full one: a new manager
/// must not silently inherit the order pipeline because nobody remembered to
/// add them here. The token is matched exactly — it is a stored value, and a
/// loose match would be a permission granted by a typo.
List<ManagerScreen> screensFor(String? managedTeam) {
  final token = (managedTeam ?? '').trim();
  if (token.isEmpty) return const [];
  return _byTeam[token] ?? _partyOnly;
}

/// As [screensFor], from the role as well. The GM's work is the escalation
/// queue, so no team screen is theirs whatever token they carry.
List<ManagerScreen> screensForUser(
    {required bool isGM, required String? managedTeam}) {
  if (isGM) return const [];
  return screensFor(managedTeam);
}

bool canOpenAs(
        {required bool isGM,
        required String? managedTeam,
        required ManagerScreen screen}) =>
    screensForUser(isGM: isGM, managedTeam: managedTeam).contains(screen);
