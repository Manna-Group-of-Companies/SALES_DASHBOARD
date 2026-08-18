/**
 * Sales-side vocabulary: order status, teams, and who a customer belongs to.
 *
 * Verified against the live site on 7 Aug 2026.
 *
 * The stored status strings still say "PO" although nothing scans a purchase
 * order any more. They are left alone because renaming would rewrite history
 * to no benefit — only the label shown to a person changed. Map at the
 * boundary with `approvalLabel` and never put the raw string on screen.
 */

import type { SalesPerson } from './types';

/** `Sales Order.custom_po_status` — a Select; anything else is rejected. */
export type PoStatus =
  | 'No PO Yet'
  | 'Pending Approval'
  | 'Pending Rate Approval'
  | 'PO Uploaded - Pending Approval'
  | 'Pending GM Approval'
  | 'PO Approved - Ready for SAP'
  | 'Rejected';

export const PO_APPROVED: PoStatus = 'PO Approved - Ready for SAP';

/** What a person should read. Never show the stored string. */
export function approvalLabel(status?: string): string {
  switch (status) {
    case 'PO Approved - Ready for SAP':
      return 'Approved';
    case 'Pending Approval':
    case 'PO Uploaded - Pending Approval':
      return 'Waiting for manager approval';
    case 'Pending Rate Approval':
      return 'Waiting for rate approval';
    case 'Pending GM Approval':
      return 'Escalated to GM';
    case 'Rejected':
      return 'Rejected';
    default:
      return 'Not sent for approval';
  }
}

export type ApprovalTone = 'ok' | 'warn' | 'danger' | 'neutral';

export function approvalTone(status?: string): ApprovalTone {
  switch (status) {
    case 'PO Approved - Ready for SAP':
      return 'ok';
    case 'Rejected':
      return 'danger';
    case 'Pending Approval':
    case 'PO Uploaded - Pending Approval':
    case 'Pending Rate Approval':
    case 'Pending GM Approval':
      return 'warn';
    default:
      return 'neutral';
  }
}

/** Is this order still waiting on somebody? */
export function awaitingDecision(status?: string): boolean {
  return (
    status === 'Pending Approval' ||
    status === 'PO Uploaded - Pending Approval' ||
    status === 'Pending Rate Approval' ||
    status === 'Pending GM Approval'
  );
}

/**
 * Read the STATUS, never the flag, to decide "is this approved".
 *
 * `custom_rate_approved` means "the prices were signed off at some point" and
 * stays set when a rep edits an approved order — which sends it back to the
 * queue. Using the flag would hide work that needs doing again.
 */
export function orderApproved(status?: string): boolean {
  return status === PO_APPROVED;
}

// ----------------------------------------------------------------- teams ---

/**
 * A team is keyed by a TOKEN, not by the manager's Sales Person name.
 *
 * `Sales Person.custom_team_manager` is a Select holding a short name —
 * `Pareeth`, `Saneesh`, `Renjith` — while the manager's own record is named
 * `Pareeth Kb`. Nobody carries `custom_team_manager = "Pareeth Kb"`, so
 * matching the token against the Sales Person name finds no reports and
 * concludes he manages nobody. Saneesh and Renjith hide the problem by
 * happening to match exactly.
 *
 * A manager is in their own team, so the token is simply their own value.
 */
export function teamTokenOf(person: SalesPerson | undefined): string {
  return (person?.teamManager ?? '').trim();
}

/**
 * Is this person the manager of the team they belong to?
 *
 * Their own name begins with the team token — `Pareeth Kb` for `Pareeth`,
 * `Saneesh` for `Saneesh`. A rep never does: `Amjad Pr` does not begin with
 * `Pareeth`. That is the only signal the data carries, and it is worth
 * replacing with a proper flag or a full-name token when ERPNext is next
 * touched, because it depends on a naming habit rather than a rule.
 */
export function isTeamManager(person: SalesPerson | undefined): boolean {
  const token = teamTokenOf(person).toLowerCase();
  if (!token || !person) return false;
  return person.id.trim().toLowerCase().startsWith(token);
}

/**
 * The Sales Person record name of a person's team manager.
 *
 * `teamManager` holds a short token (`Pareeth`); the manager's own record is
 * named `Pareeth Kb`. Anything comparing against a stored link — a trip's
 * tagged reps, an order's owner — needs the record name, and using the token
 * matches nothing while looking perfectly reasonable.
 *
 * Returns undefined when the team has no identifiable manager, so callers fail
 * closed rather than matching everybody.
 */
export function managerNameFor(
  people: SalesPerson[],
  person: SalesPerson | undefined,
): string | undefined {
  const token = teamTokenOf(person).toLowerCase();
  if (!token) return undefined;
  return people.find(
    (p) => teamTokenOf(p).toLowerCase() === token && isTeamManager(p),
  )?.id;
}

export function findPerson(people: SalesPerson[], id?: string): SalesPerson | undefined {
  if (!id) return undefined;
  return people.find((p) => p.id === id);
}

/** Everyone under a team token, the manager included. */
export function teamByToken(people: SalesPerson[], token: string): SalesPerson[] {
  const t = token.trim().toLowerCase();
  if (!t) return [];
  return people.filter(
    (p) => p.enabled && !p.isGroup && (p.teamManager ?? '').trim().toLowerCase() === t,
  );
}

/** Does this login manage anybody? */
export function managesTeam(people: SalesPerson[], personId?: string): boolean {
  return isTeamManager(findPerson(people, personId));
}

