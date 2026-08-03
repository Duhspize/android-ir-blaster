import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const Set<String> _supportedExtensions = <String>{
  '.ir',
  '.irplus',
  '.xml',
  '.conf',
  '.cfg',
  '.lirc',
  '.lrc',
  '.hex',
};

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  final token = Platform.environment['GITHUB_TOKEN']?.trim();
  final client = _GitHubClient(token: token == null || token.isEmpty ? null : token);

  try {
    final configFile = File(options.sourcesPath);
    if (!await configFile.exists()) {
      stderr.writeln('Source configuration not found: ${options.sourcesPath}');
      exitCode = 2;
      return;
    }

    final decoded = jsonDecode(await configFile.readAsString());
    if (decoded is! Map<String, dynamic> || decoded['sources'] is! List) {
      stderr.writeln('Invalid source configuration schema.');
      exitCode = 2;
      return;
    }

    final sources = (decoded['sources'] as List)
        .whereType<Map>()
        .map((value) => _Source.fromJson(value.cast<String, dynamic>()))
        .toList(growable: false)
      ..sort((a, b) => b.priority.compareTo(a.priority));

    final entries = <_IndexEntry>[];
    final failures = <Map<String, dynamic>>[];

    for (final source in sources) {
      stdout.writeln('Indexing ${source.owner}/${source.repo}@${source.ref} ...');
      try {
        final tree = await client.fetchRecursiveTree(source);
        if (tree.truncated) {
          throw StateError(
            'GitHub returned a truncated recursive tree. Index generation is fail-closed.',
          );
        }

        var accepted = 0;
        for (final node in tree.nodes) {
          if (node.type != 'blob') continue;
          if (!_isBelowRoot(node.path, source.rootPath)) continue;
          final extension = _extension(node.path);
          if (!_supportedExtensions.contains(extension)) continue;

          final relativePath = _relativeToRoot(node.path, source.rootPath);
          entries.add(
            _IndexEntry.fromTreeNode(
              source: source,
              node: node,
              relativePath: relativePath,
              extension: extension,
            ),
          );
          accepted++;
        }
        stdout.writeln('  accepted $accepted compatible files');
      } catch (error, stack) {
        stderr.writeln('  FAILED: $error');
        if (options.failOnSourceError) {
          rethrow;
        }
        failures.add(<String, dynamic>{
          'sourceId': source.id,
          'repository': '${source.owner}/${source.repo}',
          'error': error.toString(),
          if (options.includeStackTraces) 'stack': stack.toString(),
        });
      }
    }

    entries.sort(_compareEntries);
    final dedupe = _buildDedupe(entries);
    final generatedAt = DateTime.now().toUtc().toIso8601String();

    final outputDir = Directory(options.outputDirectory);
    await outputDir.create(recursive: true);

    final jsonOutput = <String, dynamic>{
      'schema': 'irblaster.master-index',
      'version': 1,
      'generatedAt': generatedAt,
      'sourceConfiguration': options.sourcesPath,
      'statistics': <String, dynamic>{
        'sourceCount': sources.length,
        'failedSourceCount': failures.length,
        'fileCount': entries.length,
        'uniqueBlobCount': dedupe.uniqueBlobCount,
        'duplicateFileCount': dedupe.duplicateFileCount,
        'formatCounts': _countBy(entries, (entry) => entry.format),
        'categoryCounts': _countBy(entries, (entry) => entry.deviceCategory),
      },
      'failures': failures,
      'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
      'duplicateGroups': dedupe.groups,
    };

    final jsonFile = File('${outputDir.path}/ir_master_index.json');
    await jsonFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(jsonOutput),
      flush: true,
    );

    final csvFile = File('${outputDir.path}/ir_master_index.csv');
    await _writeCsv(csvFile, entries);

    final summaryFile = File('${outputDir.path}/ir_master_index_summary.md');
    await summaryFile.writeAsString(
      _renderSummary(
        generatedAt: generatedAt,
        sources: sources,
        entries: entries,
        failures: failures,
        dedupe: dedupe,
      ),
      flush: true,
    );

    stdout.writeln('Generated:');
    stdout.writeln('  ${jsonFile.path}');
    stdout.writeln('  ${csvFile.path}');
    stdout.writeln('  ${summaryFile.path}');
    stdout.writeln(
      'Files: ${entries.length}; unique blobs: ${dedupe.uniqueBlobCount}; duplicates: ${dedupe.duplicateFileCount}',
    );
  } finally {
    client.close();
  }
}

