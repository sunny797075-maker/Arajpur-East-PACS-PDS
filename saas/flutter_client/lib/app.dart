import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'auth/controller.dart';
import 'auth/models.dart';
import 'ui/login_page.dart';
import 'ui/dashboard_page.dart';
import 'ui/theme.dart';
import 'ui/register_page.dart';

String? routeGuard(AuthController auth, String location) {
  if (auth.initializing) return location == '/loading' ? null : '/loading';
  final session = auth.session;
  if (session == null || session.expired) {
    if (location == '/super-admin/login' ||
        location == '/distributor/login' ||
        location == '/distributor/register') {
      return null;
    }
    return location.startsWith('/super-admin')
        ? '/super-admin/login'
        : '/distributor/login';
  }
  if (location == '/loading' ||
      location == '/' ||
      location.endsWith('/login') ||
      location == '/distributor/register') {
    return session.role.home;
  }
  if (location == '/unauthorized') return null;
  if (location != session.role.home) return '/unauthorized';
  return null;
}

class PdsApp extends StatefulWidget {
  const PdsApp({super.key, required this.auth, this.initialLocation});
  final AuthController auth;
  final String? initialLocation;
  @override
  State<PdsApp> createState() => _PdsAppState();
}

class _PdsAppState extends State<PdsApp> with WidgetsBindingObserver {
  late final GoRouter router = GoRouter(
    initialLocation: widget.initialLocation,
    refreshListenable: widget.auth,
    redirect: (_, state) {
      final location = state.uri.path;
      if (widget.auth.initializing) {
        return location == '/loading'
            ? null
            : '/loading?from=${Uri.encodeComponent(location)}';
      }
      if (location == '/loading') {
        final from = state.uri.queryParameters['from'] ?? '/';
        final safe =
            from.startsWith('/') && !from.startsWith('//') && from != '/loading'
                ? from
                : '/';
        return routeGuard(widget.auth, safe) ?? safe;
      }
      return routeGuard(widget.auth, location);
    },
    routes: [
      GoRoute(path: '/', builder: (_, __) => const SizedBox()),
      GoRoute(
        path: '/distributor/register',
        builder: (_, __) => RegisterPage(auth: widget.auth),
      ),
      GoRoute(
        path: '/loading',
        builder:
            (_, __) => const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
      ),
      for (final role in AccountRole.values) ...[
        GoRoute(
          path: role.login,
          builder:
              (_, __) =>
                  LoginPage(key: ValueKey(role), role: role, auth: widget.auth),
        ),
        GoRoute(
          path: role.home,
          builder: (_, __) => DashboardPage(auth: widget.auth),
        ),
      ],
      GoRoute(
        path: '/unauthorized',
        builder:
            (context, _) => Scaffold(
              body: SafeArea(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.lock_outline, size: 56),
                        const SizedBox(height: 20),
                        const Text(
                          'This workspace is not available to your account.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed:
                              () => context.go(widget.auth.session!.role.home),
                          child: const Text('Return to my dashboard'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
      ),
    ],
    errorBuilder:
        (context, _) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed:
                  () => context.go(
                    widget.auth.session?.role.home ?? '/distributor/login',
                  ),
              child: const Text('Page not found · Go home'),
            ),
          ),
        ),
  );
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        widget.auth.session?.expired == true) {
      widget.auth.renew();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'PDS Connect',
    debugShowCheckedModeBanner: false,
    theme: pdsTheme(),
    routerConfig: router,
  );
}
