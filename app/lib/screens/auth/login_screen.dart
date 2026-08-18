import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/auth_store.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/auth/update_required_screen.dart';
import 'package:manna_field_sales/screens/home/home_dashboard.dart';
import 'package:manna_field_sales/services/api.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _url = TextEditingController(text: Session.I.baseUrl);
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _showUrl = false;
  bool _obscurePassword = true;
  // Show the splash — not the login form — until we know whether the saved
  // credentials still work. Otherwise the form flashes up on every cold start.
  bool _restoring = true;
  // Set once a resume attempt has failed on the network, so the splash can
  // say why it is still spinning.
  bool _waiting = false;
  // Offers a manual way onto the login form after repeated failures.
  bool _stuck = false;
  // Stops the resume loop when the rep opts out of it.
  bool _abandon = false;

  void _showUrlField() => setState(() => _showUrl = !_showUrl);

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  static bool get _hasRole =>
      Session.I.salesPerson != null ||
      Session.I.isManager ||
      Session.I.isGM ||
      Session.I.isHR ||
      Session.I.isProductionManager ||
      Session.I.isStockManager;

  /// The one door into the app, for both the resume path and a fresh login.
  ///
  /// The version check sits here rather than on the dashboard so a build the
  /// backend has retired never reaches a screen that can write. It fails open:
  /// a settings row that will not load leaves the rep working.
  Future<void> _goHome() async {
    final gate = await Api.appVersionGate();
    if (!mounted) return;
    if (gate.blocked) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => UpdateRequiredScreen(gate: gate, onRetry: _goHome)));
      return;
    }
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeDashboard()));
  }

  Future<AuthState> _restoreSession() async {
    final state = await Api.restore();
    if (state != AuthState.ok) return state;
    try {
      await Api.resolveMySalesPerson();
      await Api.resolveManagerContext();
    } on DioException {
      return AuthState.unreachable;
    }
    return _hasRole ? AuthState.ok : AuthState.rejected;
  }

  Future<void> _loadSaved() async {
    final c = await AuthStore.load();
    _url.text = c.baseUrl.isEmpty ? Session.I.baseUrl : c.baseUrl;
    _email.text = c.email;
    // Nothing to resume with: first ever launch, or the rep logged out on
    // purpose. Those are the only two ways to reach the login form.
    if (!c.hasToken && !c.canReauth) {
      if (mounted) setState(() => _restoring = false);
      return;
    }
    await _resume();
  }

  /// Escape hatch from [_resume] — the rep asking for the form is the one
  /// case besides logout where we are allowed to show it.
  Future<void> _useAnotherAccount() async {
    _abandon = true;
    await AuthStore.clear();
    _password.clear();
    if (mounted) {
      setState(() {
        _restoring = false;
        _waiting = false;
        _stuck = false;
      });
    }
  }

  /// Get back onto an authenticated session, however long it takes.
  ///
  /// A rep who has logged in once should never be asked again, so a flat
  /// network is treated as something to wait out behind the splash rather
  /// than a reason to sign them out. Only a credential the server actually
  /// refuses drops through to the login form.
  Future<void> _resume() async {
    for (var attempt = 1; !_abandon; attempt++) {
      AuthState state;
      try {
        // Bounded per attempt: the calls inside can each sit on a 20s
        // timeout, and we would rather retry than stall on one dead socket.
        state = await _restoreSession().timeout(const Duration(seconds: 25),
            onTimeout: () => AuthState.unreachable);
      } catch (_) {
        state = AuthState.unreachable;
      }
      if (!mounted) return;
      if (state == AuthState.ok) {
        await _goHome();
        return;
      }
      if (state == AuthState.rejected) {
        // Stop retrying a credential the server refuses, and make the rep's
        // next login the one that re-establishes it.
        await AuthStore.clear();
        if (mounted) {
          setState(() {
            _restoring = false;
            _error = 'Your saved sign-in is no longer valid. '
                'Please log in again.';
          });
        }
        return;
      }
      setState(() {
        _waiting = true;
        // Never shown automatically, but after a few failed attempts give the
        // rep a way out rather than trapping them on a spinner.
        _stuck = attempt >= 3;
      });
      await Future<void>.delayed(_backoff(attempt));
      if (!mounted) return;
    }
  }

  // Ease off quickly at first, then settle at 30s so a rep who walks back
  // into coverage is picked up promptly without hammering a dead network.
  static Duration _backoff(int attempt) => Duration(
      seconds: switch (attempt) { 1 => 2, 2 => 4, 3 => 8, 4 => 15, _ => 30 });

  Future<void> _login() async {
    // Guard the handler itself, not just the button: a fast double-tap can
    // land two taps before the disabled state rebuilds.
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      Session.I.baseUrl = _url.text.trim();
      Session.I.init();
      Api.attachAutoReauth();
      await Api.login(_email.text.trim(), _password.text);
      // Credentials accepted. Hand over to the splash so the form is not left
      // sitting there looking frozen while the roles resolve.
      if (mounted) setState(() => _restoring = true);
      await Api.resolveMySalesPerson();
      await Api.resolveManagerContext();
      if (!_hasRole) {
        throw Exception(
            'This login is not linked to a Sales Person or team. Contact admin.');
      }
      if (mounted) await _goHome();
    } catch (e) {
      // Back to the form with the reason spelled out.
      if (mounted) {
        setState(() {
          _error = _readable(e);
          _restoring = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _readable(Object e) {
    if (e is DioException) {
      return 'Could not reach the server. Check your connection and try again.';
    }
    final s = '$e'.replaceFirst('Exception: ', '').trim();
    return s.isEmpty ? 'Login failed. Please try again.' : s;
  }

  static Widget get _logo => Image.asset(
        'assets/manna_logo.png',
        height: 96,
        errorBuilder: (_, __, ___) => const Text(
          'MANNA',
          style: TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w900,
              color: Color(0xFFF46A21)),
        ),
      );

  static const _tagline = Text('Field Sales',
      style: TextStyle(
          fontSize: 16,
          letterSpacing: 2,
          color: Color(0xFF3F3F3F),
          fontWeight: FontWeight.w600));

  Widget _splash() => Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _logo,
            const SizedBox(height: 8),
            _tagline,
            const SizedBox(height: 36),
            const SizedBox(
                height: 24,
                width: 24,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFFF46A21))),
            if (_waiting) ...[
              const SizedBox(height: 20),
              const Text('Waiting for network…',
                  style: TextStyle(fontSize: 13, color: Colors.black54)),
              const SizedBox(height: 4),
              const Text('You are still signed in.',
                  style: TextStyle(fontSize: 12, color: Colors.black38)),
            ],
            if (_stuck)
              TextButton(
                onPressed: _useAnotherAccount,
                child: const Text('Log in with a different account',
                    style: TextStyle(fontSize: 12)),
              ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_restoring) return _splash();
    return Scaffold(
      backgroundColor: Colors.white,
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: ListView(children: [
          const SizedBox(height: 48),
          Center(child: _logo),
          const SizedBox(height: 8),
          const Center(child: _tagline),
          const SizedBox(height: 36),
          TextField(
              controller: _email,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
              controller: _password,
              enabled: !_busy,
              obscureText: _obscurePassword,
              onSubmitted: (_) => _login(),
              decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    tooltip:
                    _obscurePassword ? 'Show password' : 'Hide password',
                    onPressed: _busy
                        ? null
                        : () => setState(
                            () => _obscurePassword = !_obscurePassword),
                  ),
                  border: const OutlineInputBorder())),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : _showUrlField,
              child: const Text('Server settings',
                  style: TextStyle(fontSize: 12)),
            ),
          ),
          if (_showUrl)
            TextField(
                controller: _url,
                enabled: !_busy,
                decoration: const InputDecoration(
                    labelText: 'ERPNext URL', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child:
                Text(_error!, style: const TextStyle(color: Colors.red))),
          FilledButton(
            onPressed: _busy ? null : _login,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _busy
                  ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
                  : const Text('Log in'),
            ),
          ),
        ]),
      ),
    );
  }
}

// -------------------- HOME DASHBOARD --------------------
