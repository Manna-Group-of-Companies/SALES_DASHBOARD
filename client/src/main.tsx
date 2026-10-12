import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { BrowserRouter } from 'react-router-dom';
import { store } from './store';
import { revalidateSession } from './store/slices/authSlice';
import { AppRoutes } from './app/routes';
import './styles/global.css';

// The restored user is only a cache; confirm the session behind it is still
// alive before the shell renders screens that would all fail with 403.
store.dispatch(revalidateSession());

const container = document.getElementById('root');
if (!container) throw new Error('#root is missing from index.html');

createRoot(container).render(
  <StrictMode>
    <Provider store={store}>
      <BrowserRouter>
        <AppRoutes />
      </BrowserRouter>
    </Provider>
  </StrictMode>,
);
