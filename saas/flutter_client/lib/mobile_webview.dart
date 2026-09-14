import 'package:flutter/widgets.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Mobile displays only the website; no native application screens.
Future<void> runMobileWebView() async {
  final website = Uri.parse('https://15.252.37.89/');
  final controller = WebViewController();
  await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
  await controller.setNavigationDelegate(
    NavigationDelegate(
      onNavigationRequest: (request) async {
        final uri = Uri.tryParse(request.url);
        if (uri == null) return NavigationDecision.prevent;
        if (uri.scheme == 'tel' || uri.scheme == 'mailto') {
          try {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } catch (_) {
            // Keep the website visible if this device has no handler.
          }
          return NavigationDecision.prevent;
        }
        if (uri.scheme == 'https' &&
            uri.host == website.host &&
            uri.port == website.port) {
          return NavigationDecision.navigate;
        }
        return NavigationDecision.prevent;
      },
    ),
  );
  final platform = controller.platform;
  if (platform is AndroidWebViewController) {
    await platform.setOnShowFileSelector((params) async {
      final selection = await FilePicker.platform.pickFiles(
        allowMultiple: params.mode == FileSelectorMode.openMultiple,
        type: FileType.any,
      );
      return selection?.paths
              .whereType<String>()
              .map((path) => Uri.file(path).toString())
              .toList() ??
          <String>[];
    });
  }
  // Refresh website assets on each cold launch; retain login cookies/storage.
  await controller.clearCache();
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: SafeArea(child: WebViewWidget(controller: controller)),
    ),
  );
  WidgetsBinding.instance.addObserver(_WebViewBackNavigation(controller));
  await controller.loadRequest(website, headers: {'Cache-Control': 'no-cache'});
}

class _WebViewBackNavigation extends WidgetsBindingObserver {
  _WebViewBackNavigation(this.controller);
  final WebViewController controller;
  @override
  Future<bool> didPopRoute() async {
    if (await controller.canGoBack()) {
      await controller.goBack();
      return true;
    }
    return false;
  }
}
