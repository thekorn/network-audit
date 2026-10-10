import 'dart:async';
import 'dart:convert';
import 'dart:io';

class Product {
  const Product({
    required this.title,
    required this.category,
    required this.price,
    required this.thumbnail,
  });

  final String title;
  final String category;
  final double price;
  final String thumbnail;

  factory Product.fromJson(Object? json) {
    if (json case {
      'title': String title,
      'category': String category,
      'price': num price,
      'thumbnail': String thumbnail,
    }) {
      return Product(
        title: title,
        category: category,
        price: price.toDouble(),
        thumbnail: thumbnail,
      );
    }
    throw const FormatException('Invalid product response');
  }
}

sealed class ProductResult {
  const ProductResult(this.id);

  final int id;
}

class ProductLoaded extends ProductResult {
  const ProductLoaded(super.id, this.product);

  final Product product;
}

class ProductFailed extends ProductResult {
  const ProductFailed(super.id, this.message);

  final String message;
}

/// Each batch makes ten independent GETs, without automatic retries or caching.
class ProductApi {
  ProductApi({Uri? baseUri, this.timeout = const Duration(seconds: 20)})
    : baseUri = baseUri ?? Uri.parse('https://dummyjson.com/');

  static const requestCount = 10;
  final Uri baseUri;
  final Duration timeout;
  final _client = HttpClient();

  Future<List<ProductResult>> loadProducts() => Future.wait([
    for (var id = 1; id <= requestCount; id++) _loadProduct(id),
  ]);

  Future<ProductResult> _loadProduct(int id) async {
    HttpClientRequest? request;
    var timedOut = false;

    Future<ProductResult> fetch() async {
      final outgoing = await _client.getUrl(baseUri.resolve('/products/$id'));
      request = outgoing;
      if (timedOut) {
        outgoing.abort();
        throw TimeoutException('Request timed out');
      }
      outgoing.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await outgoing.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return ProductFailed(id, 'HTTP ${response.statusCode}');
      }
      final body = await utf8.decoder.bind(response).join();
      return ProductLoaded(id, Product.fromJson(jsonDecode(body)));
    }

    try {
      return await fetch().timeout(
        timeout,
        onTimeout: () {
          timedOut = true;
          request?.abort();
          throw TimeoutException('Request timed out');
        },
      );
    } on TimeoutException {
      return ProductFailed(id, 'Request timed out');
    } on FormatException {
      return ProductFailed(id, 'Invalid product response');
    } on IOException {
      return ProductFailed(id, 'Could not connect. Check your network.');
    }
  }

  void close() => _client.close(force: true);
}
