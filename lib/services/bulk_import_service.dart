import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// File types accepted by the existing remote import pipeline.
const Set<String> kBulkImportExtensions = <String>{
  '.ir',
  '.irplus',
  '.xml',
  '.conf',
  '.cfg',
  '.lirc',
  '.json',
};

typedef BulkImportParser<T> = FutureOr<List<T>> Function(
  BulkImportCandidate candidate,
);

typedef BulkImportCommitter<T> = FutureOr<void> Function(List<T> items);

typedef BulkImportIdentity<T> = String Function(T item);

class BulkImportCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }

  void throwIfCancelled() {
    if (_cancelled) throw const BulkImportCancelled();
  }
}

class BulkImportCancelled implements Exception {
  const BulkImportCancelled();

  @override
  String toString() => 'Bulk import cancelled';
}

class BulkImportCandidate {
  final String displayPath;
  final String extension;
  final Uint8List bytes;

  const BulkImportCandidate({
    required this.displayPath,
    required this.extension,
    required this.bytes,
  });

  String get fileName {
    final normalized = displayPath.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }
}

class BulkImportFailure {
  final String path;
  final Object error;
  final StackTrace? stackTrace;

  const BulkImportFailure({
    required this.path,
    required this.error,
    this.stackTrace,
  });
}

class BulkImportProgress {
  final int discovered;
  final int processed;
  final int imported;
  final int duplicates;
  final int unsupported;
  final int failed;
  final String? currentPath;
  final bool cancelled;

  const BulkImportProgress({
    required this.discovered,
    required this.processed,
    required this.imported,
    required this.duplicates,
    required this.unsupported,
    required this.failed,
    this.currentPath,
    this.cancelled = false,
  });

  double? get fraction => discovered <= 0 ? null : processed / discovered;
}

class BulkImportResult<T> {
  final List<T> importedItems;
  final List<BulkImportFailure> failures;
  final int discoveredFiles;
  final int processedFiles;
  final int duplicateFiles;
  final int duplicateItems;
  final int unsupportedFiles;
  final bool cancelled;

  const BulkImportResult({
    required this.importedItems,
    required this.failures,
    required this.discoveredFiles,
    required this.processedFiles,
    required this.duplicateFiles,
    required this.duplicateItems,
    required this.unsupportedFiles,
    required this.cancelled,
  });

  int get importedCount => importedItems.length;
  int get failedCount => failures.length;
}

/// Recursive, parser-agnostic import engine.
///
/// The engine deliberately does not know about [Remote] or any concrete file
/// syntax. Existing Flipper/LIRC/IRPlus/backup parsers are injected through
/// [parser], which preserves current parsing behavior and keeps this module
/// reusable for local-folder and GitHub imports.
class BulkImportService<T> {
  final BulkImportParser<T> parser;
  final BulkImportIdentity<T> identityOf;
  final BulkImportCommitter<T>? commitBatch;
  final int batchSize;
  final int maxFileBytes;
  final Set<String> supportedExtensions;

  const BulkImportService({
    required this.parser,
    required this.identityOf,
    this.commitBatch,
    this.batchSize = 50,
    this.maxFileBytes = 8 * 1024 * 1024,
    this.supportedExtensions = kBulkImportExtensions,
  })  : assert(batchSize > 0),
        assert(maxFileBytes > 0);