/**
 * The Sales Person names this login is responsible for.
 *
 * Empty when they manage nobody — callers treat that as "no team filter",
 * which is what a non-manager should see: nothing scoped to a team they
 * do not have.
 */
export function teamOf(people: SalesPerson[], personId?: string): string[] {
  const me = findPerson(people, personId);
  if (!isTeamManager(me)) return [];
  return teamByToken(people, teamTokenOf(me)).map((p) => p.id);
}

/**
 * The reps a manager's screens may read — or `null` meaning **show nothing**.
 *
 * `teamOf` returning `[]` used to be passed to the API as "no filter", which
 * an API reasonably reads as *every rep in the company*. So a manager whose
 * team could not be resolved — a missing `Sales Person` link, a name that
 * stopped matching its team token — silently saw the whole company's
 * customers, leads and location captures instead of none.
 *
 * A permission boundary has to fail closed. `null` is that: callers must
 * refuse to load rather than fetch unfiltered.
 */
export const NO_TEAM_MESSAGE =
  'This login does not manage a sales team, so there is nothing scoped to show. ' +
  'A manager needs a Sales Person record linked to their user, whose team matches their own name.';

export function scopeFor(people: SalesPerson[], personId?: string): string[] | null {
  const reps = teamOf(people, personId);
  return reps.length ? reps : null;
}

/** The reps under a manager, excluding the manager themselves. */
export function reportsOf(people: SalesPerson[], personId?: string): SalesPerson[] {
  const me = findPerson(people, personId);
  if (!isTeamManager(me)) return [];
  return teamByToken(people, teamTokenOf(me)).filter((p) => p.id !== me!.id);
}

// ------------------------------------------------------------- customers ---

/**
 * Does this customer belong to that rep?
 *
 * `custom_assigned_reps` is a **Link to Sales Person** holding a bare name.
 * It was once free text wrapped in pipes and matched with LIKE; that changed,
 * and every rep's customer list came back empty until the filters were
 * switched to equality. A `like "%|name|%"` against this field is broken.
 */
export function customerBelongsTo(assignedRep: string | undefined, reps: string[]): boolean {
  if (!assignedRep) return false;
  return reps.includes(assignedRep);
}

/** Over limit when what they already owe plus this order exceeds the limit. */
// ------------------------------------------------- what each manager sees ---

/**
 * The screens a sales manager's dashboard offers.
 *
 * Not every team runs the same way. Pareeth's team raises the orders, so that
 * team's manager needs the whole order pipeline. Saneesh and Renjith are
 * asked, for now, to work the party records and their own people — customers,
 * leads, location checks and attendance corrections — and nothing else.
 *
 * Held as data rather than scattered through the navigation because "who can
 * see the order queue" is a business decision that will change, and it should
 * change in one place rather than in six `roles:` arrays.
 */
export type ManagerScreen =
  | 'customers'
  | 'leads'
  | 'locations'
  | 'regularizations'
  | 'orders'
  | 'approvals'
  | 'combined'
  | 'stock';

/** Everything. */
const FULL: ManagerScreen[] = [
  'customers',
  'leads',
  'locations',
  'regularizations',
  'orders',
  'approvals',
  'combined',
  'stock',
];

/** Party records and their own people. */
const PARTY_ONLY: ManagerScreen[] = ['customers', 'leads', 'locations', 'regularizations'];

/**
 * Keyed by the team token on `Sales Person.custom_team_manager`, which is what
 * both the mobile app and this dashboard group people by.
 */
const BY_TEAM: Record<string, ManagerScreen[]> = {
  Pareeth: FULL,
  Saneesh: PARTY_ONLY,
  Renjith: PARTY_ONLY,
};

/**
 * What this manager may open.
 *
 * An unrecognised team gets the reduced set, not the full one. A new manager
 * appearing on the site should not silently inherit the order pipeline because
 * nobody remembered to add them here — the failure that costs least is the one
 * where somebody has to ask for access.
 */
export function screensFor(managedTeam: string | undefined): ManagerScreen[] {
  const token = (managedTeam ?? '').trim();
  if (!token) return [];
  return BY_TEAM[token] ?? PARTY_ONLY;
}

export function canOpen(managedTeam: string | undefined, screen: ManagerScreen): boolean {
  return screensFor(managedTeam).includes(screen);
}

/**
 * §7.7 — an order cannot be *started* for a party with no sales route.
 *
 * Checked before the order screen opens and again at creation, because a rep
 * or manager can sit on the screen while somebody else clears the route. The
 * route decides which run the goods go out on; an order without one has
 * nowhere to be delivered and nothing downstream will ask again.
 *
 * 258 of 620 customers currently have no route, so this refuses a great many
 * orders on purpose — the alternative is orders that cannot be dispatched.
 */
export function canStartOrder(party: { route?: string | null }): boolean {
  return hasRoute(party.route);
}

export const NO_ROUTE_MESSAGE =
  'This party has no sales route, so an order cannot be started for them. Assign a route first — the route is what decides which delivery run the goods go out on.';

export function creditBreached(
  outstanding: number,
  creditLimit: number,
  orderTotal = 0,
): boolean {
  if (!(creditLimit > 0)) return false;
  return outstanding + orderTotal > creditLimit;
}

/**
 * A route is required before an order can be taken.
 *
 * Production is shown the route and nothing else, so an order without one
 * reaches the floor with nowhere to send it. Blank, whitespace, null and the
 * literal string "null" all mean no route — the last one is real, and treating
 * it as a route puts the word "null" on a delivery run.
 */
export function hasRoute(route?: string | null): boolean {
  const r = (route ?? '').trim();
  return r !== '' && r.toLowerCase() !== 'null';
}
