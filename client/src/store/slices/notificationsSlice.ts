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
  /**
   * Notifications this browser worked out for itself - an order reaching SAP
   * (26 Nov 2026, `useSapSentWatch`). No server store holds them; the watcher
   * keeps them in localStorage. Ids start `local:`.
   */
  local: AppNotification[];
  toasts: Toast[];
  status: 'idle' | 'loading' | 'ready';
  panelOpen: boolean;
}

const initialState: NotificationsState = {
  feed: [],
  local: [],
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
    if (isLocalNotification(input.id)) {
      dispatch(markLocalRead(input.id));
      return;
    }
    await Api.notify.markRead(input.id);
    void dispatch(loadNotifications(input.user));
  },
);

export const markAllNotificationsRead = createAsyncThunk(
  'notifications/markAllRead',
  async (user: User, { dispatch }) => {
    dispatch(markLocalRead(undefined));
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

export const isLocalNotification = (id: string) => id.startsWith('local:');

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
    setLocalNotifications(state, action: PayloadAction<AppNotification[]>) {
      state.local = action.payload;
    },
    /** One local notification read, or every one when the id is undefined. */
    markLocalRead(state, action: PayloadAction<string | undefined>) {
      const at = new Date().toISOString();
      for (const n of state.local) {
        if (!n.readAt && (action.payload === undefined || n.id === action.payload)) n.readAt = at;
      }
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

export const { pushToast, dismissToast, togglePanel, setLocalNotifications, markLocalRead } =
  notificationsSlice.actions;
export default notificationsSlice.reducer;
