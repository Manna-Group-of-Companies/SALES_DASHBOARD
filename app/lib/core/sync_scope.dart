// Which SAP syncs a login's Sync button asks for.
//
// DECIDED 25 SEPTEMBER 2026 — every sync reachable wherever its data is read.
// Until then stock and credit were offered to the Manna Treads side only
// (`Session.isTreadsUnit`), so the GM, whose approval screens show credit and
// stock, and a Treads production login could refresh neither. Nothing syncs on
// a timer, so a sync nobody may ask for simply does not happen.
//
//   * Orders: everyone.
//   * Stock (with the items and the two weight UDFs): everyone except a login
//     of another unit — it is Manna Treads' finished-goods warehouse. A login
//     with no unit at all (the GM) reads it too.
//   * Credit: the Manna Treads sales side and the GM. The sync reads
//     MANNA_TREADS_LIVE only; manna_sap_request_sync admits Higher Management
//     (the GM) from 25 Sep 2026.
//
// The dashboard's twin is `client/src/domain/syncScope.ts` (`syncsFor`); the
// two must give the same answer for the same login.

import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/core/session.dart';

enum SyncKind { orders, stock, credit }

/// The rule, on plain values so it can be tested without a [Session].
///
/// [salesCompany] is the login's own Sales Person company, or failing that
/// the company of the team it manages. [productionUnit] is the unit a
/// production login runs.
List<SyncKind> syncsForLogin({
  String? salesCompany,
  String? productionUnit,
  bool isGM = false,
}) {
  final sales = (salesCompany ?? '').trim();
  final unit = (productionUnit ?? '').trim();
  // A login's own unit: its sales company, else the unit it runs.
  final own = sales.isNotEmpty ? sales : unit;
  return [
    SyncKind.orders,
    if (own.isEmpty || own == kUnitTreads) SyncKind.stock,
    if (sales == kUnitTreads || isGM) SyncKind.credit,
  ];
}

/// [syncsForLogin] for the signed-in phone.
List<SyncKind> syncsForSession(Session s) {
  final own = (s.company ?? '').trim();
  return syncsForLogin(
    salesCompany: own.isNotEmpty ? own : s.managedTeamCompany,
    productionUnit: s.isProductionManager ? s.productionCompany : null,
    isGM: s.isGM,
  );
}
