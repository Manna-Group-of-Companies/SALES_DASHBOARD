import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import type {
  AttendanceRecord,
  AttendanceStatus,
  Employee,
  LeaveRequest,
  User,
} from '@/domain/types';
import { shiftDays } from '@/domain/hrRules';
import { toIsoDate } from '@/domain/orderRules';
import { Api, toApiError } from '@/api/client';

/** How much attendance history the dashboard's trend needs. */
export const ATTENDANCE_WINDOW_DAYS = 14;

interface HrState {
  employees: Employee[];
  attendance: AttendanceRecord[];
  leaveRequests: LeaveRequest[];
  status: 'idle' | 'loading' | 'ready' | 'failed';
  error: string | null;
  lastSyncedAt: string | null;
}

const initialState: HrState = {
  employees: [],
  attendance: [],
  leaveRequests: [],
  status: 'idle',
  error: null,
  lastSyncedAt: null,
};

export const loadHr = createAsyncThunk('hr/load', async (_: void, { rejectWithValue }) => {
  try {
    const today = toIsoDate(new Date());
    const [employees, attendance, leaveRequests] = await Promise.all([
      Api.hr.listEmployees(),
      Api.hr.listAttendance(shiftDays(today, -(ATTENDANCE_WINDOW_DAYS - 1)), today),
      Api.hr.listLeaveRequests(),
    ]);
    return { employees, attendance, leaveRequests };
  } catch (e) {
    return rejectWithValue(toApiError(e).message);
  }
});

export const markAttendance = createAsyncThunk(
  'hr/markAttendance',
  async (
    input: {
      employeeId: string;
      date: string;
      status: AttendanceStatus;
      checkIn?: string;
      checkOut?: string;
      note?: string;
      markedBy: User;
    },
    { rejectWithValue },
  ) => {
    try {
      return await Api.hr.markAttendance(input);
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

export const decideLeave = createAsyncThunk(
  'hr/decideLeave',
  async (
    input: { request: LeaveRequest; approve: boolean; decidedBy: User; note?: string },
    { dispatch, rejectWithValue },
  ) => {
    try {
      const decided = await Api.hr.decideLeave(input);
      // An approval writes leave onto the attendance sheet, so the roster on
      // screen is stale the moment the decision lands — pull it straight back.
      if (input.approve) void dispatch(loadHr());
      return decided;
    } catch (e) {
      return rejectWithValue(toApiError(e).message);
    }
  },
);

const hrSlice = createSlice({
  name: 'hr',
  initialState,
  reducers: {},
  extraReducers: (builder) => {
    builder
      .addCase(loadHr.pending, (state) => {
        // A refresh must not blank the roster that is already on screen.
        if (state.status === 'idle') state.status = 'loading';
      })
      .addCase(loadHr.fulfilled, (state, action) => {
        state.status = 'ready';
        state.employees = action.payload.employees;
        state.attendance = action.payload.attendance;
        state.leaveRequests = action.payload.leaveRequests;
        state.lastSyncedAt = new Date().toISOString();
        state.error = null;
      })
      .addCase(loadHr.rejected, (state, action) => {
        state.status = 'failed';
        state.error = (action.payload as string) ?? 'Could not load the HR records.';
      })
      .addCase(markAttendance.fulfilled, (state, action) => {
        const row = action.payload;
        const at = state.attendance.findIndex(
          (r) => r.employeeId === row.employeeId && r.date === row.date,
        );
        if (at >= 0) state.attendance[at] = row;
        else state.attendance.push(row);
      })
      .addCase(markAttendance.rejected, (state, action) => {
        state.error = (action.payload as string) ?? 'Could not mark attendance.';
      })
      .addCase(decideLeave.fulfilled, (state, action) => {
        const at = state.leaveRequests.findIndex((r) => r.id === action.payload.id);
        if (at >= 0) state.leaveRequests[at] = action.payload;
      })
      .addCase(decideLeave.rejected, (state, action) => {
        state.error = (action.payload as string) ?? 'Could not record that decision.';
      });
  },
});

export default hrSlice.reducer;
