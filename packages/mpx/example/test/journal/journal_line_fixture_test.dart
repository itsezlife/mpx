/// The journal's stored line, pinned: lines a previous run wrote are read
/// back, and a record is written as the same bytes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/journal/model/journal_record.dart';

// Written by the encoder before it became a codec.
const _full =
    '{"t":1795780800000000,"l":"error","s":"mpx","c":"upload",'
    '"o":"failed","ids":{"jobId":"j1","itemId":"i2"},'
    '"f":{"n":3,"ok":false,"why":"timeout","ratio":0.5},'
    '"e":"SocketException: https://host.test","st":"#0 main"}';
const _bare =
    '{"t":1795780800000001,"l":"info","s":"app","c":"app",'
    '"o":"log","m":"hello"}';

void main() {
  final full = JournalRecord(
    time: DateTime.fromMicrosecondsSinceEpoch(1795780800000000),
    level: MpxEventLevel.error,
    source: JournalSource.mpx,
    category: 'upload',
    op: 'failed',
    ids: const {'jobId': 'j1', 'itemId': 'i2'},
    fields: const {'n': 3, 'ok': false, 'why': 'timeout', 'ratio': 0.5},
    error: 'SocketException: https://host.test',
    stackTrace: '#0 main',
  );
  final bare = JournalRecord(
    time: DateTime.fromMicrosecondsSinceEpoch(1795780800000001),
    level: MpxEventLevel.info,
    source: JournalSource.app,
    category: 'app',
    op: 'log',
    message: 'hello',
  );

  test('a record is written as the stored line, byte for byte', () {
    expect(full.encode(), _full);
    expect(bare.encode(), _bare);
  });

  test('a stored line reads back as the record it was', () {
    for (final (line, record) in [(_full, full), (_bare, bare)]) {
      final read = JournalRecord.tryParse(line)!;
      expect(read.time, record.time);
      expect(read.level, record.level);
      expect(read.source, record.source);
      expect(read.category, record.category);
      expect(read.op, record.op);
      expect(read.ids, record.ids);
      expect(read.fields, record.fields);
      expect(read.message, record.message);
      expect(read.error, record.error);
      expect(read.stackTrace, record.stackTrace);
      expect(read.encode(), line);
    }
  });

  test('a torn line or a line of another format reads as none', () {
    expect(JournalRecord.tryParse(_full.substring(0, 40)), isNull);
    expect(JournalRecord.tryParse('{"t":1}'), isNull);
    expect(JournalRecord.tryParse(_bare.replaceFirst('info', 'loud')), isNull);
  });
}
