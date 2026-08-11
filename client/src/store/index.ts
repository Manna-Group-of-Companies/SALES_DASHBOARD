import { configureStore } from '@reduxjs/toolkit';
import auth from './slices/authSlice';
import catalog from './slices/catalogSlice';
import hr from './slices/hrSlice';
import minStock from './slices/minStockSlice';
import notifications from './slices/notificationsSlice';
import orders from './slices/ordersSlice';

export const store = configureStore({
  reducer: { auth, catalog, orders, minStock, notifications, hr },
  middleware: (getDefault) =>
    getDefault({
      // Payloads carry ISO strings and plain objects only; the check is pure
      // overhead on lists this size.
      serializableCheck: false,
    }),
});

export type RootState = ReturnType<typeof store.getState>;
export type AppDispatch = typeof store.dispatch;
