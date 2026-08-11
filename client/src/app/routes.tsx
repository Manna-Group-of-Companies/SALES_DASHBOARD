/**
 * Routing.
 *
 * `RoleRoute` is the second half of the permission story: `orderRules` decides
 * what a user may *do*, this decides what they may even open. A Production
 * Manager typing /approvals into the address bar lands back on their dashboard
 * rather than on a screen full of customer names.
 *
 * There is no Sales Rep route set here at all — reps raise orders in the
 * field-sales app and have no login for this one.
 */

import { lazy, Suspense, type ReactElement } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';
import type { Role } from '@/domain/types';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { AppShell } from '@/components/layout/AppShell';
import { LoginPage } from '@/features/auth/LoginPage';
import { CustomersPage } from '@/features/customers/CustomersPage';
import { LeadsPage } from '@/features/customers/LeadsPage';
import { TakeOrderPage } from '@/features/orders/TakeOrderPage';
import { OrdersListPage } from '@/features/orders/OrdersListPage';
import { OrderDetailPage } from '@/features/orders/OrderDetailPage';
import { LeadOrderPage } from '@/features/orders/LeadOrderPage';
import { CombinedOrdersPage } from '@/features/orders/CombinedOrdersPage';
import { GmQueuePage } from '@/features/orders/GmQueuePage';
import { ApprovalsInboxPage } from '@/features/approvals/ApprovalsInboxPage';
import { ProductionQueuePage } from '@/features/production/ProductionQueuePage';
import { ProductionOrderPage } from '@/features/production/ProductionOrderPage';
import { CloseWeekPage } from '@/features/production/CloseWeekPage';
import { ProductionStockPage } from '@/features/production/ProductionStockPage';
import { MinStockPage } from '@/features/stock/MinStockPage';
import { AgingListPage } from '@/features/stock/AgingListPage';
import { SalesStockPage } from '@/features/stock/SalesStockPage';
import { ReplenishmentPage } from '@/features/stock/ReplenishmentPage';
import { SalesDashboardPage } from '@/features/dashboard/SalesDashboardPage';
import { StockDashboardPage } from '@/features/dashboard/StockDashboardPage';
import { HrDashboardPage } from '@/features/hr/HrDashboardPage';
import { EmployeesPage } from '@/features/hr/EmployeesPage';
import { LeaveRequestsPage } from '@/features/hr/LeaveRequestsPage';
import { CalendarPage } from '@/features/hr/CalendarPage';
import { OdometerVerificationPage } from '@/features/hr/OdometerVerificationPage';
import { TripDetailPage } from '@/features/hr/TripDetailPage';
import { RegularizationsPage } from '@/features/hr/RegularizationsPage';
import { MonthlyExpensePage } from '@/features/reports/MonthlyExpensePage';
import { RangeSummaryPage } from '@/features/reports/RangeSummaryPage';

// The importer pulls in the whole spreadsheet parser, which nobody needs until
// they actually open it — so it loads on demand rather than in the main bundle.
const ImportPage = lazy(() =>
  import('@/features/import/ImportPage').then((m) => ({ default: m.ImportPage })),
);

function RoleRoute({ allow, children }: { allow: Role[]; children: ReactElement }) {
  const user = useAppSelector(selectUser);
  if (!user) return <Navigate to="/login" replace />;
  if (!allow.includes(user.role)) return <Navigate to="/" replace />;
  return children;
}

/**
 * Every role opens onto its own landing page rather than straight into a work
 * screen. These replace an earlier set of tiles that were removed because they
 * had become a second place to act on an order — so the rule this time is that
 * a dashboard summarises and navigates and never decides. There is no Approve,
 * no stage move and no acknowledgement on any of them; every number links to
 * the single screen that owns that decision.
 */

function RoleHome() {
  const user = useAppSelector(selectUser);
  if (!user) return <Navigate to="/login" replace />;
  switch (user.role) {
    case 'hr':
      return <HrDashboardPage />;
    case 'sales_manager':
      return <SalesDashboardPage />;
    // The GM opens on what is waiting for them and nothing else.
    case 'general_manager':
      return <GmQueuePage />;
    /*
     * The production manager lands straight on the queue (B1), not on a
     * summary. The old dashboard is fed by the Redux order slice, which is the
     * fixture-era path and never reaches the live Sales Orders — so it showed
     * an empty screen with no sign that anything was wrong. The queue is the
     * production manager's actual job, and it reads the live site.
     */
    case 'production_manager':
      return <ProductionQueuePage />;
    case 'stock_manager':
      return <StockDashboardPage />;
  }
}

const SALES: Role[] = ['sales_manager', 'general_manager'];
const GM: Role[] = ['general_manager'];
const HR: Role[] = ['hr'];

