import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:smart_wearables_app/connection/ble_protocol.dart';

/// Persistent, de-duplicated store of history records.
///
/// De-dup key is the record timestamp `ts` (ble_protocol.md §6). Records are
/// kept in a map keyed by ts, so re-pulling history never creates duplicates.
/// Backed by a JSON file in the app documents directory so the Storico graphs
/// survive across sessions.
class HistoryStore {
  static const String _fileName = 'history.json';

  final Map<int, HistoryRecord> _byTs = {};

  /// All records, ascending by ts.
  List<HistoryRecord> get records {
    final list = _byTs.values.toList()..sort((a, b) => a.ts.compareTo(b.ts));
    return list;
  }

  /// Records that carry real (synced) timestamps, ascending. Used for graphs.
  List<HistoryRecord> get syncedRecords =>
      records.where((r) => r.synced).toList();

  /// Count of records hidden from graphs because their ts is boot-relative.
  int get unsyncedCount => _byTs.values.where((r) => !r.synced).length;

  bool get isEmpty => _byTs.isEmpty;

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Load persisted records from disk. Safe to call once at startup.
  Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return;
      final list = jsonDecode(raw) as List<dynamic>;
      _byTs.clear();
      for (final e in list) {
        final r = HistoryRecord.fromJson(e as Map<String, dynamic>);
        _byTs[r.ts] = r;
      }
    } catch (_) {
      // Corrupt or missing file: start empty.
    }
  }

  /// Merge a dump into the store (de-dup by ts). Returns number of NEW records.
  Future<int> merge(Iterable<HistoryRecord> incoming) async {
    var added = 0;
    for (final r in incoming) {
      if (!_byTs.containsKey(r.ts)) added++;
      _byTs[r.ts] = r;
    }
    await _save();
    return added;
  }

  /// Wipe the local store and delete the file.
  Future<void> clear() async {
    _byTs.clear();
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _save() async {
    final f = await _file();
    final list = records.map((r) => r.toJson()).toList();
    await f.writeAsString(jsonEncode(list));
  }

  /// Write all records to a CSV file and return its path. Full rewrite each
  /// time, so the export is idempotent (no duplication).
  Future<File> exportCsv() async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/smart_wearables_history.csv');
    final sb = StringBuffer();
    // datetime is LOCAL time to match the Storico charts (which render
    // fromMillisecondsSinceEpoch in local time); the raw epoch `ts` column stays
    // for an unambiguous machine-readable value.
    sb.writeln('ts,datetime_local,temp_c,hr,spo2,steps_delta,synced');
    for (final r in records) {
      final iso = r.synced
          ? DateTime.fromMillisecondsSinceEpoch(r.ts * 1000).toIso8601String()
          : '';
      sb.writeln(
        '${r.ts},$iso,${r.tempC.toStringAsFixed(2)},${r.hr},'
        '${r.spo2.toStringAsFixed(1)},${r.steps},${r.synced}',
      );
    }
    await f.writeAsString(sb.toString());
    return f;
  }
}
