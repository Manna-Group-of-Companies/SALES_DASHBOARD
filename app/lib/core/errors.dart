// Turning a failure into something a rep can act on.
//
// Every screen used to end its catch block with `'Failed: $e'`, which put text
// like `DioException [connection error]: SocketException: Failed host lookup`
// in front of somebody standing in a tyre shop. That tells them nothing about
// whether to wait, retry, or ring the office — which is the only question they
// actually have.
//
// So every failure resolves to one plain sentence saying what happened and what
// to do about it. Where the backend sent a real message — a credit limit
// breached, a mandatory field missing — that message is preferred over anything
// invented here, because it is the specific thing that went wrong.
//
// Deliberately free of dart:io so the same code compiles for the web
// dashboards; the offline case is recognised through Dio's own error type.

import 'dart:convert';

import 'package:dio/dio.dart';

/// True when the failure is the network rather than the request — the
/// distinction that decides whether retrying the same thing is worth anything.
bool isOffline(Object? e) {
  if (e is! DioException) return false;
  switch (e.type) {
    case DioExceptionType.connectionError:
    case DioExceptionType.connectionTimeout:
      return true;
    case DioExceptionType.unknown:
      return '${e.error}'.contains('SocketException') ||
          '${e.error}'.contains('Failed host lookup');
    default:
      return false;
  }
}

/// True when the request may not have reached the server, or its answer did
/// not reach the phone — [isOffline] plus the two timeouts that happen after
/// the connection was made.
///
/// Wider than [isOffline] on purpose, and only safe where the caller can cope
/// with a write that DID land: a timed-out POST may well have been saved. The
/// punch queue can, because every queued punch first looks for itself on the
/// server before it is sent (see `Api.sendPendingPunch`). Rounded towards
/// queueing: a punch held back and found to be already there costs one read;
/// a punch treated as refused when it merely timed out is lost.
bool isNetworkFailure(Object? e) {
  if (isOffline(e)) return true;
  if (e is! DioException) return false;
  return e.type == DioExceptionType.sendTimeout ||
      e.type == DioExceptionType.receiveTimeout;
}

/// One sentence, fit to show a rep.
String humanError(Object? e) {
  if (e == null) return 'Something went wrong.';

  // Anything that already writes for a rep is left alone: a refused capture
  // and a coarse GPS fix both phrase themselves better than this file could.
  final own = _ownMessage(e);
  if (own != null) return own;

  if (e is! DioException) {
    final s = _clean('$e');
    return s.isEmpty ? 'Something went wrong.' : s;
  }

  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.transformTimeout:
      return 'Server too slow. Check your signal and try again.';
    case DioExceptionType.connectionError:
      return 'No connection. Try again with signal.';
    case DioExceptionType.badCertificate:
      return 'Could not verify the server. Try mobile data.';
    case DioExceptionType.cancel:
      return 'Cancelled.';
    case DioExceptionType.unknown:
      if (isOffline(e)) {
        return 'No connection. Try again with signal.';
      }
      return 'Something went wrong. Try again.';
    case DioExceptionType.badResponse:
      return _fromResponse(e.response);
  }
}

String _fromResponse(Response? r) {
  final status = r?.statusCode ?? 0;
  final backend = _frappeMessage(r?.data);

  switch (status) {
    case 401:
      return 'Login expired. Sign in again.';
    case 403:
      // Frappe uses 403 both for a dead session and a genuine denial, and its
      // own message is the only thing that tells them apart.
      return backend ?? 'You do not have permission to do that.';
    case 404:
      return backend ?? 'Record no longer exists.';
    case 409:
    case 417:
      return backend ??
          'Changed by someone else. Reopen and try again.';
    case 429:
      return 'Too many requests. Try again shortly.';
  }

  if (status >= 500) {
    return 'Server error. Try later, or tell the office.';
  }
  return backend ?? 'Something went wrong. Try again.';
}

/// Exceptions that carry a message already written for a rep.
///
/// Recognised by shape rather than by type, so this file does not have to
/// import every feature that defines one.
///
/// `StockUnavailable` stood here too and has gone with the booking protocol
/// that raised it: nothing in the app refuses an order for want of stock any
/// more, SAP decides that after the order reaches it. See the note in
/// `test/errors_test.dart`.
String? _ownMessage(Object e) {
  final t = e.runtimeType.toString();
  if (t == 'CoarseFixException' ||
      t == 'CaptureRefused' ||
      t == 'PunchRefused') {
    final s = '$e'.trim();
    if (s.isNotEmpty) return s;
  }
  return null;
}

/// Digs the human part out of a Frappe error body.
///
/// Frappe answers in several shapes depending on how the error was raised:
/// `_server_messages` is a JSON string holding a JSON array of JSON objects,
/// `exception` is a Python traceback line, and `message` is sometimes plain
/// text and sometimes a nested map. All of them are tried.
String? _frappeMessage(dynamic body) {
  if (body == null) return null;

  if (body is String) {
    final s = _clean(body);
    return s.isEmpty ? null : s;
  }

  if (body is Map) {
    final server = body['_server_messages'];
    if (server is String && server.isNotEmpty) {
      try {
        final list = jsonDecode(server);
        if (list is List && list.isNotEmpty) {
          final parts = <String>[];
          for (final item in list) {
            final decoded = item is String ? _tryDecode(item) : item;
            final msg = decoded is Map ? decoded['message'] : decoded;
            final s = _clean('${msg ?? ''}');
            if (s.isNotEmpty) parts.add(s);
          }
          if (parts.isNotEmpty) return parts.join('\n');
        }
      } catch (_) {
        // Malformed — fall through to the other fields.
      }
    }

    for (final key in ['_error_message', 'message', 'exception', 'exc_type']) {
      final v = body[key];
      if (v is Map) {
        final s = _clean('${v['message'] ?? ''}');
        if (s.isNotEmpty) return s;
      }
      if (v != null) {
        final s = _clean('$v');
        if (s.isNotEmpty) return s;
      }
    }
  }
  return null;
}

dynamic _tryDecode(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return s;
  }
}

/// Strips the machinery out of a backend message: the Python exception path,
/// the HTML Frappe wraps messages in, and the Dio prefix.
String _clean(String raw) {
  var s = raw.trim();

  // "DioException [bad response]: ..." — never useful to a rep.
  final dio = RegExp(r'^DioException\s*\[[^\]]*\]:\s*');
  s = s.replaceFirst(dio, '');

  // "frappe.exceptions.ValidationError: Credit limit crossed" -> the message.
  final py = RegExp(r'^[\w.]*(?:Error|Exception)\s*:\s*', multiLine: true);
  s = s.replaceFirst(py, '');

  // Frappe sends messages as HTML.
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ');
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  s = s.replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>');
  s = s.replaceAll('&quot;', '"').replaceAll('&#39;', "'");
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

  // A traceback is not a message. Better to say nothing and let the caller
  // fall back to something generic.
  if (s.startsWith('Traceback') || s.contains('  File "')) return '';
  // Frappe's catch-all page title, which means nothing to anyone.
  if (s == 'Internal Server Error' || s == 'None') return '';

  if (s.length > 300) s = '${s.substring(0, 297)}...';
  return s;
}
