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
import { TakeOrderPage } from '@/features/orders/TakeOrderPage';
import { OrdersListPage } from '@/features/orders/OrdersListPage';
import { OrderDetailPage } from '@/features/orders/OrderDetailPage';
import { ApprovalsPage } from '@/features/approvals/ApprovalsPage';
import { ProductionBoard } from '@/features/production/ProductionBoard';
import { WeeklyCompilePage } from '@/features/production/WeeklyCompilePage';
import { MinStockPage } from '@/features/stock/MinStockPage';
import { AgingListPage } from '@/features/stock/AgingListPage';
import { ReplenishmentPage } from '@/features/stock/ReplenishmentPage';
import { HrDashboardPage } from '@/features/hr/HrDashboardPage';
import { EmployeesPage } from '@/features/hr/EmployeesPage';
import { LeaveRequestsPage } from '@/features/hr/LeaveRequestsPage';

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
 * Where "/" sends each role.
 *
 * There is no tiles dashboard on the sales side any more — every role opens
 * straight onto the screen they actually work in, so "/" is purely a redirect.
 * HR keeps its own overview because that page is the people summary, not a
 * dashboard of order counts.
 */
const HOME_ROUTE: Record<Exclude<Role, 'hr'>, string> = {
  sales_manager: '/approvals',
  production_manager: '/production',
  stock_manager: '/stock/replenish',
};

function RoleHome() {
  const user = useAppSelector(selectUser);
  if (!user) return <Navigate to="/login" replace />;
  if (user.role === 'hr') return <HrDashboardPage />;
  return <Navigate to={HOME_ROUTE[user.role]} replace />;
}

const SALES: Role[] = ['sales_manager'];
/** Everyone on the order/stock side. HR is deliberately not here. */
const ALL: Role[] = ['sales_manager', 'production_manager', 'stock_manager'];
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
          path="orders/new/:customerId"
          element={
            <RoleRoute allow={SALES}>
              <TakeOrderPage />
            </RoleRoute>
          }
        />
        <Route
          path="orders"
          element={
            <RoleRoute allow={ALL}>
              <OrdersListPage />
            </RoleRoute>
          }
        />
        <Route
          path="orders/:orderId"
          element={
            <RoleRoute allow={ALL}>
              <OrderDetailPage />
            </RoleRoute>
          }
        />

        <Route
          path="approvals"
          element={
            <RoleRoute allow={['sales_manager']}>
              <ApprovalsPage />
            </RoleRoute>
          }
        />

        <Route
          path="production"
          element={
            <RoleRoute allow={['production_manager']}>
              <ProductionBoard />
            </RoleRoute>
          }
        />
        <Route
          path="dispatch"
          element={
            <RoleRoute allow={['production_manager']}>
              <WeeklyCompilePage />
            </RoleRoute>
          }
        />

        <Route
          path="stock"
          element={
            <RoleRoute allow={ALL}>
              <MinStockPage />
            </RoleRoute>
          }
        />
        <Route
          path="stock/aging"
          element={
            <RoleRoute allow={['sales_manager', 'production_manager']}>
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
