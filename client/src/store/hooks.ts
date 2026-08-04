import { useDispatch, useSelector } from 'react-redux';
import type { AppDispatch, RootState } from './index';

/** Typed `useDispatch` — knows about thunks, so `await dispatch(...)` works. */
export const useAppDispatch: () => AppDispatch = useDispatch;
export const useAppSelector = useSelector.withTypes<RootState>();
