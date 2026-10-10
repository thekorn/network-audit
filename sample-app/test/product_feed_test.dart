import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_audit_sample/product_api.dart';
import 'package:network_audit_sample/product_feed.dart';

void main() {
  testWidgets(
    'shows failures and allows a new batch without overlapping loads',
    (tester) async {
      final api = _ControlledApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ProductFeed(api: api)),
        ),
      );

      expect(find.text('Sending 10 GETs…'), findsOneWidget);
      await tester.tap(find.text('Sending 10 GETs…'));
      await tester.pump();
      expect(api.batches, hasLength(1));

      api.batches.single.complete([
        for (var id = 1; id <= 10; id++) ProductFailed(id, 'HTTP 503'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('0 / 10 loaded · 10 failed'), findsOneWidget);
      expect(find.text('Product 1 unavailable'), findsOneWidget);

      await tester.tap(find.text('Run 10 GETs again'));
      await tester.pump();
      expect(api.batches, hasLength(2));
      await tester.tap(find.text('Sending 10 GETs…'));
      expect(api.batches, hasLength(2));

      api.batches.last.complete([
        for (var id = 1; id <= 10; id++)
          ProductLoaded(
            id,
            Product(
              title: 'Product $id',
              category: 'beauty',
              price: 12.50,
              thumbnail: 'https://example.com/$id.png',
            ),
          ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('10 / 10 loaded · 0 failed'), findsOneWidget);
      expect(find.text('Product 1'), findsOneWidget);
      expect(find.text('Product 1 unavailable'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a batch finishing after the feed is removed is harmless', (
    tester,
  ) async {
    final api = _ControlledApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ProductFeed(api: api)),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    api.batches.single.complete(const []);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

class _ControlledApi extends ProductApi {
  final batches = <Completer<List<ProductResult>>>[];

  @override
  Future<List<ProductResult>> loadProducts() {
    final batch = Completer<List<ProductResult>>();
    batches.add(batch);
    return batch.future;
  }
}
