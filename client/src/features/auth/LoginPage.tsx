import { useState } from 'react';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import { signIn } from '@/store/slices/authSlice';
import { Alert, Button, Card, Field, Input } from '@/components/ui';
import './login.css';

export function LoginPage() {
  const dispatch = useAppDispatch();
  const { status, error } = useAppSelector((s) => s.auth);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');

  const submitting = status === 'loading';

  return (
    <div className="login">
      <div className="login__panel">
        <div className="login__brand">
          <div className="sidebar__logo" style={{ width: 38, height: 38, fontSize: 15 }}>
            MT
          </div>
          <div>
            <h1>Manna Treads</h1>
            <p className="muted small">Sales &amp; Production module</p>
          </div>
        </div>

        <Card>
          <form
            className="stack gap-3"
            onSubmit={(e) => {
              e.preventDefault();
              if (!email.trim() || !password) return;
              void dispatch(signIn({ email, password }));
            }}
          >
            <Field label="Email" htmlFor="email">
              <Input
                id="email"
                type="email"
                autoComplete="username"
                placeholder="you@mannarubber.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                disabled={submitting}
                required
                autoFocus
              />
            </Field>

            <Field label="Password" htmlFor="password">
              <Input
                id="password"
                type="password"
                autoComplete="current-password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                disabled={submitting}
                required
              />
            </Field>

            {error && <Alert tone="danger">{error}</Alert>}

            <Button
              variant="primary"
              size="lg"
              block
              type="submit"
              loading={submitting}
              disabled={!email.trim() || !password}
            >
              Sign in
            </Button>
          </form>
        </Card>

        <p className="tiny dim center">
          Your role decides what you see. Contact the Sales Manager if you need access.
        </p>
      </div>
    </div>
  );
}
