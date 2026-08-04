import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import type { FulfilmentSource, Order, OrderItem, User, WeeklyGroup } from '@/domain/types';
import { Api, toApiError } from '@/api/client';
import type { CreateOrderInput, OrderQuery, WeekBucket } from '@/api/client';
import { signOut } from './authSlice';

interface OrdersState {
  list: Order[];
  weeklyGroups: WeeklyGroup[];
  status: 'idle' | 'loading' | 'ready' | 'failed';
  saving: boolean;
  error: string | null;
  /** Order id whose detail view is open. */
  selectedId: string | null;
}

const initialState: OrdersState = {
  list: [],
  weeklyGroups: [],
  status: 'idle',
  saving: false,
  error: null,
  selectedId: null,
};

export const loadOrders = createAsyncThunk(
  'orders/load',
  async (query: OrderQuery | undefined, { rejectWithValue }) => {
    try {
      const [list, weeklyGroups] = await Promise.all([
        Api.orders.list(query ?? {}),
        Api.orders.listWeeklyGroups(),
      ]);
      return { list, weeklyGroups };
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

export const createOrder = createAsyncThunk(
  'orders/create',
  async (input: CreateOrderInput, { rejectWithValue }) => {
    try {
      return await Api.orders.create(input);
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

export const updateOrderItems = createAsyncThunk(
  'orders/updateItems',
  async (
    input: { orderId: string; items: OrderItem[]; user: User; note?: string },
    { rejectWithValue },
  ) => {
    try {
      return await Api.orders.updateItems(input.orderId, input.items, input.user, input.note);
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

export const approveOrder = createAsyncThunk(
  'orders/approve',
  async (
    input: {
      orderId: string;
      user: User;
      finalRates: Record<string, number>;
      sources: Record<string, FulfilmentSource>;
    },
    { rejectWithValue },
  ) => {
    try {
      return await Api.orders.approve(input);
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

export const rejectOrder = createAsyncThunk(
  'orders/reject',
  async (input: { orderId: string; reason: string; user: User }, { rejectWithValue }) => {
    try {
      return await Api.orders.reject(input.orderId, input.reason, input.user);
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

export const setItemStage = createAsyncThunk(
  'orders/setStage',
  async (
    input: { orderId: string; itemId: string; stage: string; user: User },
    { rejectWithValue },
  ) => {
    try {
      return await Api.orders.setItemStage(input.orderId, input.itemId, input.stage, input.user);
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

export const changeDeliveryDate = createAsyncThunk(
  'orders/changeDeliveryDate',
  async (
    input: { orderId: string; newDate: string; reason: string; user: User },
    { rejectWithValue },
  ) => {
    try {
      return await Api.orders.changeDeliveryDate(
        input.orderId,
        input.newDate,
        input.reason,
        input.user,
      );
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

export const acknowledgeChange = createAsyncThunk(
  'orders/acknowledgeChange',
  async (input: { orderId: string; timelineId: string; user: User }, { rejectWithValue }) => {
    try {
      return await Api.orders.acknowledgeChange(input.orderId, input.timelineId, input.user);
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

export const dispatchOrder = createAsyncThunk(
  'orders/dispatch',
  async (input: { orderId: string; user: User }, { rejectWithValue }) => {
    try {
      return await Api.orders.dispatch(input.orderId, input.user);
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

export const compileWeeklyGroup = createAsyncThunk(
  'orders/compileWeek',
  async (input: { bucket: WeekBucket; user: User }, { dispatch, rejectWithValue }) => {
    try {
      const group = await Api.orders.compileWeeklyGroup(input.bucket, input.user);
      void dispatch(loadOrders(undefined));
      return group;
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

const ordersSlice = createSlice({
  name: 'orders',
  initialState,
  reducers: {
    selectOrder(state, action: { payload: string | null }) {
      state.selectedId = action.payload;
    },
    clearOrdersError(state) {
      state.error = null;
    },
  },
  extraReducers: (builder) => {
    builder
      // Orders are scoped to the signed-in user, so they must not survive a
      // sign-out into the next person's session.
      .addCase(signOut.fulfilled, () => initialState)
      .addCase(loadOrders.pending, (state) => {
        if (state.status === 'idle') state.status = 'loading';
        state.error = null;
      })
      .addCase(loadOrders.fulfilled, (state, action) => {
        state.status = 'ready';
        state.list = action.payload.list;
        state.weeklyGroups = action.payload.weeklyGroups;
      })
      .addCase(loadOrders.rejected, (state, action) => {
        state.status = 'failed';
        state.error = (action.payload as string) ?? 'Could not load orders.';
      })
      .addCase(createOrder.fulfilled, (state, action) => {
        state.saving = false;
        state.list.unshift(action.payload);
      })
      // Compiling returns a WeeklyGroup rather than an Order, so it sits
      // outside the matcher below and has to clear `saving` itself.
      .addCase(compileWeeklyGroup.fulfilled, (state, action) => {
        state.saving = false;
        state.weeklyGroups.unshift(action.payload);
      })
      // Every mutating thunk returns the fresh order, so one matcher keeps the
      // list in sync rather than nine near-identical cases.
      .addMatcher(
        (a) => /^orders\/(updateItems|approve|reject|setStage|changeDeliveryDate|acknowledgeChange|dispatch)\/fulfilled$/.test(a.type),
        (state, action: { payload: Order }) => {
          state.saving = false;
          const i = state.list.findIndex((o) => o.id === action.payload.id);
          if (i >= 0) state.list[i] = action.payload;
          else state.list.unshift(action.payload);
        },
      )
      .addMatcher(
        (a) => /^orders\/.+\/pending$/.test(a.type) && a.type !== loadOrders.pending.type,
        (state) => {
          state.saving = true;
          state.error = null;
        },
      )
      .addMatcher(
        (a) => /^orders\/.+\/rejected$/.test(a.type) && a.type !== loadOrders.rejected.type,
        (state, action: { payload: unknown }) => {
          state.saving = false;
          state.error = (action.payload as string) ?? 'That change could not be saved.';
        },
      );
  },
});

export const { selectOrder, clearOrdersError } = ordersSlice.actions;
export default ordersSlice.reducer;