export function AppRoutes() {
  const user = useAppSelector(selectUser);

  if (!user) {
    return (
      <Routes>
        <Route path="/login" element={<LoginPage />} />
        <Route path="*" element={<Navigate to="/login" replace />} />
      </Routes>
    );
  }

  return (
    <Routes>
      <Route path="/login" element={<Navigate to="/" replace />} />

      <Route element={<AppShell />}>
        <Route index element={<RoleHome />} />

        <Route
          path="customers"
          element={
            <RoleRoute allow={SALES}>
              <CustomersPage />
            </RoleRoute>
          }
        />
        <Route
          path="leads"
          element={
            <RoleRoute allow={SALES}>
              <LeadsPage />
            </RoleRoute>
          }
        />

        <Route
          path="orders/new/:customerId"
          element={
            <RoleRoute allow={SALES}>
              <TakeOrderPage />
            </RoleRoute>
          }
        />
        {/*
          Orders carry the customer's name, so these are SALES only — not
          `ALL`. A production manager reaching /orders would see exactly the
          identity that B0 exists to keep from them, and a route that merely
          hides it in the UI is not the same as one they cannot open.
        */}
        <Route
          path="orders"
          element={
            <RoleRoute allow={SALES}>
              <OrdersListPage />
            </RoleRoute>
          }
        />
        <Route
          path="orders/:orderId"
          element={
            <RoleRoute allow={SALES}>
              <OrderDetailPage />
            </RoleRoute>
          }
        />
        <Route
          path="lead-orders/:leadOrderId"
          element={
            <RoleRoute allow={SALES}>
              <LeadOrderPage />
            </RoleRoute>
          }
        />
        <Route
          path="combined"
          element={
            <RoleRoute allow={SALES}>
              <CombinedOrdersPage />
            </RoleRoute>
          }
        />

        <Route
          path="gm"
          element={
            <RoleRoute allow={GM}>
              <GmQueuePage />
            </RoleRoute>
          }
        />

        <Route
          path="approvals"
          element={
            <RoleRoute allow={SALES}>
              <ApprovalsInboxPage />
            </RoleRoute>
          }
        />

        <Route
          path="production"
          element={
            <RoleRoute allow={['production_manager']}>
              <ProductionQueuePage />
            </RoleRoute>
          }
        />
        <Route
          path="production/stock"
          element={
            <RoleRoute allow={['production_manager']}>
              <ProductionStockPage />
            </RoleRoute>
          }
        />
        <Route
          path="production/close-week"
          element={
            <RoleRoute allow={['production_manager']}>
              <CloseWeekPage />
            </RoleRoute>
          }
        />
        <Route
          path="production/:orderId"
          element={
            <RoleRoute allow={['production_manager']}>
              <ProductionOrderPage />
            </RoleRoute>
          }
        />

        {/*
          The sales side gets its own read-only view: it answers "what can I
          promise and what should I clear", where production's answers "what
          should we make next". The fixture-era MinStockPage stays for the
          stock manager until that role has live data behind it.
        */}
        <Route
          path="stock"
          element={
            <RoleRoute allow={['sales_manager', 'general_manager']}>
              <SalesStockPage />
            </RoleRoute>
          }
        />
        <Route
          path="stock/ledger"
          element={
            <RoleRoute allow={['stock_manager']}>
              <MinStockPage />
            </RoleRoute>
          }
        />
        <Route
          path="stock/aging"
          element={
            <RoleRoute allow={['stock_manager']}>
              <AgingListPage />
            </RoleRoute>
          }
        />
        <Route
          path="stock/replenish"
          element={
            <RoleRoute allow={['stock_manager', 'production_manager']}>
              <ReplenishmentPage />
            </RoleRoute>
          }
        />

        <Route
          path="hr/employees"
          element={
            <RoleRoute allow={HR}>
              <EmployeesPage />
            </RoleRoute>
          }
        />
        <Route
          path="hr/leave"
          element={
            <RoleRoute allow={HR}>
              <LeaveRequestsPage />
            </RoleRoute>
          }
        />
        <Route
          path="hr/calendar"
          element={
            <RoleRoute allow={HR}>
              <CalendarPage />
            </RoleRoute>
          }
        />
        <Route
          path="hr/regularizations"
          element={
            <RoleRoute allow={HR}>
              <RegularizationsPage />
            </RoleRoute>
          }
        />
        <Route
          path="hr/odometer"
          element={
            <RoleRoute allow={HR}>
              <OdometerVerificationPage />
            </RoleRoute>
          }
        />
        <Route
          path="hr/trips/:tripId"
          element={
            <RoleRoute allow={HR}>
              <TripDetailPage />
            </RoleRoute>
          }
        />
        <Route
          path="reports/expenses"
          element={
            <RoleRoute allow={HR}>
              <MonthlyExpensePage />
            </RoleRoute>
          }
        />
        <Route
          path="reports/summary"
          element={
            <RoleRoute allow={HR}>
              <RangeSummaryPage />
            </RoleRoute>
          }
        />

        <Route
          path="import"
          element={
            <RoleRoute allow={['sales_manager', 'stock_manager']}>
              <Suspense fallback={<div className="muted">Loading importer…</div>}>
                <ImportPage />
              </Suspense>
            </RoleRoute>
          }
        />

        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}
