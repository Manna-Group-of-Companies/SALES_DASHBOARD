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
      });
  },
});

export const { clearAuthError } = authSlice.actions;
export default authSlice.reducer;
