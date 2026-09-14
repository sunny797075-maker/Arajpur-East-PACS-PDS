import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../auth/controller.dart';
import '../auth/models.dart';
import 'theme.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.role, required this.auth});
  final AccountRole role;
  final AuthController auth;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _id = TextEditingController(), _password = TextEditingController();
  bool _hidden = true,
      _remember = false,
      _recovery = false,
      _recovering = false;
  String? _message;
  bool get admin => widget.role == AccountRole.superAdmin;
  String get idLabel => admin ? 'Email or Admin ID' : 'Email or Mobile Number';
  @override
  void initState() {
    super.initState();
    _loadIdentifier();
  }

  Future<void> _loadIdentifier() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || _id.text.isNotEmpty) return;
    final saved = prefs.getString('pds_id_${widget.role.path}');
    if (saved != null && (admin || !saved.toUpperCase().startsWith('DIST-'))) {
      setState(() {
        _id.text = saved;
        _remember = true;
      });
    }
  }

  @override
  void dispose() {
    _id.dispose();
    _password.dispose();
    super.dispose();
  }

  String? validateId(String? value) {
    final id = value?.trim() ?? '';
    if (id.isEmpty) return 'Enter your $idLabel.';
    if (id.length > 254) return 'The ID is too long.';
    if (!admin &&
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(id) &&
        !RegExp(
          r'^(?:[6-9]\d{9}|91[6-9]\d{9}|\+[1-9]\d{6,14})$',
        ).hasMatch(id.replaceAll(RegExp(r'[\s()-]'), ''))) {
      return 'Enter your registered email or mobile number.';
    }
    if (admin &&
        id.contains('@') &&
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(id)) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    if (_recovery) {
      setState(() {
        _recovering = true;
        _message = null;
      });
      try {
        await widget.auth.repository.forgotPassword(
          widget.role,
          _id.text.trim(),
        );
        if (mounted) {
          setState(
            () =>
                _message =
                    widget.auth.repository.isDemo
                        ? 'Preview only: no email was sent. The demo password is Preview@12345.'
                        : 'If this account exists, recovery instructions have been sent to its registered contact.',
          );
        }
      } catch (e) {
        if (mounted) {
          setState(
            () =>
                _message =
                    e is AuthFailure
                        ? e.message
                        : 'Recovery is unavailable. Try again.',
          );
        }
      } finally {
        if (mounted) setState(() => _recovering = false);
      }
      return;
    }
    final identifier = _id.text.trim();
    final remember = _remember;
    final success = await widget.auth.login(
      widget.role,
      identifier,
      _password.text,
      remember,
    );
    if (success) {
      final prefs = await SharedPreferences.getInstance();
      if (remember) {
        await prefs.setString('pds_id_${widget.role.path}', identifier);
      } else {
        await prefs.remove('pds_id_${widget.role.path}');
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.auth,
    builder: (context, _) {
      final busy = widget.auth.busy || _recovering;
      return Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 960;
              final form = ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!wide) ...[const Brand(), const SizedBox(height: 34)],
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE5EEE5),
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: Text(
                        admin
                            ? 'PLATFORM ACCESS'
                            : 'YOUR DISTRIBUTOR WORKSPACE',
                        style: const TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.2,
                          color: green,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _recovery
                          ? 'Reset your password'
                          : admin
                          ? 'Super Admin Login'
                          : 'Distributor Login',
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        color: ink,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _recovery
                          ? 'Enter your account ID to request recovery instructions.'
                          : admin
                          ? 'Welcome back. Keep your distributor network running smoothly.'
                          : 'Welcome back. Sign in to your own PDS workspace.',
                      style: const TextStyle(
                        color: Color(0xFF5A6F65),
                        height: 1.6,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Form(
                      key: _form,
                      child: AutofillGroup(
                        child: Column(
                          children: [
                            TextFormField(
                              controller: _id,
                              enabled: !busy,
                              validator: validateId,
                              autofillHints: const [AutofillHints.username],
                              textInputAction:
                                  _recovery
                                      ? TextInputAction.done
                                      : TextInputAction.next,
                              autocorrect: false,
                              decoration: InputDecoration(
                                labelText: idLabel,
                                hintText:
                                    admin
                                        ? 'Your email or admin ID'
                                        : 'you@example.com or mobile number',
                                prefixIcon: Icon(
                                  admin
                                      ? Icons.admin_panel_settings_outlined
                                      : Icons.badge_outlined,
                                ),
                              ),
                              onFieldSubmitted: (_) {
                                if (_recovery && !busy) _submit();
                              },
                            ),
                            if (!_recovery) ...[
                              const SizedBox(height: 20),
                              TextFormField(
                                controller: _password,
                                enabled: !busy,
                                obscureText: _hidden,
                                autofillHints: const [AutofillHints.password],
                                enableSuggestions: false,
                                autocorrect: false,
                                textInputAction: TextInputAction.done,
                                validator:
                                    (value) =>
                                        value == null || value.isEmpty
                                            ? 'Enter your password.'
                                            : null,
                                onFieldSubmitted: (_) {
                                  if (!busy) _submit();
                                },
                                decoration: InputDecoration(
                                  labelText: 'Password',
                                  prefixIcon: const Icon(Icons.lock_outline),
                                  suffixIcon: IconButton(
                                    tooltip:
                                        _hidden
                                            ? 'Show password'
                                            : 'Hide password',
                                    onPressed:
                                        busy
                                            ? null
                                            : () => setState(
                                              () => _hidden = !_hidden,
                                            ),
                                    icon: Icon(
                                      _hidden
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 8,
                                children: [
                                  InkWell(
                                    onTap:
                                        busy
                                            ? null
                                            : () => setState(
                                              () => _remember = !_remember,
                                            ),
                                    borderRadius: BorderRadius.circular(8),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Checkbox(
                                          value: _remember,
                                          onChanged:
                                              busy
                                                  ? null
                                                  : (value) => setState(
                                                    () => _remember = value!,
                                                  ),
                                        ),
                                        const Text('Remember me'),
                                      ],
                                    ),
                                  ),
                                  TextButton(
                                    onPressed:
                                        busy
                                            ? null
                                            : () => setState(() {
                                              _recovery = true;
                                              _message = null;
                                            }),
                                    child: const Text('Forgot password?'),
                                  ),
                                ],
                              ),
                            ],
                            if (_message != null) ...[
                              const SizedBox(height: 16),
                              Notice(_message!),
                            ],
                            if (!_recovery && widget.auth.error != null) ...[
                              const SizedBox(height: 16),
                              Notice(widget.auth.error!, error: true),
                            ],
                            const SizedBox(height: 20),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: busy ? null : _submit,
                                child:
                                    busy
                                        ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                        : Text(
                                          _recovery
                                              ? 'Send recovery instructions'
                                              : 'Sign in',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 16,
                                          ),
                                        ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (!admin && !_recovery)
                      Center(
                        child: TextButton(
                          onPressed:
                              busy
                                  ? null
                                  : () => context.go('/distributor/register'),
                          child: const Text(
                            'New distributor? Create an account',
                          ),
                        ),
                      ),
                    if (_recovery)
                      Center(
                        child: TextButton(
                          onPressed:
                              busy
                                  ? null
                                  : () {
                                    if (_recovery) {
                                      setState(() {
                                        _recovery = false;
                                        _message = null;
                                      });
                                    }
                                  },
                          child: const Text('Back to sign in'),
                        ),
                      ),
                    if (widget.auth.repository.isDemo) ...[
                      const SizedBox(height: 18),
                      Notice(
                        'DEMO PREVIEW · No real accounts or data\n${admin ? 'admin@pds.demo or ADMIN-001' : 'distributor1@pds.demo or 9876543210'}\nPassword: Preview@12345\nRemember me saves your ID only in this preview.',
                      ),
                    ],
                    const SizedBox(height: 28),
                    const Text(
                      'Powered by MENHI GLOBAL TECH',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: Color(0xFF63776E),
                      ),
                    ),
                  ],
                ),
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (wide)
                    Expanded(
                      flex: 5,
                      child: Container(
                        color: ink,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(48),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Brand(light: true),
                              const SizedBox(height: 88),
                              const Icon(
                                Icons.grass_rounded,
                                size: 100,
                                color: Color(0xFFDFC77F),
                              ),
                              const SizedBox(height: 24),
                              Text(
                                admin
                                    ? 'A stronger network.\nA better service.'
                                    : 'Local service.\nThoughtfully connected.',
                                style: const TextStyle(
                                  fontSize: 42,
                                  height: 1.15,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 24),
                              Text(
                                admin
                                    ? 'One place for distributor accounts, subscriptions and platform oversight.'
                                    : 'A dedicated workspace for the people who keep their communities supplied.',
                                style: const TextStyle(
                                  fontSize: 17,
                                  height: 1.7,
                                  color: Colors.white70,
                                ),
                              ),
                              const SizedBox(height: 56),
                              const Divider(color: Colors.white24),
                              const SizedBox(height: 20),
                              const Text(
                                'BUILT AROUND TRUST',
                                style: TextStyle(
                                  color: Color(0xFFDFC77F),
                                  letterSpacing: 2,
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'Separate workspaces. Clear responsibilities.',
                                style: TextStyle(
                                  color: Colors.white70,
                                  height: 1.6,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    flex: 6,
                    child: SingleChildScrollView(
                      padding: EdgeInsets.symmetric(
                        horizontal: constraints.maxWidth < 400 ? 20 : 40,
                        vertical: 40,
                      ),
                      child: Center(child: form),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}
