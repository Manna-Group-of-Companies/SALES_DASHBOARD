/**
 * Which customers, leads and routes a rep may see.
 *
 * **Paired with `app/lib/core/visibility.dart`.** Both read
 * `shared/fixtures/visibility.json` in their tests. See `shared/README.md`.
 *
 * Everywhere in this business a customer belongs to one rep and only that rep
 * works it. The UAE unit is the exception, and it is a real operational one:
 * four reps and a manager cover a whole country between them, and when one
 * takes leave another has to serve their customers that week. Waiting for an
 * administrator to reassign 200 records — and to put them back afterwards — is
 * not a thing that happens on the morning somebody calls in sick.
 *
 * So for a **pooled unit**, visibility is the unit; everywhere else it stays
 * the individual.
 *
 * **Pooling widens visibility only. It does not change ownership.** Every
 * customer, lead and route still names one rep, because the business still
 * needs to know whose it is — for the route plan, for accountability, and so a
 * screen can say who is being covered for. A UAE list that did not show the
 * owner would turn a shared pool into nobody's responsibility.
 *
 * **It fails closed.** A login that matches no Sales Person, or a rep with no
 * unit recorded, sees nothing rather than everything. The failure that costs
 * least is the one where somebody asks why a list is empty.
 */

/** A Sales Person row, as either app reads it. */
export interface Person {
  name: string;
  unit?: string | null;
  enabled?: boolean;
  isGroup?: boolean;
}

export const VISIBILITY_FIELD = {
  unit: 'custom_company',
  customerOwner: 'custom_assigned_reps',
  leadOwner: 'custom_sales_person',
  routeOwner: 'sales_person',
  /**
   * The route a customer or lead sits on. Both doctypes spell it the same way.
   *
   * This is what ties an UNOWNED record to a unit. A record with no rep has
   * nothing else pointing at one — a Sales Route belongs to a rep, and that
   * rep belongs to a unit, so the route is the only honest link back.
   */
  partyRoute: 'custom_sales_route',
} as const;

/**
 * Units whose reps share their customers, leads and routes.
 *
 * A list rather than a flag on the unit, because there is no `Business Unit`
 * doctype to hang a flag on — the unit is a plain `Data` value on Sales
 * Person. Adding one here is a deliberate act; an unrecognised unit is never
 * pooled by default.
 */
export const POOLED_UNITS: readonly string[] = ['Manna Tyres UAE'];

export function isPooledUnit(unit: string | null | undefined): boolean {
  return POOLED_UNITS.includes((unit ?? '').trim());
}

const usable = (p: Person) => p.enabled !== false && p.isGroup !== true;

/**
 * The reps whose records this person may see.
 *
 * Returns `[]` — never "everyone" — when the person cannot be resolved. An
 * empty list must be handed to callers as "show nothing", and every caller
 * here treats it that way; the alternative is a filter of `undefined`, which
 * an API reasonably reads as *no filter at all* and answers with the whole
 * company. That exact bug was live on the dashboard on 12 Aug 2026.
 */
export function visibleReps(people: Person[], personId: string | undefined): string[] {
  const me = people.find((p) => p.name === personId);
  if (!me || !usable(me)) return [];

  const unit = (me.unit ?? '').trim();
  if (!unit || !isPooledUnit(unit)) return [me.name];

  return people.filter((p) => usable(p) && (p.unit ?? '').trim() === unit).map((p) => p.name);
}

/** Whether this person's records are shared with colleagues. */
export function sharesWithUnit(people: Person[], personId: string | undefined): boolean {
  return visibleReps(people, personId).length > 1;
}

/**
 * The owner-field VALUES a customer or lead may hold for this person to see
 * it — `visibleReps` plus, in a pooled unit only, an unassigned record.
 *
 * Outside a pool, an unowned record has nobody to route it to and stays
 * invisible until someone claims it — that is unchanged. Inside a pool the
 * business wants the opposite: a batch of customers/leads imported for the
 * UAE unit lands with no owner, and the whole team must see them immediately
 * rather than have them sit dark until somebody opens Desk. So a pooled
 * unit's filter additionally matches an empty owner field.
 *
 * `[]` still means "show nothing" — unresolvable is unresolvable whether or
 * not the unit is pooled.
 */
export function visibleOwnerValues(people: Person[], personId: string | undefined): string[] {
  const reps = visibleReps(people, personId);
  if (!reps.length) return [];
  const me = people.find((p) => p.name === personId);
  return isPooledUnit(me?.unit) ? [...reps, ''] : reps;
}

/**
 * Whether this person may set or change who a customer or lead belongs to.
 *
 * Restricted to a pooled unit deliberately: everywhere else a customer
 * belongs to the one rep who has always owned it, and reassignment is not a
 * decision the app hands out — it would let one rep quietly take another's
 * customer. A pooled unit is different because the business already treats
 * ownership there as a team-level fact, not a personal one.
 */
export function canAssignOwner(people: Person[], personId: string | undefined): boolean {
  const me = people.find((p) => p.name === personId);
  if (!me || !usable(me)) return false;
  return isPooledUnit(me.unit);
}

/**
 * Whether a record this person can see is actually somebody else's.
 *
 * Drives the "covering for X" marker. Only meaningful in a pooled unit, where
 * seeing a record and owning it are different things for the first time.
 */
export function isCoveringFor(
  people: Person[],
  personId: string | undefined,
  ownerId: string | undefined,
): boolean {
  if (!ownerId || ownerId === personId) return false;
  return visibleReps(people, personId).includes(ownerId);
}

export const POOLED_UNIT_NOTE =
  'Everyone in this unit shares its customers, leads and routes, so any of you can serve any of them while a colleague is away. Each one still has an owner, shown on the row.';
