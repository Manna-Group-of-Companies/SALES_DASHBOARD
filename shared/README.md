# What lives here, and why

Two apps sell the same products to the same customers against the same ERPNext
site: `app/` (Flutter, the reps' phones) and `client/` (React, the managers'
dashboard). They cannot share code — Dart and TypeScript — so every rule that
matters is written twice.

That is the whole problem. A rule written twice drifts, and when the rule
decides a price, drift means two different invoices for the same order.

Prose does not stop it. `app/server/DASHBOARD_ADDENDUM.md` is a careful
document and both sides still ended up disagreeing about the discount cap
within a day of each other — see `DIVERGENCES.md`. A document is a promise one
side makes; a fixture is a test the other side fails.

## How a fixture works

`fixtures/*.json` holds cases as data, not as code. Both test suites load the
same file and assert the same expectations:

```dart
// app/test/discount_test.dart
final cases = json.decode(File('../shared/fixtures/discount.json').readAsStringSync());
```

```ts
// client/src/domain/__tests__/discount.test.ts
import cases from '../../../../shared/fixtures/discount.json'
```

Change the rule on one side and the other side's tests go red. The divergence
becomes a build failure rather than something a customer finds.

## The rules for this directory

- **A fixture is only added once both sides agree.** An open question belongs
  in `DIVERGENCES.md` until somebody decides it, not in a fixture where it
  would silently make one implementation the winner.
- **Every case carries a `why`.** A case named `case_7` teaches nothing when it
  fails at midnight; the sentence is the point.
- **Cover the money first.** Discounts, approval gates, credit escalation,
  split arithmetic, the booking protocol. Cosmetic differences between the two
  apps are fine and always will be — these are not.
- **Changing a fixture is changing the rule.** It needs the same thought as
  changing the code, and both apps updated in the same pull request.
