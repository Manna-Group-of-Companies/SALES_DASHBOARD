/**
 * What the shelf has, for the screens that render it while an order is typed.
 *
 * This held three lists and five thunks: a minimum-stock ledger, the live
 * reservation rows, open replenishment orders, and the actions to reserve,
 * release, raise a replenishment and receive one. All of it went on
 * 17 September 2026 with the doctypes behind it — and most of it had never
 * worked against the live site anyway, because `Manna Minimum Stock Item` has
 * no `onHand` or `threshold` field for `MinStockItem` to read.
 *
 * One list now, from SAP, and one thunk to re-read it. There is nothing to
 * reserve: SAP commits stock against its own sales orders, and the figure here
 * is already net of every one of them.
 */

import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import type { MinStockLine } from '@/domain/types';
import { Api, toApiError } from '@/api/client';

interface MinStockState {
  items: MinStockLine[];
  status: 'idle' | 'loading' | 'ready' | 'failed';
  error: string | null;
  lastSyncedAt: string | null;
}

const initialState: MinStockState = {
  items: [],
  status: 'idle',
  error: null,
  lastSyncedAt: null,
};

/**
 * Re-read what is available. Polled on a timer while an order is being taken,
 * so a rep sees stock go as other orders reach SAP.
 *
 * The figure is only as fresh as the five-minute SAP stock sync behind it, so
 * polling faster than that buys nothing but load.
 */
export const refreshMinStock = createAsyncThunk(
  'minStock/refresh',
  async (_: void, { rejectWithValue }) => {
    try {
      return await Api.sales.listMinimumStock();
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

const minStockSlice = createSlice({
  name: 'minStock',
  initialState,
  reducers: {},
  extraReducers: (builder) => {
    builder
      .addCase(refreshMinStock.pending, (state) => {
        // Keep the previous rows on screen; a poll must not blank the list.
        if (state.status === 'idle') state.status = 'loading';
      })
      .addCase(refreshMinStock.fulfilled, (state, action) => {
        state.status = 'ready';
        state.items = action.payload;
        state.lastSyncedAt = new Date().toISOString();
      })
      .addCase(refreshMinStock.rejected, (state, action) => {
        state.status = 'failed';
        state.error = (action.payload as string) ?? 'Could not read what is in stock.';
      });
  },
});

export default minStockSlice.reducer;
