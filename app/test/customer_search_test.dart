// Finding a customer in the list.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/customer_search.dart';

final _renjith = {
  'name': 'CUST-00042',
  'customer_name': 'Renjith Tyres',
  'customer_group': 'Dealer',
  'custom_sales_route': 'Jaimon D - Adoor',
};

final _sky = {
  'name': 'CUST-00043',
  'customer_name': 'Sky Tyres',
  'customer_group': 'Retailer',
  'custom_sales_route': 'Jaimon D - Pathanamthitta',
};

bool _shown(Map<String, dynamic> c, CustomerFilter f) =>
    f.matches(c, customerHaystack(c));

void main() {
  test('no query and no route shows everyone', () {
    final f = CustomerFilter();
    expect(_shown(_renjith, f), isTrue);
    expect(_shown(_sky, f), isTrue);
  });

  test('the search ignores case and matches part of a name', () {
    expect(_shown(_renjith, CustomerFilter(query: 'RENJ')), isTrue);
    expect(_shown(_sky, CustomerFilter(query: 'renj')), isFalse);
  });

  test('a rep can search by ERP id, group or route as well as name', () {
    expect(_shown(_renjith, CustomerFilter(query: '00042')), isTrue);
    expect(_shown(_renjith, CustomerFilter(query: 'dealer')), isTrue);
    expect(_shown(_renjith, CustomerFilter(query: 'adoor')), isTrue);
  });

  test('the route filter narrows to that route exactly', () {
    final f = CustomerFilter(route: 'Jaimon D - Adoor');
    expect(_shown(_renjith, f), isTrue);
    expect(_shown(_sky, f), isFalse);
  });

  test('the route filter and the search both have to pass', () {
    expect(
        _shown(_renjith,
            CustomerFilter(query: 'tyres', route: 'Jaimon D - Adoor')),
        isTrue);
    expect(
        _shown(_sky, CustomerFilter(query: 'tyres', route: 'Jaimon D - Adoor')),
        isFalse);
  });

  test('a customer with no route is hidden by any route filter', () {
    final f = CustomerFilter(route: 'Jaimon D - Adoor');
    expect(_shown({'name': 'CUST-1', 'customer_name': 'No Route'}, f), isFalse);
  });

  test('surrounding spaces in the query do not hide matches', () {
    expect(_shown(_renjith, CustomerFilter(query: '  renjith ')), isTrue);
  });
}
