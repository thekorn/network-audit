import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_audit_sample/product_api.dart';

void main() {
  late HttpServer server;
  late ProductApi api;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    api = ProductApi(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      timeout: const Duration(seconds: 2),
    );
  });

  tearDown(() async {
    api.close();
    await server.close(force: true);
  });

  test(
    'each batch sends ten separate GETs and returns products in ID order',
    () async {
      final received = <String>[];
      var batch = <HttpRequest>[];
      server.listen((request) async {
        received.add('${request.method} ${request.uri.path}');
        batch.add(request);
        // Respond only once all ten arrive, also verifying concurrent dispatch.
        if (batch.length != 10) return;
        final pending = batch.reversed.toList();
        batch = [];
        for (final request in pending) {
          final id = int.parse(request.uri.pathSegments.last);
          request.response.write(jsonEncode(_product(id)));
          await request.response.close();
        }
      });

      for (var run = 1; run <= 2; run++) {
        final results = await api.loadProducts();
        expect(results.map((result) => result.id), [
          1,
          2,
          3,
          4,
          5,
          6,
          7,
          8,
          9,
          10,
        ]);
        expect(results.whereType<ProductLoaded>(), hasLength(10));
        final seventh = (results[6] as ProductLoaded).product;
        expect(seventh.title, 'Product 7');
        expect(seventh.price, 18.25);
        expect(seventh.thumbnail, 'https://example.com/7.png');
        expect(received, hasLength(run * 10));
        for (var id = 1; id <= 10; id++) {
          expect(
            received.where((entry) => entry == 'GET /products/$id'),
            hasLength(run),
          );
        }
      }
    },
  );

  test(
    'HTTP, malformed, and timed-out responses preserve successful products',
    () async {
      server.listen((request) async {
        final id = int.parse(request.uri.pathSegments.last);
        switch (id) {
          case 3:
            request.response.statusCode = 503;
          case 7:
            request.response.write('{invalid json');
          case 9:
            request.response.write('{"title": 42}');
          case 10:
            // Keep the body open: the timeout must cover the entire response.
            request.response.write('{');
            await request.response.flush();
            return;
          default:
            request.response.write(jsonEncode(_product(id)));
        }
        await request.response.close();
      });

      final results = await api.loadProducts();
      expect(results.whereType<ProductLoaded>().map((result) => result.id), [
        1,
        2,
        4,
        5,
        6,
        8,
      ]);
      final failures = results.whereType<ProductFailed>().toList();
      expect(failures.map((result) => result.id), [3, 7, 9, 10]);
      expect(failures.map((result) => result.message), [
        'HTTP 503',
        'Invalid product response',
        'Invalid product response',
        'Request timed out',
      ]);
    },
  );
}

Map<String, Object> _product(int id) => {
  'title': 'Product $id',
  'category': 'test category',
  'price': 11.25 + id,
  'thumbnail': 'https://example.com/$id.png',
};
