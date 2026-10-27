import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

class BunteView extends StatefulWidget {
  const BunteView({super.key});

  @override
  State<BunteView> createState() => _BunteViewState();
}

class _BunteViewState extends State<BunteView> {
  static final _home = Uri.parse('https://www.bunte.de');
  static final _auditGate =
      const bool.fromEnvironment('NETWORK_AUDIT_WEBVIEW_GATE') &&
      kDebugMode &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  late final WebViewController _controller;
  var _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await _controller.setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _error = null;
              _progress = 0;
            });
          },
          onPageFinished: (url) async {
            if (_auditGate && url == 'about:blank') {
              // Capture must not race this initial load with its navigation.
              await _controller.runJavaScript(
                'window.__networkAuditGateReady = true',
              );
            }
          },
          onWebResourceError: (error) {
            // Ads and other subresources can fail without breaking the page.
            if (mounted && error.isForMainFrame == true) {
              setState(
                () =>
                    _error = 'Could not load this page. Check your connection.',
              );
            }
          },
          onNavigationRequest: (request) {
            // The audit runner installs its observer before navigating.
            if (_auditGate && request.url == 'about:blank') {
              return NavigationDecision.navigate;
            }
            final scheme = Uri.tryParse(request.url)?.scheme;
            return scheme == 'https' || scheme == 'http'
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      );
      await _controller.loadRequest(
        _auditGate ? Uri.parse('about:blank') : _home,
      );
    } on PlatformException {
      if (mounted) {
        setState(() => _error = 'Could not start the WebView. Try again.');
      }
    }
  }

  Future<void> _reload() async {
    setState(() {
      _error = null;
      _progress = 0;
    });
    await _controller.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Go back',
                onPressed: () async {
                  if (await _controller.canGoBack()) await _controller.goBack();
                },
                icon: const Icon(Icons.arrow_back),
              ),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'www.bunte.de',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      'WEBVIEW',
                      style: TextStyle(fontSize: 10, letterSpacing: 1),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'BUNTE home',
                onPressed: () => _controller.loadRequest(_home),
                icon: const Icon(Icons.home_outlined),
              ),
              IconButton(
                tooltip: 'Reload website',
                onPressed: _reload,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (_error case final error?)
          MaterialBanner(
            content: Text(error),
            actions: [
              TextButton(onPressed: _initialize, child: const Text('Retry')),
            ],
          )
        else if (_progress < 100)
          LinearProgressIndicator(value: _progress / 100),
        Expanded(child: WebViewWidget(controller: _controller)),
      ],
    );
  }
}
