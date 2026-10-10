import 'package:flutter/material.dart';

import 'product_api.dart';

class ProductFeed extends StatefulWidget {
  const ProductFeed({required this.api, super.key});

  final ProductApi api;

  @override
  State<ProductFeed> createState() => _ProductFeedState();
}

class _ProductFeedState extends State<ProductFeed> {
  var _loading = false;
  List<ProductResult> _results = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() => _loading = true);
    final results = await widget.api.loadProducts();
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final loaded = _results.whereType<ProductLoaded>().length;
    final failed = _results.whereType<ProductFailed>().length;
    final theme = Theme.of(context);

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        key: const PageStorageKey('product-feed'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: const Color(0xFF103F39),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'NATIVE FLUTTER  /  DUMMYJSON',
                  style: TextStyle(
                    color: Color(0xFFACE6CC),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Ten requests.\nA little window shopping.',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '10 separate product GETs per batch.\nImages make extra requests.',
                  style: TextStyle(color: Color(0xFFD0E5DD), height: 1.5),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _loading ? null : _refresh,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB7F1D5),
                    foregroundColor: const Color(0xFF103F39),
                    disabledBackgroundColor: const Color(0xFF315A52),
                    disabledForegroundColor: Colors.white70,
                  ),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(
                    _loading ? 'Sending 10 GETs…' : 'Run 10 GETs again',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Product feed',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Text('GET', style: TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _loading
                ? 'Loading dummyjson.com/products/1 … /10'
                : '$loaded / 10 loaded · $failed failed',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (_loading) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 16),
          ],
          for (final result in _results) ...[
            _ProductCard(result: result),
            const SizedBox(height: 12),
          ],
          if (!_loading && failed > 0)
            const Text(
              'Some requests failed. Pull down or run a new batch to retry.',
            ),
        ],
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.result});

  final ProductResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFFE2E8E4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: switch (result) {
          ProductLoaded(:final product) => Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: ColoredBox(
                  color: const Color(0xFFF3F5F2),
                  child: Image.network(
                    product.thumbnail,
                    width: 96,
                    height: 112,
                    fit: BoxFit.contain,
                    semanticLabel: product.title,
                    errorBuilder: (_, _, _) => const SizedBox(
                      width: 96,
                      height: 112,
                      child: Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.category.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(product.title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Text(
                      '\$${product.price.toStringAsFixed(2)}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'GET /products/${result.id}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          ProductFailed(:final id, :final message) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.cloud_off, color: theme.colorScheme.error),
            title: Text('Product $id unavailable'),
            subtitle: Text('GET /products/$id\n$message'),
            isThreeLine: true,
          ),
        },
      ),
    );
  }
}
