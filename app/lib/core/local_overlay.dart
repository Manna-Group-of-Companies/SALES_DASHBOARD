// What the phone has done that the server has not heard about yet, laid over
// what the server last said.
//
// A write kept on the phone (the outbox) is invisible to every list that reads
// the server, live or saved: a manager who approves an order with no signal
// would see it sit on the Pending list as if nothing had happened, and a lead
// added in a shed would not be on the Leads screen. The user asked for the app
// to behave the same with no signal (13 Nov 2026), so each kept write says what
// it will change — a document's fields, a new document, a deletion — and every
// `/api/resource` answer has those changes applied before a screen sees it.
//
// Pure on purpose: no Flutter, no storage, so the rules are tested directly.
//
// ROUNDING
//   - A new document goes into a list unless a filter on a field it HAS rules
//     it out. A filter on a field it lacks is passed: the rep's own new lead
//     must show on their Leads list even though the phone does not know every
//     field the server will fill in. Rounded towards showing it, because a
//     record the rep just made and cannot find is the worse surprise.
//   - A changed document is dropped from a list only when a filter on a field
//     that CHANGED now fails — an approved order leaves the "waiting" list. A
//     filter on an unchanged field already passed on the server.

import 'dart:convert';

/// One change a kept write will make.
class LocalEffect {
  final String doctype;
  final String name;

  /// The fields it sets. For a new document, everything the phone knows.
  final Map<String, dynamic> fields;
  final bool create;
  final bool delete;

  const LocalEffect.update(this.doctype, this.name, this.fields)
      : create = false,
        delete = false;
  const LocalEffect.create(this.doctype, this.name, this.fields)
      : create = true,
        delete = false;
  const LocalEffect.delete(this.doctype, this.name)
      : fields = const {},
        create = false,
        delete = true;

  Map<String, dynamic> toJson() => {
        'dt': doctype,
        'name': name,
        if (fields.isNotEmpty) 'fields': fields,
        if (create) 'create': true,
        if (delete) 'delete': true,
      };

  static LocalEffect? fromJson(dynamic j) {
    if (j is! Map) return null;
    final dt = '${j['dt'] ?? ''}';
    final name = '${j['name'] ?? ''}';
    if (dt.isEmpty || name.isEmpty) return null;
    final f = j['fields'] is Map
        ? Map<String, dynamic>.from(j['fields'] as Map)
        : <String, dynamic>{};
    if (j['delete'] == true) return LocalEffect.delete(dt, name);
    if (j['create'] == true) return LocalEffect.create(dt, name, f);
    return LocalEffect.update(dt, name, f);
  }
}

