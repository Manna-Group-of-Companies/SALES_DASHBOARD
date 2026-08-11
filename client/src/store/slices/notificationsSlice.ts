import { createAsyncThunk, createSlice, type PayloadAction } from '@reduxjs/toolkit';
import type { AppNotification, NotificationSeverity, User } from '@/domain/types';
import { Api, toApiError } from '@/api/client';
import { signOut } from './authSlice';

/** A transient on-screen message. Distinct from the persistent feed. */
export interface Toast {
  id: string;
  severity: NotificationSeverity | 'success';
  message: string;
}

interface NotificationsState {
  feed: AppNotification[];
  toasts: Toast[];
  status: 'idle' | 'loading' | 'ready';
  panelOpen: boolean;
}

const initialState: NotificationsState = {
  feed: [],
  toasts: [],
  status: 'idle',
  panelOpen: false,
};

export const loadNotifications = createAsyncThunk(
  'notifications/load',
  async (user: User, { rejectWithValue }) => {
    try {
      return await Api.notify.list(user);
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

export const markNotificationRead = createAsyncThunk(
  'notifications/markRead',
  async (input: { id: string; user: User }, { dispatch }) => {
    await Api.notify.markRead(input.id);
    void dispatch(loadNotifications(input.user));
  },
);

export const markAllNotificationsRead = createAsyncThunk(
  'notifications/markAllRead',
  async (user: User, { dispatch }) => {
    await Api.notify.markAllRead(user);
    void dispatch(loadNotifications(user));
  },
);

export const acknowledgeNotification = createAsyncThunk(
  'notifications/acknowledge',
  async (input: { id: string; user: User }, { dispatch }) => {
    await Api.notify.acknowledge(input.id);
    void dispatch(loadNotifications(input.user));
  },
);

let toastSeq = 0;

const notificationsSlice = createSlice({
  name: 'notifications',
  initialState,
  reducers: {
    pushToast: {
      reducer(state, action: PayloadAction<Toast>) {
        state.toasts.push(action.payload);
      },
      prepare(message: string, severity: Toast['severity'] = 'info') {
        toastSeq += 1;
        return { payload: { id: `T-${toastSeq}`, message, severity } };
      },
    },
    dismissToast(state, action: PayloadAction<string>) {
      state.toasts = state.toasts.filter((t) => t.id !== action.payload);
    },
    togglePanel(state, action: PayloadAction<boolean | undefined>) {
      state.panelOpen = action.payload ?? !state.panelOpen;
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(loadNotifications.pending, (state) => {
        if (state.status === 'idle') state.status = 'loading';
      })
      .addCase(loadNotifications.fulfilled, (state, action) => {
        state.status = 'ready';
        state.feed = action.payload;
      })
      // The feed and any on-screen toasts belong to whoever was signed in.
      // Without this, the next person to sign in on the same browser inherits
      // the previous user's messages.
      .addCase(signOut.fulfilled, () => initialState);
  },
});

export const { pushToast, dismissToast, togglePanel } = notificationsSlice.actions;
export default notificationsSlice.reducer;
