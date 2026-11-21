// What a rep is actually shown when something fails.
//
// The bar every case here is held to: the text names what happened and implies
// what to do next, and nothing leaks a Dio type, a Python traceback, or an HTML
// tag onto a phone screen in a tyre shop.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/errors.dart';

DioException _dio(DioExceptionType type, {Response? response, Object? error}) =>
    DioException(
      requestOptions: RequestOptions(path: '/api/resource/Sales Order'),
      type: type,
      response: response,
      error: error,
    );

Response _res(int status, dynamic body) => Response(
      requestOptions: RequestOptions(path: '/api/resource/Sales Order'),
      statusCode: status,
      data: body,
    );

void main() {
  group('Telling a network problem from a rejected request', () {
    test('a connection error is offline', () {
      expect(isOffline(_dio(DioExceptionType.connectionError)), isTrue);
    });

    test('a failed host lookup is offline even when Dio calls it unknown', () {
      expect(
          isOffline(_dio(DioExceptionType.unknown,
              error: 'SocketException: Failed host lookup: mannarubber')),
          isTrue);
    });

    // 11 Nov 2026: the demo app's USB link to a PC whose ERPNext was down, and
    // one bar of signal in the field, both broke the connection mid-request.
    // Read as a real error, screens failed instead of showing their saved copy.
    test('a connection that opened and then broke is offline', () {
      for (final msg in [
        'HttpException: Connection closed before full header was received',
        'HttpException: Connection reset by peer',
        'OS Error: Connection refused, errno = 111',
        'Software caused connection abort',
        'Network is unreachable',
      ]) {
        expect(isOffline(_dio(DioExceptionType.unknown, error: msg)), isTrue,
            reason: msg);
      }
    });

    test('an unknown failure that is not the connection stays an error', () {
      expect(
          isOffline(_dio(DioExceptionType.unknown,
              error: 'FormatException: Unexpected character')),
          isFalse);
    });

    test('a rejected request is not offline — retrying it changes nothing', () {
      expect(isOffline(_dio(DioExceptionType.badResponse,
              response: _res(417, {'exception': 'ValidationError: nope'}))),
          isFalse);
      expect(isOffline(Exception('boom')), isFalse);
    });
  });

  group('Network failures', () {
    // The user, 13 Nov 2026: nothing in the app says the network is gone.
    // Every write is kept and sent by itself, so this only reaches a read
    // with nothing on the phone to answer it.
    test('no signal is not put into words about the network', () {
      final s = humanError(_dio(DioExceptionType.connectionError));
      expect(s, kNotYet);
      expect(s.toLowerCase(), isNot(contains('signal')));
      expect(s.toLowerCase(), isNot(contains('connection')));
    });

    test('a timeout reads the same as no signal', () {
      expect(humanError(_dio(DioExceptionType.receiveTimeout)), kNotYet);
      expect(humanError(_dio(DioExceptionType.connectionTimeout)), kNotYet);
    });

    test('a bad certificate suggests the thing that usually causes it', () {
      expect(humanError(_dio(DioExceptionType.badCertificate)),
          contains('mobile data'));
    });
  });

  group('Rejected requests', () {
    test('an expired login says how to fix it', () {
      expect(humanError(_dio(DioExceptionType.badResponse, response: _res(401, {}))),
          contains('Sign in again'));
    });

    test('a missing record does not read as a bug', () {
      expect(
          humanError(
              _dio(DioExceptionType.badResponse, response: _res(404, {}))),
          contains('no longer exists'));
    });

    test('a timestamp clash tells them to reopen it', () {
      final s =
          humanError(_dio(DioExceptionType.badResponse, response: _res(409, {})));
      expect(s, contains('Changed by someone else'));
      expect(s, contains('Reopen'));
    });

    test('a server fault tells them to escalate if it persists', () {
      final s = humanError(
          _dio(DioExceptionType.badResponse, response: _res(500, {})));
      expect(s, contains('Server error'));
      expect(s, contains('tell the office'));
    });

    test('rate limiting asks for patience, not a reinstall', () {
      expect(
          humanError(
              _dio(DioExceptionType.badResponse, response: _res(429, {}))),
          contains('Try again shortly'));
    });
  });

  group("The backend's own message wins", () {
    test('_server_messages is unwrapped from its double encoding', () {
      final body = {
        '_server_messages':
            '["{\\"message\\": \\"Credit limit crossed for Renjith Tyres\\"}"]'
      };
      expect(humanError(_dio(DioExceptionType.badResponse, response: _res(417, body))),
          'Credit limit crossed for Renjith Tyres');
    });

    test('several server messages are all kept', () {
      final body = {
        '_server_messages': '["{\\"message\\": \\"Row 1: rate required\\"}",'
            '"{\\"message\\": \\"Row 2: rate required\\"}"]'
      };
      final s = humanError(
          _dio(DioExceptionType.badResponse, response: _res(417, body)));
      expect(s, contains('Row 1'));
      expect(s, contains('Row 2'));
    });

    test('a specific message beats the generic conflict wording', () {
      final body = {'exception': 'frappe.exceptions.ValidationError: '
          'Delivery date cannot be before today'};
      expect(
          humanError(
              _dio(DioExceptionType.badResponse, response: _res(417, body))),
          'Delivery date cannot be before today');
    });

    test('a 403 with a reason shows the reason', () {
      final body = {'exception': 'PermissionError: Not permitted to submit'};
      expect(
          humanError(
              _dio(DioExceptionType.badResponse, response: _res(403, body))),
          'Not permitted to submit');
    });
  });

  group('Nothing machine-generated reaches the screen', () {
    test('the Python exception path is stripped', () {
      final body = {'exception': 'frappe.exceptions.LinkExistsError: In use'};
      expect(
          humanError(
              _dio(DioExceptionType.badResponse, response: _res(417, body))),
          'In use');
    });

    test('HTML is stripped and entities decoded', () {
      final body = {
        '_server_messages':
            '["{\\"message\\": \\"<b>Item</b><br>not found &amp; not created\\"}"]'
      };
      expect(
          humanError(
              _dio(DioExceptionType.badResponse, response: _res(417, body))),
          'Item not found & not created');
    });

    test('a traceback is suppressed in favour of something useful', () {
      final body = {
        'exception': 'Traceback (most recent call last):\n  File "app.py"'
      };
      final s = humanError(
          _dio(DioExceptionType.badResponse, response: _res(500, body)));
      expect(s, contains('Server error'));
      expect(s, isNot(contains('Traceback')));
    });

    test('the Dio prefix never survives', () {
      final s = humanError(_dio(DioExceptionType.unknown));
      expect(s, isNot(contains('DioException')));
    });

    test('a long backend message is cut rather than filling the screen', () {
      final body = {'exception': 'ValidationError: ${'x' * 500}'};
      final s = humanError(
          _dio(DioExceptionType.badResponse, response: _res(417, body)));
      expect(s.length, lessThanOrEqualTo(300));
      expect(s, endsWith('...'));
    });

    test("Frappe's meaningless placeholders fall back to plain wording", () {
      for (final junk in ['Internal Server Error', 'None']) {
        final s = humanError(_dio(DioExceptionType.badResponse,
            response: _res(500, {'exception': junk})));
        expect(s, contains('Server error'));
      }
    });
  });

  group('Messages already written for a rep are left alone', () {
    // A StockUnavailable case stood here — "Only 2 rolls left of PCTR-100,
    // another rep booked the rest" — and it has gone with the booking protocol
    // that raised it. Nothing in the app refuses an order for want of stock
    // any more; SAP decides that, after the order reaches it.

    test('a plain exception still comes out as a sentence', () {
      expect(humanError(Exception('Lead is missing GST number')),
          'Lead is missing GST number');
    });

    test('null does not produce the word null', () {
      expect(humanError(null), 'Something went wrong.');
      expect(humanError(null).toLowerCase(), isNot(contains('null')));
    });
  });
}
