import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:irblaster_controller/services/bulk_import_service.dart';

void main() {
  group('BulkImportService', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('ir_bulk_import_test_');
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('recursively imports supported files and skips unsupported files',
        () async {
      final nested = Directory('${temp.path}/TV/Samsung');
      await nested.create(recursive: true);
      await File('${nested.path}/remote.ir').writeAsString('REMOTE_A');
      await File('${nested.path}/notes.txt').writeAsString('ignore');

      final service = BulkImportService<String>(
        parser: (candidate) => <String>[String.fromCharCodes(candidate.bytes)],
        identityOf: (item) => item,
      );

      final result = await service.importDirectory(temp);

      expect(result.importedItems, <String>['REMOTE_A']);
      expect(result.discoveredFiles, 2);
      expect(result.processedFiles, 2);
      expect(result.unsupportedFiles, 1);
      expect(result.failedCount, 0);
    });

    test('removes byte-identical files before parser execution', () async {
      await File('${temp.path}/a.ir').writeAsString('same');
      await File('${temp.path}/b.ir').writeAsString('same');
      var parseCalls = 0;

      final service = BulkImportService<String>(
        parser: (candidate) {
          parseCalls++;
          return <String>[candidate.fileName];
        },
        identityOf: (item) => item,
      );

      final result = await service.importDirectory(temp);

      expect(parseCalls, 1);
      expect(result.importedCount, 1);
      expect(result.duplicateFiles, 1);
    });

    test('removes parser-level duplicates against existing identities',
        () async {
      await File('${temp.path}/one.ir').writeAsString('first');
      await File('${temp.path}/two.ir').writeAsString('second');

      final service = BulkImportService<String>(
        parser: (_) => <String>['same-remote'],
        identityOf: (item) => item,
      );

      final result = await service.importDirectory(
        temp,
        existingItemIdentities: const <String>['same-remote'],
      );

      expect(result.importedItems, isEmpty);
      expect(result.duplicateItems, 2);
    });

    test('isolates malformed files and continues importing', () async {
      await File('${temp.path}/bad.ir').writeAsString('bad');
      await File('${temp.path}/good.ir').writeAsString('good');

      final service = BulkImportService<String>(
        parser: (candidate) {
          final text = String.fromCharCodes(candidate.bytes);
          if (text == 'bad') throw const FormatException('broken');
          return <String>[text];
        },
        identityOf: (item) => item,
      );

      final result = await service.importDirectory(temp);

      expect(result.importedItems, <String>['good']);
      expect(result.failedCount, 1);
      expect(result.failures.single.path, endsWith('bad.ir'));
    });

    test('commits in bounded batches and flushes the final batch', () async {
      for (var i = 0; i < 5; i++) {
        await File('${temp.path}/$i.ir').writeAsString('$i');
      }
      final committed = <List<String>>[];

      final service = BulkImportService<String>(
        parser: (candidate) => <String>[String.fromCharCodes(candidate.bytes)],
        identityOf: (item) => item,
        batchSize: 2,
        commitBatch: (batch) => committed.add(List<String>.from(batch)),
      );

      final result = await service.importDirectory(temp);

      expect(result.importedCount, 5);
      expect(committed.map((batch) => batch.length), <int>[2, 2, 1]);
    });

    test('cancellation returns partial progress without throwing', () async {
      for (var i = 0; i < 4; i++) {
        await File('${temp.path}/$i.ir').writeAsString('$i');
      }
      final token = BulkImportCancellationToken();

      final service = BulkImportService<String>(
        parser: (candidate) {
          token.cancel();
          return <String>[String.fromCharCodes(candidate.bytes)];
        },
        identityOf: (item) => item,
      );

      final result = await service.importDirectory(
        temp,
        cancellationToken: token,
      );

      expect(result.cancelled, isTrue);
      expect(result.importedCount, 1);
      expect(result.processedFiles, 1);
    });
  });
}
