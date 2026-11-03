/**
 * Monthly sales targets — read through the `manna_sales_targets` Server
 * Script (app/server/sales_targets.py), which decides whose targets this login
 * sees and counts only what SAP has invoiced. Written straight to the
 * `Sales Target` doctype, where `manna_sales_target_guard` refuses anybody but
 * the rep's own team manager.
 */
import { createDoc, http, listDocs, updateDoc } from './client';
import { toTargetMonth, type TargetMonth, type TargetUnit } from '@/domain/salesTarget';

const SALES_TARGET = 'Sales Target';

export async function getTargetMonth(month: string, year: number): Promise<TargetMonth> {
  const { data } = await http.get<{ message: Record<string, unknown> }>(
    '/api/method/manna_sales_targets',
    { params: { month, year } },
  );
  return toTargetMonth(data.message ?? {});
}

/** One target per rep per month: update it if there is one, else create it. */
export async function upsertTarget(args: {
  salesPerson: string;
  month: string;
  year: number;
  amount: number;
  unit: TargetUnit;
}): Promise<void> {
  const existing = await listDocs<{ name: string }>(SALES_TARGET, {
    fields: ['name'],
    filters: [
      ['sales_person', '=', args.salesPerson],
      ['month', '=', args.month],
      ['year', '=', args.year],
    ],
    limit: 1,
  });
  const body = { target_amount: args.amount, target_unit: args.unit };
  if (existing[0]) {
    await updateDoc(SALES_TARGET, existing[0].name, body);
  } else {
    await createDoc(SALES_TARGET, {
      ...body,
      sales_person: args.salesPerson,
      month: args.month,
      year: args.year,
    });
  }
}