class _Options {
  const _Options({
    required this.sourcesPath,
    required this.outputDirectory,
    required this.failOnSourceError,
    required this.includeStackTraces,
  });

  final String sourcesPath;
  final String outputDirectory;
  final bool failOnSourceError;
  final bool includeStackTraces;

  static _Options parse(List<String> args) {
    var sourcesPath = 'tool/ir_master_index_sources.json';
    var outputDirectory = 'build/ir_master_index';
    var failOnSourceError = true;
    var includeStackTraces = false;

    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--sources':
          sourcesPath = args[++i];
        case '--output':
          outputDirectory = args[++i];
        case '--allow-source-failures':
          failOnSourceError = false;
        case '--include-stack-traces':
          includeStackTraces = true;
        case '--help':
          stdout.writeln('''
Build the file-level infrared master index.

Options:
  --sources PATH              Source configuration JSON.
  --output DIRECTORY          Output directory.
  --allow-source-failures     Continue if one repository cannot be indexed.
  --include-stack-traces      Include stack traces in failure records.
''');
          exit(0);
        default:
          throw FormatException('Unknown argument: ${args[i]}');
      }
    }

    return _Options(
      sourcesPath: sourcesPath,
      outputDirectory: outputDirectory,
      failOnSourceError: failOnSourceError,
      includeStackTraces: includeStackTraces,
    );
  }
}

class _GitHubClient {
  _GitHubClient({required this.token});

  final String? token;
  final http.Client _client = http.Client();

  Future<_TreeResponse> fetchRecursiveTree(_Source source) async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/${source.owner}/${source.repo}/git/trees/${source.ref}',
      const <String, String>{'recursive': '1'},
    );
    final response = await _client.get(uri, headers: <String, String>{
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'IRBlaster-Master-Index/1.0',
      if (token != null) 'Authorization': 'Bearer $token',
    });

    if (response.statusCode != 200) {
      throw HttpException(
        'GitHub ${response.statusCode} for ${source.owner}/${source.repo}@${source.ref}: ${response.body}',
        uri: uri,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['tree'] is! List) {
      throw const FormatException('GitHub tree response has an invalid schema.');
    }

    return _TreeResponse(
      truncated: decoded['truncated'] == true,
      nodes: (decoded['tree'] as List)
          .whereType<Map>()
          .map((value) => _TreeNode.fromJson(value.cast<String, dynamic>()))
          .toList(growable: false),
    );
  }

  void close() => _client.close();
}

class _TreeResponse {
  const _TreeResponse({required this.truncated, required this.nodes});

  final bool truncated;
  final List<_TreeNode> nodes;
}

class _TreeNode {
  const _TreeNode({
    required this.path,
    required this.type,
    required this.sha,
    required this.size,
  });

  final String path;
  final String type;
  final String sha;
  final int? size;

  factory _TreeNode.fromJson(Map<String, dynamic> json) => _TreeNode(
        path: (json['path'] ?? '').toString(),
        type: (json['type'] ?? '').toString(),
        sha: (json['sha'] ?? '').toString(),
        size: json['size'] is int ? json['size'] as int : null,
      );
}

class _Source {
  const _Source({
    required this.id,
    required this.label,
    required this.owner,
    required this.repo,
    required this.ref,
    required this.rootPath,
    required this.formats,
    required this.license,
    required this.priority,
    required this.overlapHint,
  });

  final String id;
  final String label;
  final String owner;
  final String repo;
  final String ref;
  final String rootPath;
  final List<String> formats;
  final String license;
  final int priority;
  final String? overlapHint;

