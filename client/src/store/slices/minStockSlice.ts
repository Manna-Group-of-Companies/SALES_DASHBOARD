import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import type { MinStockItem, ProductionOrder, StockReservation, User } from '@/domain/types';
import { joinProductionOrders } from '@/domain/aging';
import { Api, toApiError } from '@/api/client';

interface MinStockState {
  items: MinStockItem[];
  reservations: StockReservation[];
  productionOrders: ProductionOrder[];
  status: 'idle' | 'loading' | 'ready' | 'failed';
  error: string | null;
  /** Set when a reserve attempt loses a race with another rep. */
  lastConflict: string | null;
  lastSyncedAt: string | null;
}

const initialState: MinStockState = {
  items: [],
  reservations: [],
  productionOrders: [],
  status: 'idle',
  error: null,
  lastConflict: null,
  lastSyncedAt: null,
};

/**
 * Re-read the shared ledger. Polled on a timer while an order is being taken so
 * one rep sees another rep's bookings appear (1.2).
 */
export const refreshMinStock = createAsyncThunk(
  'minStock/refresh',
  async (_: void, { rejectWithValue }) => {
    try {
      const [items, reservations, productionOrders] = await Promise.all([
        Api.stock.listMinStock(),
        Api.stock.listReservations(),
        Api.stock.listProductionOrders(),
      ]);
      return { items, reservations, productionOrders };
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

export const reserveStock = createAsyncThunk(
  'minStock/reserve',
  async (
    input: { itemCode: string; qty: number; user: User; orderId?: string | null },
    { dispatch, rejectWithValue },
  ) => {
    try {
      const row = await Api.stock.reserve(input);
      // Pull the ledger straight back so the row's availability is truthful.
      void dispatch(refreshMinStock());
      return row;
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

export const releaseHolds = createAsyncThunk(
  'minStock/release',
  async (input: { user: User; orderId?: string | null }, { dispatch }) => {
    await Api.stock.releaseDraftHolds(input.user, input.orderId ?? null);
    void dispatch(refreshMinStock());
  },
);

export const raiseReplenishment = createAsyncThunk(
  'minStock/replenish',
  async (
    input: { item: MinStockItem; qty: number; user: User },
    { dispatch, rejectWithValue },
  ) => {
    try {
      const order = await Api.stock.raiseReplenishment(input.item, input.qty, input.user);
      void dispatch(refreshMinStock());
      return order;
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

export const recordReplenishment = createAsyncThunk(
  'minStock/record',
  async (
    input: {
      itemCode: string;
      qty: number;
      user: User;
      productionOrderId?: string;
      looseBelts?: number;
    },
    { dispatch, rejectWithValue },
  ) => {
    try {
      const item = await Api.stock.recordReplenishment(
        input.itemCode,
        input.qty,
        input.user,
        input.productionOrderId,
        input.looseBelts,
      );
      void dispatch(refreshMinStock());
      return item;
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

const minStockSlice = createSlice({
  name: 'minStock',
  initialState,
  reducers: {
    clearConflict(state) {
      state.lastConflict = null;
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(refreshMinStock.pending, (state) => {
        // Keep the previous rows on screen; a poll must not blank the list.
        if (state.status === 'idle') state.status = 'loading';
      })
      .addCase(refreshMinStock.fulfilled, (state, action) => {
        const joined = joinProductionOrders(action.payload.items, action.payload.productionOrders);
        state.status = 'ready';
        state.items = joined.items;
        state.reservations = action.payload.reservations;
        state.productionOrders = joined.orders;
        state.lastSyncedAt = new Date().toISOString();
      })
      .addCase(refreshMinStock.rejected, (state, action) => {
        state.status = 'failed';
        state.error = (action.payload as string) ?? 'Could not read the stock ledger.';
      })
      .addCase(reserveStock.rejected, (state, action) => {
        state.lastConflict = (action.payload as string) ?? 'That quantity is no longer available.';
      })
      .addCase(reserveStock.fulfilled, (state) => {
        state.lastConflict = null;
      });
  },
});

export const { clearConflict } = minStockSlice.actions;
export default minStockSlice.reducer;
