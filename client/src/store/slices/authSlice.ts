import { createAsyncThunk, createSlice, type PayloadAction } from '@reduxjs/toolkit';
import type { User } from '@/domain/types';
import { Api, toApiError } from '@/api/client';

interface AuthState {
  user: User | null;
  status: 'idle' | 'loading' | 'failed';
  error: string | null;
}

const initialState: AuthState = {
  // Survive a refresh without a round-trip.
  user: Api.auth.restoreSession(),
  status: 'idle',
  error: null,
};

export const signIn = createAsyncThunk(
  'auth/signIn',
  async (credentials: { email: string; password: string }, { rejectWithValue }) => {
    try {
      return await Api.auth.login(credentials.email, credentials.password);
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

export const signOut = createAsyncThunk('auth/signOut', async () => {
  await Api.auth.logout();
});

/**
 * Check at boot that the restored user still has a live session.
 *
 * The cached user survives a refresh; the Frappe cookie behind it does not
 * always. Without this the app renders a full signed-in shell on a dead
 * session and every screen fails with a permission error that looks like an
 * ERPNext misconfiguration — see `validateSession` for the incident.
 *
 * Rejecting signs the user out locally and says why, so they land on the
 * login page with an explanation rather than a wall of red panels.
 */
export const revalidateSession = createAsyncThunk(
  'auth/revalidate',
  async (_: void, { getState, rejectWithValue }) => {
    // Nothing to revalidate when nobody was restored.
    if (!(getState() as { auth: AuthState }).auth.user) return true;
    if (await Api.auth.validateSession()) return true;
    await Api.auth.logout();
    return rejectWithValue('Your session has expired. Please sign in again.');
  },
);

const authSlice = createSlice({
  name: 'auth',
  initialState,
  reducers: {
    clearAuthError(state) {
      state.error = null;
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(signOut.fulfilled, (state) => {
        state.user = null;
        state.status = 'idle';
        state.error = null;
      })
      .addCase(signIn.pending, (state) => {
        state.status = 'loading';
        state.error = null;
      })
      .addCase(signIn.fulfilled, (state, action: PayloadAction<User>) => {
        state.status = 'idle';
        state.user = action.payload;
      })
      .addCase(signIn.rejected, (state, action) => {
        state.status = 'failed';
        state.error = (action.payload as string) ?? 'Sign in failed.';
      })
      .addCase(revalidateSession.rejected, (state, action) => {
        state.user = null;
        state.status = 'idle';
        state.error =
          (action.payload as string) ?? 'Your session has expired. Please sign in again.';
      });
  },
});

export const { clearAuthError } = authSlice.actions;
export default authSlice.reducer;