  Future<BulkImportResult<T>> importDirectory(
    Directory root, {
    Iterable<String> existingItemIdentities = const <String>[],
    BulkImportCancellationToken? cancellationToken,
    void Function(BulkImportProgress progress)? onProgress,
    bool followLinks = false,
  }) async {
    final token = cancellationToken ?? BulkImportCancellationToken();
    final failures = <BulkImportFailure>[];
    final importedItems = <T>[];
    final seenFileHashes = <String>{};
    final seenItemIds = existingItemIdentities.toSet();
    final pendingBatch = <T>[];

    var discovered = 0;
    var processed = 0;
    var duplicateFiles = 0;
    var duplicateItems = 0;
    var unsupported = 0;
    var cancelled = false;

    final files = <File>[];
    try {
      token.throwIfCancelled();
      await for (final entity in root.list(
        recursive: true,
        followLinks: followLinks,
      )) {
        token.throwIfCancelled();
        if (entity is! File) continue;
        discovered++;
        files.add(entity);
      }

      onProgress?.call(BulkImportProgress(
        discovered: discovered,
        processed: 0,
        imported: 0,
        duplicates: 0,
        unsupported: 0,
        failed: 0,
      ));

      for (final file in files) {
        token.throwIfCancelled();
        final path = file.path;
        final extension = _extensionOf(path);

        if (!supportedExtensions.contains(extension)) {
          unsupported++;
          processed++;
          onProgress?.call(BulkImportProgress(
            discovered: discovered,
            processed: processed,
            imported: importedItems.length,
            duplicates: duplicateFiles + duplicateItems,
            unsupported: unsupported,
            failed: failures.length,
            currentPath: path,
          ));
          continue;
        }

        try {
          final stat = await file.stat();
          if (stat.size > maxFileBytes) {
            throw FileSystemException(
              'File exceeds maximum import size of $maxFileBytes bytes',
              path,
            );
          }

          final bytes = await file.readAsBytes();
          final fileHash = _fnv1a64(bytes);
          if (!seenFileHashes.add(fileHash)) {
            duplicateFiles++;
            processed++;
            onProgress?.call(BulkImportProgress(
              discovered: discovered,
              processed: processed,
              imported: importedItems.length,
              duplicates: duplicateFiles + duplicateItems,
              unsupported: unsupported,
              failed: failures.length,
              currentPath: path,
            ));
            continue;
          }

          final parsed = await parser(BulkImportCandidate(
            displayPath: path,
            extension: extension,
            bytes: bytes,
          ));

          for (final item in parsed) {
            final identity = identityOf(item);
            if (identity.trim().isEmpty) {
              throw StateError('Parser produced an item with no identity: $path');
            }
            if (!seenItemIds.add(identity)) {
              duplicateItems++;
              continue;
            }
            importedItems.add(item);
            pendingBatch.add(item);
            if (pendingBatch.length >= batchSize) {
              await _commit(pendingBatch);
            }
          }
        } catch (error, stackTrace) {
          failures.add(BulkImportFailure(
            path: path,
            error: error,
            stackTrace: stackTrace,
          ));
        }

        processed++;
        onProgress?.call(BulkImportProgress(
          discovered: discovered,
          processed: processed,
          imported: importedItems.length,
          duplicates: duplicateFiles + duplicateItems,
          unsupported: unsupported,
          failed: failures.length,
          currentPath: path,
        ));
      }

      await _commit(pendingBatch);
    } on BulkImportCancelled {
      cancelled = true;
      await _commit(pendingBatch);
      onProgress?.call(BulkImportProgress(
        discovered: discovered,
        processed: processed,
        imported: importedItems.length,
        duplicates: duplicateFiles + duplicateItems,
        unsupported: unsupported,
        failed: failures.length,
        cancelled: true,
      ));
    }

    return BulkImportResult<T>(
      importedItems: List<T>.unmodifiable(importedItems),
      failures: List<BulkImportFailure>.unmodifiable(failures),
      discoveredFiles: discovered,
      processedFiles: processed,
      duplicateFiles: duplicateFiles,
      duplicateItems: duplicateItems,
      unsupportedFiles: unsupported,
      cancelled: cancelled,
    );
  }

  Future<void> _commit(List<T> pendingBatch) async {
    if (pendingBatch.isEmpty) return;
    final batch = List<T>.unmodifiable(pendingBatch);
    pendingBatch.clear();
    if (commitBatch != null) await commitBatch!(batch);
  }

  static String _extensionOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    final dot = normalized.lastIndexOf('.');
    if (dot < 0 || dot < slash) return '';
    return normalized.substring(dot).toLowerCase();
  }

  static String _fnv1a64(Uint8List bytes) {
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    const mask = 0xFFFFFFFFFFFFFFFF;
    for (final byte in bytes) {
      hash ^= byte;
      hash = (hash * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
