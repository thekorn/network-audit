import 'package:flutter/material.dart';

import 'bunte_view.dart';
import 'product_api.dart';
import 'product_feed.dart';

void main() {
  runApp(const NetworkSampleApp());
}

class NetworkSampleApp extends StatelessWidget {
  const NetworkSampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Network sample',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF006C60)),
        scaffoldBackgroundColor: const Color(0xFFF5F7F6),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF5F7F6),
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const _SampleHome(),
    );
  }
}

class _SampleHome extends StatefulWidget {
  const _SampleHome();

  @override
  State<_SampleHome> createState() => _SampleHomeState();
}

class _SampleHomeState extends State<_SampleHome> {
  final _api = ProductApi();
  var _selectedTab = 0;
  var _webViewVisited = false;

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const Icon(Icons.hub_outlined),
        title: const Text('Network sample'),
      ),
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _selectedTab,
          children: [
            ProductFeed(api: _api),
            // Keep both views alive, but don't load BUNTE before it is opened.
            if (_webViewVisited) const BunteView() else const SizedBox.shrink(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (index) => setState(() {
          _selectedTab = index;
          _webViewVisited = _webViewVisited || index == 1;
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.shopping_bag_outlined),
            selectedIcon: Icon(Icons.shopping_bag),
            label: 'Products',
          ),
          NavigationDestination(
            icon: Icon(Icons.language_outlined),
            selectedIcon: Icon(Icons.language),
            label: 'BUNTE',
          ),
        ],
      ),
    );
  }
}
