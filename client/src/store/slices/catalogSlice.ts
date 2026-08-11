import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import type { Customer, Product } from '@/domain/types';
import { Api, toApiError } from '@/api/client';
import { signOut } from './authSlice';

interface CatalogState {
  products: Product[];
  customers: Customer[];
  status: 'idle' | 'loading' | 'ready' | 'failed';
  error: string | null;
}

const initialState: CatalogState = {
  products: [],
  customers: [],
  status: 'idle',
  error: null,
};

export const loadCatalog = createAsyncThunk(
  'catalog/load',
  async (salesPerson: string | undefined, { rejectWithValue }) => {
    try {
      const [products, customers] = await Promise.all([
        Api.catalog.listProducts(),
        Api.catalog.listCustomers(salesPerson),
      ]);
      return { products, customers };
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

const catalogSlice = createSlice({
  name: 'catalog',
  initialState,
  reducers: {},
  extraReducers: (builder) => {
    builder
      // The customer list is filtered per rep; clear it with the session.
      .addCase(signOut.fulfilled, () => initialState)
      .addCase(loadCatalog.pending, (state) => {
        state.status = 'loading';
        state.error = null;
      })
      .addCase(loadCatalog.fulfilled, (state, action) => {
        state.status = 'ready';
        state.products = action.payload.products;
        state.customers = action.payload.customers;
      })
      .addCase(loadCatalog.rejected, (state, action) => {
        state.status = 'failed';
        state.error = (action.payload as string) ?? 'Could not load products.';
      });
  },
});

export default catalogSlice.reducer;
