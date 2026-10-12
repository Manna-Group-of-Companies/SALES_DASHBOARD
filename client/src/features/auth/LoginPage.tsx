import { useState } from 'react';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import { signIn } from '@/store/slices/authSlice';
import { Alert, Button, Card, Field, Input } from '@/components/ui';
import logoInk from '@/assets/manna-logo.png';
import logoWhite from '@/assets/manna-logo-white.png';
import './login.css';

export function LoginPage() {
  const dispatch = useAppDispatch();
  const { status, error } = useAppSelector((s) => s.auth);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');

  const submitting = status === 'loading';

  return (
    <div className="login">
      <aside className="login__hero">
        <img className="login__hero-logo" src={logoWhite} alt="Manna Group" />
        <div className="login__hero-line">Sales &amp; Production</div>
      </aside>

      <div className="login__panel">
        <img className="login__logo login__logo--ink" src={logoInk} alt="Manna Group" />
        <img className="login__logo login__logo--white" src={logoWhite} alt="" />
        <h1 className="login__title">Sign in</h1>

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
      </div>
    </div>
  );
}
