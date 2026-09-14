import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'mobile_webview.dart';
import 'app.dart';
import 'auth/api_repository.dart';
import 'auth/controller.dart';
import 'auth/demo_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    await runMobileWebView();
    return;
  }
  const demo = bool.fromEnvironment('PDS_DEMO');
  const api = String.fromEnvironment('PDS_API_URL');
  final auth = AuthController(
    demo ? DemoAuthRepository() : ApiAuthRepository(api),
  );
  runApp(PdsApp(auth: auth));
  auth.initialize();
}