/// `/api/resource/Sales%20Order` → (`Sales Order`, null);
/// `/api/resource/Lead/CRM-LEAD-1` → (`Lead`, `CRM-LEAD-1`). Null for any
/// other path.
({String doctype, String? name})? resourceOf(String path) {
  final i = path.indexOf('/api/resource/');
  if (i < 0) return null;
  var rest = path.substring(i + '/api/resource/'.length);
  final q = rest.indexOf('?');
  if (q >= 0) rest = rest.substring(0, q);
  final parts = rest.split('/').where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return null;
  String dec(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  return (
    doctype: dec(parts[0]),
    name: parts.length > 1 ? dec(parts.sublist(1).join('/')) : null,
  );
}

/// [body] — a Frappe `/api/resource` answer — with [effects] applied.
/// [query] is the request's query, for its `filters` / `or_filters`. Returns
/// [body] itself when nothing applies.
dynamic applyEffects(String path, Map<String, dynamic> query, dynamic body,
    List<LocalEffect> effects) {
  if (effects.isEmpty) return body;
  final res = resourceOf(path);
  if (res == null) return body;
  final mine = effects.where((e) => e.doctype == res.doctype).toList();
  if (mine.isEmpty) return body;

  if (res.name != null) {
    return _applyToDoc(res.name!, body, mine);
  }
  final data = body is Map ? body['data'] : null;
  if (body != null && data is! List) return body;
  final rows = <Map<String, dynamic>>[
    for (final r in (data as List? ?? const []))
      if (r is Map) Map<String, dynamic>.from(r)
  ];
  final filters = _decode(query['filters']);
  final orFilters = _decode(query['or_filters']);

  final deleted = {
    for (final e in mine)
      if (e.delete) e.name
  };
  final out = <Map<String, dynamic>>[];
  for (final row in rows) {
    final name = '${row['name'] ?? ''}';
    if (deleted.contains(name)) continue;
    final changed = <String, dynamic>{};
    for (final e in mine) {
      if (!e.create && !e.delete && e.name == name) changed.addAll(e.fields);
    }
    if (changed.isEmpty) {
      out.add(row);
      continue;
    }
    final merged = {...row, ...changed};
    if (!passes(merged, filters, onlyFields: changed.keys.toSet())) continue;
    if (!passesAny(merged, orFilters, onlyFields: changed.keys.toSet())) {
      continue;
    }
    out.add(merged);
  }

  final present = {for (final r in out) '${r['name']}'};
  final created = <Map<String, dynamic>>[];
  for (final e in mine) {
    if (!e.create || deleted.contains(e.name) || present.contains(e.name)) {
      continue;
    }
    final row = <String, dynamic>{...e.fields, 'name': e.name};
    for (final u in mine) {
      if (!u.create && !u.delete && u.name == e.name) row.addAll(u.fields);
    }
    if (!passes(row, filters) || !passesAny(row, orFilters)) continue;
    created.add(row);
    present.add(e.name);
  }
  // Newest first, which is how nearly every list here is ordered.
  final result = [...created.reversed, ...out];
  return body is Map
      ? {...Map<String, dynamic>.from(body), 'data': result}
      : {'data': result};
}

dynamic _applyToDoc(String name, dynamic body, List<LocalEffect> mine) {
  Map<String, dynamic>? doc = body is Map && body['data'] is Map
      ? Map<String, dynamic>.from(body['data'] as Map)
      : null;
  for (final e in mine.where((e) => e.name == name)) {
    if (e.delete) return body;
    if (e.create) doc = {...e.fields, ...?doc, 'name': name};
  }
  if (doc == null) return body;
  for (final e in mine.where((e) => e.name == name && !e.create)) {
    doc.addAll(e.fields);
  }
  return {
    ...(body is Map ? Map<String, dynamic>.from(body) : <String, dynamic>{}),
    'data': doc,
  };
}

dynamic _decode(dynamic f) {
  if (f is String) {
    if (f.isEmpty) return null;
    try {
      return jsonDecode(f);
    } catch (_) {
      return null;
    }
  }
  return f;
}

/// Frappe's filters, as a list of `[field, op, value]` (or
/// `[doctype, field, op, value]`) or a map of `field: value` /
/// `field: [op, value]`, normalised to `(field, op, value)`.
List<(String, String, dynamic)> _conditions(dynamic filters) {
  final out = <(String, String, dynamic)>[];
  if (filters is List) {
    for (final c in filters) {
      if (c is! List || c.length < 2) continue;
      if (c.length >= 4) {
        out.add(('${c[1]}', '${c[2]}', c[3]));
      } else if (c.length == 3) {
        out.add(('${c[0]}', '${c[1]}', c[2]));
      } else {
        out.add(('${c[0]}', '=', c[1]));
      }
    }
  } else if (filters is Map) {
    for (final e in filters.entries) {
      final v = e.value;
      if (v is List && v.length == 2 && v[0] is String) {
        out.add(('${e.key}', '${v[0]}', v[1]));
      } else {
        out.add(('${e.key}', '=', v));
      }
    }
  }
  return out;
}

/// True when [row] meets every condition in [filters]. A condition on a field
/// [row] does not have is passed (see the header); with [onlyFields], so is a
/// condition on any field outside it.
bool passes(Map<String, dynamic> row, dynamic filters,
    {Set<String>? onlyFields}) {
  for (final (field, op, value) in _conditions(filters)) {
    if (onlyFields != null && !onlyFields.contains(field)) continue;
    if (!row.containsKey(field)) continue;
    if (!filterMatches(row[field], op, value)) return false;
  }
  return true;
}

/// `or_filters`: true when there are none, or any one of them holds.
bool passesAny(Map<String, dynamic> row, dynamic filters,
    {Set<String>? onlyFields}) {
  final conds = _conditions(filters);
  if (conds.isEmpty) return true;
  var judged = false;
  for (final (field, op, value) in conds) {
    if (onlyFields != null && !onlyFields.contains(field)) continue;
    if (!row.containsKey(field)) continue;
    judged = true;
    if (filterMatches(row[field], op, value)) return true;
  }
  // Nothing it could judge: passed, by the same rounding as [passes].
  return !judged;
}

String _s(dynamic v) => v == null || v == 'null' ? '' : '$v';

int _cmp(dynamic a, dynamic b) {
  final na = a is num ? a : num.tryParse(_s(a));
  final nb = b is num ? b : num.tryParse(_s(b));
  if (na != null && nb != null) return na.compareTo(nb);
  return _s(a).compareTo(_s(b));
}

bool _like(dynamic v, dynamic pattern) {
  final p = RegExp.escape(_s(pattern).toLowerCase())
      .replaceAll('%', '.*')
      .replaceAll('_', '.');
  return RegExp('^$p\$', dotAll: true).hasMatch(_s(v).toLowerCase());
}

List<String> _list(dynamic v) {
  if (v is List) return v.map(_s).toList();
  return _s(v).split(',').map((s) => s.trim()).toList();
}

/// One Frappe condition. An operator this does not know is passed.
bool filterMatches(dynamic v, String op, dynamic value) {
  switch (op.trim().toLowerCase()) {
    case '=':
      return _cmp(v, value) == 0 || _s(v) == _s(value);
    case '!=':
      return !(_cmp(v, value) == 0 || _s(v) == _s(value));
    case '>':
      return _cmp(v, value) > 0;
    case '<':
      return _cmp(v, value) < 0;
    case '>=':
      return _cmp(v, value) >= 0;
    case '<=':
      return _cmp(v, value) <= 0;
    case 'in':
      return _list(value).contains(_s(v));
    case 'not in':
      return !_list(value).contains(_s(v));
    case 'like':
      return _like(v, value);
    case 'not like':
      return !_like(v, value);
    case 'is':
      final set = _s(v).isNotEmpty;
      return _s(value) == 'set' ? set : !set;
    case 'between':
      final l = value is List ? value : const [];
      if (l.length != 2) return true;
      return _cmp(v, l[0]) >= 0 && _cmp(v, l[1]) <= 0;
    default:
      return true;
  }
}