  factory _Source.fromJson(Map<String, dynamic> json) => _Source(
        id: (json['id'] ?? '').toString(),
        label: (json['label'] ?? '').toString(),
        owner: (json['owner'] ?? '').toString(),
        repo: (json['repo'] ?? '').toString(),
        ref: (json['ref'] ?? '').toString(),
        rootPath: (json['rootPath'] ?? '').toString().replaceAll(RegExp(r'^/+|/+$'), ''),
        formats: (json['formats'] as List? ?? const <dynamic>[])
            .map((value) => value.toString())
            .toList(growable: false),
        license: (json['license'] ?? '').toString(),
        priority: json['priority'] is int ? json['priority'] as int : 0,
        overlapHint: json['overlapHint']?.toString(),
      );
}

class _IndexEntry {
  const _IndexEntry({
    required this.sourceId,
    required this.sourceLabel,
    required this.repository,
    required this.ref,
    required this.path,
    required this.fileName,
    required this.extension,
    required this.format,
    required this.deviceCategory,
    required this.manufacturer,
    required this.model,
    required this.protocolHint,
    required this.blobSha,
    required this.sizeBytes,
    required this.rawDownloadUrl,
    required this.githubUrl,
    required this.license,
    required this.sourcePriority,
    required this.overlapHint,
  });

  final String sourceId;
  final String sourceLabel;
  final String repository;
  final String ref;
  final String path;
  final String fileName;
  final String extension;
  final String format;
  final String deviceCategory;
  final String manufacturer;
  final String model;
  final String? protocolHint;
  final String blobSha;
  final int? sizeBytes;
  final String rawDownloadUrl;
  final String githubUrl;
  final String license;
  final int sourcePriority;
  final String? overlapHint;

  factory _IndexEntry.fromTreeNode({
    required _Source source,
    required _TreeNode node,
    required String relativePath,
    required String extension,
  }) {
    final pathParts = relativePath.split('/').where((part) => part.isNotEmpty).toList();
    final fileName = pathParts.isEmpty ? relativePath : pathParts.last;
    final stem = fileName.substring(0, fileName.length - extension.length);
    final metadata = _inferMetadata(pathParts, stem);

    return _IndexEntry(
      sourceId: source.id,
      sourceLabel: source.label,
      repository: '${source.owner}/${source.repo}',
      ref: source.ref,
      path: node.path,
      fileName: fileName,
      extension: extension,
      format: _formatFromExtension(extension),
      deviceCategory: metadata.category,
      manufacturer: metadata.manufacturer,
      model: metadata.model,
      protocolHint: metadata.protocolHint,
      blobSha: node.sha,
      sizeBytes: node.size,
      rawDownloadUrl:
          'https://raw.githubusercontent.com/${source.owner}/${source.repo}/${source.ref}/${Uri.encodeFull(node.path)}',
      githubUrl:
          'https://github.com/${source.owner}/${source.repo}/blob/${source.ref}/${Uri.encodeFull(node.path)}',
      license: source.license,
      sourcePriority: source.priority,
      overlapHint: source.overlapHint,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sourceId': sourceId,
        'sourceLabel': sourceLabel,
        'repository': repository,
        'ref': ref,
        'path': path,
        'fileName': fileName,
        'extension': extension,
        'format': format,
        'deviceCategory': deviceCategory,
        'manufacturer': manufacturer,
        'model': model,
        if (protocolHint != null) 'protocolHint': protocolHint,
        'blobSha': blobSha,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        'rawDownloadUrl': rawDownloadUrl,
        'githubUrl': githubUrl,
        'license': license,
        'sourcePriority': sourcePriority,
        if (overlapHint != null) 'overlapHint': overlapHint,
      };
}

class _InferredMetadata {
  const _InferredMetadata({
    required this.category,
    required this.manufacturer,
    required this.model,
    required this.protocolHint,
  });

