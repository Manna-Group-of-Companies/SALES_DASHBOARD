// Which customers, leads and routes a rep may see.
//
// Paired with `client/src/domain/visibility.ts`. Both read
// `shared/fixtures/visibility.json` in their tests. See `shared/README.md`.
//
// Everywhere in this business a customer belongs to one rep and only that rep
// works it. The UAE unit is the exception, and it is a real operational one:
// four reps and a manager cover a whole country between them, and when one
// takes leave another has to serve their customers that week. Waiting for an
// administrator to reassign 200 records — and to put them back afterwards — is
// not a thing that happens on the morning somebody calls in sick.
//
// So for a pooled unit, visibility is the unit; everywhere else it stays the
// individual.
//
// Pooling widens visibility ONLY. It does not change ownership. Every customer,
// lead and route still names one rep, because the business still needs to know
// whose it is — for the route plan, for accountability, and so a screen can say
// who is being covered for. A UAE list that did not show the owner would turn a
// shared pool into nobody's responsibility.
//
// It fails closed. A login that matches no Sales Person, or a rep with no unit
// recorded, sees nothing rather than everything.

import 'package:manna_field_sales/core/constants.dart';

const String kFieldUnit = 'custom_company';
const String kFieldCustomerOwner = 'custom_assigned_reps';
const String kFieldLeadOwner = 'custom_sales_person';
const String kFieldRouteOwner = 'sales_person';

/// Units whose reps share their customers, leads and routes.
///
/// A list rather than a flag on the unit, because there is no `Business Unit`
/// doctype to hang a flag on — the unit is a plain Data value on Sales Person.
/// Adding one here is a deliberate act; an unrecognised unit is never pooled.
const List<String> kPooledUnits = [kUnitUae];

bool isPooledUnit(String? unit) => kPooledUnits.contains((unit ?? '').trim());

/// One Sales Person, as the visibility rule needs them.
class VisPerson {
  final String name;
  final String? unit;
  final bool enabled;
  final bool isGroup;

  const VisPerson({
    required this.name,
    this.unit,
    this.enabled = true,
    this.isGroup = false,
  });

  factory VisPerson.fromRow(Map<String, dynamic> r) => VisPerson(
        name: '${r['name'] ?? ''}',
        unit: r[kFieldUnit] == null ? null : '${r[kFieldUnit]}',
        enabled: '${r['enabled'] ?? 1}' != '0',
        isGroup: '${r['is_group'] ?? 0}' == '1',
      );

  bool get usable => enabled && !isGroup;
}

/// The reps whose records this person may see.
///
/// Returns an empty list — never "everyone" — when the person cannot be
/// resolved. Callers must treat empty as "show nothing"; handing the API no
/// filter at all is read as every customer in the company.
List<String> visibleReps(List<VisPerson> people, String? personId) {
  VisPerson? me;
  for (final p in people) {
    if (p.name == personId) {
      me = p;
      break;
    }
  }
  // A growable list, not `const []`: callers sort and filter what they get
  // back, and an unmodifiable empty list turns "nothing to show" into a crash.
  if (me == null || !me.usable) return <String>[];

  final unit = (me.unit ?? '').trim();
  if (unit.isEmpty || !isPooledUnit(unit)) return [me.name];

  return people
      .where((p) => p.usable && (p.unit ?? '').trim() == unit)
      .map((p) => p.name)
      .toList();
}

/// Whether this person's records are shared with colleagues.
bool sharesWithUnit(List<VisPerson> people, String? personId) =>
    visibleReps(people, personId).length > 1;

/// The owner-field VALUES a customer or lead may hold for this person to see
/// it — [visibleReps] plus, in a pooled unit only, an unassigned record.
///
/// Outside a pool, an unowned record has nobody to route it to and stays
/// invisible until someone claims it — that is unchanged. Inside a pool the
/// business wants the opposite: a batch of customers/leads imported for the
/// UAE unit lands with no owner, and the whole team must see them
/// immediately rather than have them sit dark until somebody opens Desk. So
/// a pooled unit's filter additionally matches an empty owner field.
///
/// `[]` still means "show nothing" — unresolvable is unresolvable whether or
/// not the unit is pooled.
List<String> visibleOwnerValues(List<VisPerson> people, String? personId) {
  final reps = visibleReps(people, personId);
  if (reps.isEmpty) return <String>[];
  VisPerson? me;
  for (final p in people) {
    if (p.name == personId) {
      me = p;
      break;
    }
  }
  return isPooledUnit(me?.unit) ? [...reps, ''] : reps;
}

/// Whether this person may set or change who a customer or lead belongs to.
///
/// Restricted to a pooled unit deliberately: everywhere else a customer
/// belongs to the one rep who has always owned it, and reassignment is not a
/// decision the app hands out — it would let one rep quietly take another's
/// customer. A pooled unit is different because the business already treats
/// ownership there as a team-level fact, not a personal one.
bool canAssignOwner(List<VisPerson> people, String? personId) {
  VisPerson? me;
  for (final p in people) {
    if (p.name == personId) {
      me = p;
      break;
    }
  }
  if (me == null || !me.usable) return false;
  return isPooledUnit(me.unit);
}

/// Whether a record this person can see is actually somebody else's.
///
/// Drives the "covering for X" marker. Only meaningful in a pooled unit, where
/// seeing a record and owning it are different things for the first time.
bool isCoveringFor(
  List<VisPerson> people,
  String? personId,
  String? ownerId,
) {
  if (ownerId == null || ownerId.isEmpty || ownerId == personId) return false;
  return visibleReps(people, personId).contains(ownerId);
}

const String kPooledUnitNote =
    'Everyone in this unit shares its customers, leads and routes, so any of '
    'you can serve any of them while a colleague is away. Each one still has '
    'an owner, shown on the row.';
