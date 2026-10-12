import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/app_lock.dart';

/// Covers the whole app with the lock screen while [AppLock.locked] is set,
/// and watches the app going to and from the background so it can re-lock.
///
/// Sits in `MaterialApp.builder`, above the Navigator, so no route — however
/// it was pushed — can show through.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child});
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        AppLock.onBackgrounded();
      case AppLifecycleState.resumed:
        AppLock.onResumed();
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppLock.locked,
      builder: (context, locked, _) => Stack(children: [
        ExcludeSemantics(excluding: locked, child: widget.child),
        // Above the Navigator there is no Overlay, and a TextField needs one.
        if (locked)
          Positioned.fill(
            child: Overlay(initialEntries: [
              OverlayEntry(builder: (_) => const _LockScreen()),
            ]),
          ),
      ]),
    );
  }
}

class _LockScreen extends StatefulWidget {
  const _LockScreen();
  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  final _password = TextEditingController();
  bool _busy = false;
  bool _usePassword = false;
  bool _obscure = true;
  String? _message;

  @override
  void initState() {
    super.initState();
    // Ask straight away; the rep should only ever have to touch the sensor.
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final outcome = await AppLock.unlock();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (outcome == UnlockOutcome.lockedOut) {
        _message = 'Too many attempts. Use your password, '
            'or try again in a little while.';
        _usePassword = true;
      }
    });
  }

  Future<void> _unlockWithPassword() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await AppLock.unlockWithPassword(_password.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) _message = 'That is not the password for this login.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Center(
                child: Image.asset(
                  'assets/manna_logo.png',
                  height: 80,
                  errorBuilder: (_, _, _) => const Text('MANNA',
                      style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFFF46A21))),
                ),
              ),
              const SizedBox(height: 32),
              Center(
                child: IconButton.filledTonal(
                  iconSize: 56,
                  padding: const EdgeInsets.all(20),
                  tooltip: 'Unlock',
                  onPressed: _busy ? null : _unlock,
                  icon: const Icon(Icons.fingerprint),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Unlock with your fingerprint, face or phone screen lock',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.black54),
              ),
              if (_message != null) ...[
                const SizedBox(height: 16),
                Text(_message!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 24),
              if (!_usePassword)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _usePassword = true;
                            _message = null;
                          }),
                  child: const Text('Use password instead'),
                )
              else ...[
                TextField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: _obscure,
                  autofocus: true,
                  onSubmitted: (_) => _unlockWithPassword(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      tooltip: _obscure ? 'Show password' : 'Hide password',
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _busy ? null : _unlockWithPassword,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Unlock'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