  final String category;
  final String manufacturer;
  final String model;
  final String? protocolHint;
}

_InferredMetadata _inferMetadata(List<String> parts, String stem) {
  final directories = parts.length <= 1 ? const <String>[] : parts.sublist(0, parts.length - 1);
  final cleaned = directories
      .where((part) => !<String>{
            'remotes',
            'remote',
            'infrared',
            'assets',
            'codes',
            'devices',
            'converted',
            '_converted_',
          }.contains(part.toLowerCase()))
      .toList(growable: false);

  final category = cleaned.isNotEmpty ? _humanize(cleaned.first) : 'Uncategorized';
  final manufacturer = cleaned.length >= 2 ? _humanize(cleaned[1]) : 'Unknown';
  final model = _humanize(stem);
  final protocolHint = _protocolHint(parts.join('/'));

  return _InferredMetadata(
    category: category,
    manufacturer: manufacturer,
    model: model,
    protocolHint: protocolHint,
  );
}

String? _protocolHint(String value) {
  final lower = value.toLowerCase();
  const protocols = <String>[
    'nec',
    'rc5',
    'rc6',
    'sirc',
    'sony',
    'samsung',
    'kaseikyo',
    'panasonic',
    'jvc',
    'sharp',
    'denon',
    'pioneer',
  ];
  for (final protocol in protocols) {
    if (RegExp('(^|[/_. -])${RegExp.escape(protocol)}([/_. -]|\$)').hasMatch(lower)) {
      return protocol.toUpperCase();
    }
  }
  return null;
}

String _humanize(String value) {
  final normalized = value
      .replaceAll(RegExp(r'[_-]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) return 'Unknown';
  return normalized
      .split(' ')
      .map((word) => word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
}

String _formatFromExtension(String extension) {
  switch (extension) {
    case '.ir':
      return 'flipper-ir';
    case '.irplus':
    case '.xml':
      return 'irplus-xml';
    case '.conf':
    case '.cfg':
    case '.lirc':
    case '.lrc':
      return 'lirc';
    case '.hex':
      return 'pronto-hex';
    default:
      return 'unknown';
  }
}

bool _isBelowRoot(String path, String rootPath) {
  if (rootPath.isEmpty) return true;
  return path == rootPath || path.startsWith('$rootPath/');
}

String _relativeToRoot(String path, String rootPath) {
  if (rootPath.isEmpty) return path;
  if (path == rootPath) return path.split('/').last;
  return path.substring(rootPath.length + 1);
}

String _extension(String path) {
  final fileName = path.split('/').last.toLowerCase();
  final dot = fileName.lastIndexOf('.');
  return dot < 0 ? '' : fileName.substring(dot);
}

int _compareEntries(_IndexEntry a, _IndexEntry b) {
  final category = a.deviceCategory.toLowerCase().compareTo(b.deviceCategory.toLowerCase());
  if (category != 0) return category;
  final manufacturer = a.manufacturer.toLowerCase().compareTo(b.manufacturer.toLowerCase());
  if (manufacturer != 0) return manufacturer;
  final model = a.model.toLowerCase().compareTo(b.model.toLowerCase());
  if (model != 0) return model;
  final priority = b.sourcePriority.compareTo(a.sourcePriority);
  if (priority != 0) return priority;
  return a.path.compareTo(b.path);
}

class _DedupeResult {
  const _DedupeResult({
    required this.uniqueBlobCount,
    required this.duplicateFileCount,
    required this.groups,
  });

  final int uniqueBlobCount;
  final int duplicateFileCount;
  final List<Map<String, dynamic>> groups;
}

_DedupeResult _buildDedupe(List<_IndexEntry> entries) {
  final bySha = <String, List<_IndexEntry>>{};
  for (final entry in entries) {
    bySha.putIfAbsent(entry.blobSha, () => <_IndexEntry>[]).add(entry);
  }

  final groups = <Map<String, dynamic>>[];
  var duplicates = 0;
  for (final group in bySha.values.where((group) => group.length > 1)) {
    group.sort((a, b) => b.sourcePriority.compareTo(a.sourcePriority));
    duplicates += group.length - 1;
    groups.add(<String, dynamic>{
      'blobSha': group.first.blobSha,
      'canonical': group.first.toJson(),
      'duplicates': group.skip(1).map((entry) => entry.toJson()).toList(growable: false),
    });
  }
  groups.sort((a, b) => (a['blobSha'] as String).compareTo(b['blobSha'] as String));

  return _DedupeResult(
    uniqueBlobCount: bySha.length,
    duplicateFileCount: duplicates,
    groups: groups,
  );
}

Map<String, int> _countBy(
  List<_IndexEntry> entries,
  String Function(_IndexEntry entry) selector,
) {
  final counts = <String, int>{};
  for (final entry in entries) {
    final key = selector(entry);
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return Map<String, int>.fromEntries(
    counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)),
  );
}

Future<void> _writeCsv(File file, List<_IndexEntry> entries) async {
  final sink = file.openWrite();
  const headers = <String>[
    'source_id',
    'source_label',
    'repository',
    'ref',
    'path',
    'file_name',
    'extension',
    'format',
    'device_category',
    'manufacturer',
    'model',
    'protocol_hint',
    'blob_sha',
    'size_bytes',
    'raw_download_url',
    'github_url',
    'license',
    'source_priority',
    'overlap_hint',
  ];
  sink.writeln(headers.join(','));
  for (final entry in entries) {
    sink.writeln(<Object?>[
      entry.sourceId,
      entry.sourceLabel,
      entry.repository,
      entry.ref,
      entry.path,
      entry.fileName,
      entry.extension,
      entry.format,
      entry.deviceCategory,
      entry.manufacturer,
      entry.model,
      entry.protocolHint,
      entry.blobSha,
      entry.sizeBytes,
      entry.rawDownloadUrl,
      entry.githubUrl,
      entry.license,
      entry.sourcePriority,
      entry.overlapHint,
    ].map(_csv).join(','));
  }
  await sink.flush();
  await sink.close();
}

String _csv(Object? value) {
  final text = value?.toString() ?? '';
  if (!text.contains(RegExp(r'[,"\r\n]'))) return text;
  return '"${text.replaceAll('"', '""')}"';
}

String _renderSummary({
  required String generatedAt,
  required List<_Source> sources,
  required List<_IndexEntry> entries,
  required List<Map<String, dynamic>> failures,
  required _DedupeResult dedupe,
}) {
  final formatCounts = _countBy(entries, (entry) => entry.format);
  final categoryCounts = _countBy(entries, (entry) => entry.deviceCategory);
  final buffer = StringBuffer()
    ..writeln('# Infrared File-Level Master Index')
    ..writeln()
    ..writeln('- Generated: `$generatedAt`')
    ..writeln('- Sources configured: `${sources.length}`')
    ..writeln('- Source failures: `${failures.length}`')
    ..writeln('- Compatible files: `${entries.length}`')
    ..writeln('- Unique Git blobs: `${dedupe.uniqueBlobCount}`')
    ..writeln('- Exact duplicate files: `${dedupe.duplicateFileCount}`')
    ..writeln()
    ..writeln('## Format counts')
    ..writeln();

  for (final entry in formatCounts.entries) {
    buffer.writeln('- `${entry.key}`: ${entry.value}');
  }

  buffer
    ..writeln()
    ..writeln('## Largest device categories')
    ..writeln();
  for (final entry in categoryCounts.entries.take(30)) {
    buffer.writeln('- ${entry.key}: ${entry.value}');
  }

  buffer
    ..writeln()
    ..writeln('## Evidence limits')
    ..writeln()
    ..writeln('- Category, manufacturer, model, and protocol hints are inferred from repository paths and filenames; they are not treated as verified signal metadata.')
    ..writeln('- `blobSha` is the Git blob identity supplied by GitHub. It is suitable for exact cross-repository deduplication but is not a SHA-256 content digest.')
    ..writeln('- The generator fails closed when GitHub reports a truncated recursive tree, preventing a partial repository from being labeled complete.')
    ..writeln('- License fields describe repository-level guidance only. Per-file provenance may impose additional terms.');

  if (failures.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Source failures')
      ..writeln();
    for (final failure in failures) {
      buffer.writeln('- `${failure['repository']}`: ${failure['error']}');
    }
  }

  return buffer.toString();
}
