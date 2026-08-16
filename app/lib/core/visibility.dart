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
