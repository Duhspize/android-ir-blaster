import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:irblaster_controller/utils/remote.dart';
import 'package:irblaster_controller/utils/remotes_io.dart';

void main() {
  test(
    'generate categorized and all-remotes backup artifacts',
    () async {
      final indexPath = Platform.environment['IR_MASTER_INDEX_PATH'] ??
          'build/ir_master_index/ir_master_index.json';
      final outputPath = Platform.environment['IR_BACKUP_OUTPUT_PATH'] ??
          'build/ir_backup_collection';
      final token = Platform.environment['GITHUB_TOKEN']?.trim();

      final indexFile = File(indexPath);
      expect(await indexFile.exists(), isTrue,
          reason: 'Master index not found: $indexPath');

      final decoded = jsonDecode(await indexFile.readAsString());
      expect(decoded, isA<Map<String, dynamic>>());
      final entries = (decoded['entries'] as List)
          .whereType<Map>()
          .map((value) => _IndexEntry.fromJson(
                value.cast<String, dynamic>(),
              ))
          .toList(growable: false);

      // Keep the highest-priority occurrence of each exact Git blob.
      final canonicalByBlob = <String, _IndexEntry>{};
      for (final entry in entries) {
        final existing = canonicalByBlob[entry.blobSha];
        if (existing == null || entry.sourcePriority > existing.sourcePriority) {
          canonicalByBlob[entry.blobSha] = entry;
        }
      }
      final canonical = canonicalByBlob.values.toList(growable: false)
        ..sort((a, b) => a.rawDownloadUrl.compareTo(b.rawDownloadUrl));

      final client = http.Client();
      final headers = <String, String>{
        'Accept': 'application/vnd.github.raw+json',
        'User-Agent': 'IRBlaster-Backup-Builder/1.0',
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

      final groups = <String, List<Remote>>{};
      final allRemotes = <Remote>[];
      final failures = <Map<String, dynamic>>[];
      var nextRemoteId = 1;
      var processed = 0;

      // Bounded workers prevent socket exhaustion and raw-content throttling.
      const workerCount = 12;
      var cursor = 0;
      final lock = _AsyncLock();

      Future<void> worker() async {
        while (true) {
          final entry = await lock.synchronized<_IndexEntry?>(() {
            if (cursor >= canonical.length) return null;
            return canonical[cursor++];
          });
          if (entry == null) return;

          try {
            final response = await client
                .get(Uri.parse(entry.rawDownloadUrl), headers: headers)
                .timeout(const Duration(seconds: 45));
            if (response.statusCode != 200) {
              throw HttpException(
                'HTTP ${response.statusCode}',
                uri: Uri.parse(entry.rawDownloadUrl),
              );
            }

            final parsed = parseImportedRemotesFromText(
              utf8.decode(response.bodyBytes, allowMalformed: true),
              filename: entry.fileName,
              fallbackRemoteName: entry.model,
              fallbackButtonLabel: 'BUTTON',
            );
            if (parsed.isEmpty) {
              throw const FormatException('Parser returned no remotes');
            }

            await lock.synchronized<void>(() {
              final category = _backupCategory(entry);
              final categoryRemotes =
                  groups.putIfAbsent(category, () => <Remote>[]);
              for (final remote in parsed) {
                if (remote.buttons.isEmpty) continue;
                remote.id = nextRemoteId++;
                remote.name = _remoteName(entry, remote.name);
                remote.useNewStyle = true;
                categoryRemotes.add(remote);
                allRemotes.add(remote);
              }
            });
          } catch (error) {
            await lock.synchronized<void>(() {
              failures.add(<String, dynamic>{
                'repository': entry.repository,
                'path': entry.path,
                'format': entry.format,
                'error': error.toString(),
              });
            });
          } finally {
            final count = await lock.synchronized<int>(() => ++processed);
            if (count % 250 == 0 || count == canonical.length) {
              stdout.writeln(
                'Processed $count/${canonical.length}; remotes=${allRemotes.length}; failures=${failures.length}',
              );
            }
          }
        }
      }

      try {
        await Future.wait(List.generate(workerCount, (_) => worker()));
      } finally {
        client.close();
      }

      expect(allRemotes, isNotEmpty);
      final output = Directory(outputPath);
      await output.create(recursive: true);
      final generatedAt = DateTime.now().toUtc().toIso8601String();

      final manifest = <String, dynamic>{
        'schema': 'irblaster.backup-collection',
        'version': 1,
        'generatedAt': generatedAt,
        'indexedUniqueFiles': canonical.length,
        'generatedRemotes': allRemotes.length,
        'failedFiles': failures.length,
        'categories': <Map<String, dynamic>>[],
        'failures': failures,
      };

      final sortedGroups = groups.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      for (final group in sortedGroups) {
        final safe = _safeFileName(group.key);
        final fileName = 'irblaster_backup_${safe}.json';
        await _writeBackup(
          File('${output.path}/$fileName'),
          group.value,
          generatedAt,
        );
        (manifest['categories'] as List).add(<String, dynamic>{
          'category': group.key,
          'file': fileName,
          'remoteCount': group.value.length,
          'buttonCount': group.value.fold<int>(
            0,
            (sum, remote) => sum + remote.buttons.length,
          ),
        });
      }

      await _writeBackup(
        File('${output.path}/irblaster_backup_ALL_REMOTES.json'),
        allRemotes,
        generatedAt,
      );
      await File('${output.path}/manifest.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(manifest),
        flush: true,
      );
      await File('${output.path}/README.txt').writeAsString(
        _readme(sortedGroups, allRemotes.length, failures.length),
        flush: true,
      );

      stdout.writeln(
        'Generated ${sortedGroups.length} categorized backups and one all-remotes backup with ${allRemotes.length} remotes.',
      );
    },
    timeout: const Timeout(Duration(hours: 2)),
  );
}

Future<void> _writeBackup(
  File file,
  List<Remote> remotes,
  String generatedAt,
) async {
  final payload = <String, dynamic>{
    'schema': 'irblaster.backup',
    'version': 1,
    'exportedAt': generatedAt,
    'remotes': remotes.map((remote) => remote.toJson()).toList(growable: false),
    'macros': <dynamic>[],
  };
  await file.writeAsString(jsonEncode(payload), flush: true);
}

String _backupCategory(_IndexEntry entry) {
  final path = entry.path.toLowerCase();
  final category = entry.deviceCategory.toLowerCase();
  String haystack(String value) => ' $value ';
  final text = haystack('$path $category');

  bool hasAny(List<String> terms) => terms.any(text.contains);
  if (hasAny(<String>['/tv', 'television', 'tv_', 'tvs/'])) return 'TVs';
  if (hasAny(<String>['air conditioner', '/acs/', '/ac/', 'hvac'])) {
    return 'Air_Conditioners';
  }
  if (hasAny(<String>['soundbar', 'receiver', 'speaker', 'audio', 'stereo', 'amplifier', 'cd player', 'minidisc'])) {
    return 'Audio';
  }
  if (hasAny(<String>['projector'])) return 'Projectors';
  if (hasAny(<String>['dvd', 'blu ray', 'blu-ray', 'vcr', 'laserdisc'])) {
    return 'Disc_and_Tape_Players';
  }
  if (hasAny(<String>['streaming', 'cable box', 'satellite', 'set top', 'tv box', 'tuner', 'dvb'])) {
    return 'Streaming_Cable_and_Satellite';
  }
  if (hasAny(<String>['fan', 'heater', 'fireplace', 'humidifier', 'air purifier'])) {
    return 'Climate_and_Appliances';
  }
  if (hasAny(<String>['led', 'lighting', 'light', 'lamp'])) return 'Lighting';
  if (hasAny(<String>['camera', 'cctv'])) return 'Cameras_and_CCTV';
  if (hasAny(<String>['monitor', 'display', 'whiteboard', 'picture frame'])) {
    return 'Displays';
  }
  if (hasAny(<String>['vacuum', 'window cleaner', 'robot'])) {
    return 'Cleaning_Robots';
  }
  if (hasAny(<String>['toy', 'console', 'game'])) return 'Toys_and_Gaming';
  if (hasAny(<String>['car', 'head unit'])) return 'Car_Audio';
  if (hasAny(<String>['universal'])) return 'Universal_Remotes';
  return 'Miscellaneous';
}

String _remoteName(_IndexEntry entry, String parsedName) {
  final manufacturer = entry.manufacturer.trim();
  final model = entry.model.trim();
  final base = parsedName.trim().isEmpty ? model : parsedName.trim();
  final parts = <String>[
    if (manufacturer.isNotEmpty && manufacturer.toLowerCase() != 'unknown')
      manufacturer,
    if (base.isNotEmpty) base,
  ];
  final name = parts.join(' - ');
  return name.isEmpty ? entry.fileName : name;
}

String _safeFileName(String value) => value
    .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
    .replaceAll(RegExp(r'_+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

String _readme(
  List<MapEntry<String, List<Remote>>> groups,
  int allCount,
  int failures,
) {
  final buffer = StringBuffer()
    ..writeln('IR Blaster Backup Collection')
    ..writeln('============================')
    ..writeln()
    ..writeln('Import in the app using Settings > Backup/Restore > Restore backup.')
    ..writeln('Start with one categorized file. The ALL_REMOTES file is very large and may exceed device memory limits.')
    ..writeln()
    ..writeln('All-remotes count: $allCount')
    ..writeln('Files that could not be converted: $failures')
    ..writeln()
    ..writeln('Categorized backups:');
  for (final group in groups) {
    buffer.writeln('- ${group.key}: ${group.value.length} remotes');
  }
  return buffer.toString();
}

class _IndexEntry {
  const _IndexEntry({
    required this.repository,
    required this.path,
    required this.fileName,
    required this.format,
    required this.deviceCategory,
    required this.manufacturer,
    required this.model,
    required this.blobSha,
    required this.rawDownloadUrl,
    required this.sourcePriority,
  });

  final String repository;
  final String path;
  final String fileName;
  final String format;
  final String deviceCategory;
  final String manufacturer;
  final String model;
  final String blobSha;
  final String rawDownloadUrl;
  final int sourcePriority;

  factory _IndexEntry.fromJson(Map<String, dynamic> json) => _IndexEntry(
        repository: (json['repository'] ?? '').toString(),
        path: (json['path'] ?? '').toString(),
        fileName: (json['fileName'] ?? '').toString(),
        format: (json['format'] ?? '').toString(),
        deviceCategory: (json['deviceCategory'] ?? '').toString(),
        manufacturer: (json['manufacturer'] ?? '').toString(),
        model: (json['model'] ?? '').toString(),
        blobSha: (json['blobSha'] ?? '').toString(),
        rawDownloadUrl: (json['rawDownloadUrl'] ?? '').toString(),
        sourcePriority: json['sourcePriority'] is int
            ? json['sourcePriority'] as int
            : int.tryParse('${json['sourcePriority']}') ?? 0,
      );
}

class _AsyncLock {
  Future<void> _tail = Future<void>.value();

  Future<T> synchronized<T>(T Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) {
      try {
        completer.complete(action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }
}
