import 'dart:async';

import 'package:irblaster_controller/github_store/github_store_service.dart';
import 'package:irblaster_controller/github_store/models.dart';
import 'package:irblaster_controller/utils/remote.dart';
import 'package:irblaster_controller/utils/remotes_io.dart';

class GitHubRepositoryImportCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }

  void throwIfCancelled() {
    if (_cancelled) throw const GitHubRepositoryImportCancelled();
  }
}

class GitHubRepositoryImportCancelled implements Exception {
  const GitHubRepositoryImportCancelled();

  @override
  String toString() => 'GitHub repository import cancelled';
}

class GitHubRepositoryImportFailure {
  final String path;
  final Object error;

  const GitHubRepositoryImportFailure({
    required this.path,
    required this.error,
  });
}

class GitHubRepositoryImportProgress {
  final int directoriesScanned;
  final int filesDiscovered;
  final int filesProcessed;
  final int remotesImported;
  final int duplicateRemotes;
  final int unsupportedFiles;
  final int failedFiles;
  final String? currentPath;
  final bool discovering;
  final bool cancelled;

  const GitHubRepositoryImportProgress({
    required this.directoriesScanned,
    required this.filesDiscovered,
    required this.filesProcessed,
    required this.remotesImported,
    required this.duplicateRemotes,
    required this.unsupportedFiles,
    required this.failedFiles,
    this.currentPath,
    this.discovering = false,
    this.cancelled = false,
  });

  double? get fraction => filesDiscovered <= 0
      ? null
      : (filesProcessed / filesDiscovered).clamp(0.0, 1.0);
}

class GitHubRepositoryImportResult {
  final List<Remote> importedRemotes;
  final List<GitHubRepositoryImportFailure> failures;
  final int directoriesScanned;
  final int filesDiscovered;
  final int filesProcessed;
  final int duplicateRemotes;
  final int unsupportedFiles;
  final bool cancelled;

  const GitHubRepositoryImportResult({
    required this.importedRemotes,
    required this.failures,
    required this.directoriesScanned,
    required this.filesDiscovered,
    required this.filesProcessed,
    required this.duplicateRemotes,
    required this.unsupportedFiles,
    required this.cancelled,
  });
}

/// Recursively enumerates and imports every compatible file below a GitHub
/// repository path using the application's existing file parsers.
class GitHubRepositoryImportService {
  static const Set<String> supportedExtensions = <String>{
    '.json',
    '.ir',
    '.xml',
    '.irplus',
    '.conf',
    '.cfg',
    '.lirc',
    '.lrc',
  };

  final GitHubStoreService github;
  final int maximumFiles;
  final int maximumDepth;

  const GitHubRepositoryImportService({
    required this.github,
    this.maximumFiles = 25000,
    this.maximumDepth = 32,
  })  : assert(maximumFiles > 0),
        assert(maximumDepth > 0);

  Future<GitHubRepositoryImportResult> importRepository(
    RepoRef ref, {
    required Iterable<Remote> existingRemotes,
    required String fallbackRemoteName,
    required String fallbackButtonLabel,
    GitHubRepositoryImportCancellationToken? cancellationToken,
    void Function(GitHubRepositoryImportProgress progress)? onProgress,
  }) async {
    final token =
        cancellationToken ?? GitHubRepositoryImportCancellationToken();
    final files = <RepoItem>[];
    final failures = <GitHubRepositoryImportFailure>[];
    final imported = <Remote>[];
    final seenRemoteIds = existingRemotes.map(_remoteIdentity).toSet();

    var directoriesScanned = 0;
    var unsupported = 0;
    var processed = 0;
    var duplicateRemotes = 0;
    var cancelled = false;

    try {
      final queue = <_DirectoryWork>[
        _DirectoryWork(path: '', depth: 0),
      ];

      while (queue.isNotEmpty) {
        token.throwIfCancelled();
        final work = queue.removeAt(0);
        if (work.depth > maximumDepth) {
          failures.add(GitHubRepositoryImportFailure(
            path: work.path,
            error: StateError(
              'Maximum repository traversal depth of $maximumDepth exceeded.',
            ),
          ));
          continue;
        }

        final items = await github.listDirectory(
          ref,
          subPath: work.path.isEmpty ? null : work.path,
        );
        directoriesScanned++;

        for (final item in items) {
          token.throwIfCancelled();
          if (item.type == RepoItemType.dir) {
            queue.add(_DirectoryWork(
              path: _relativeToRepoRoot(ref, item.path),
              depth: work.depth + 1,
            ));
            continue;
          }

          if (!_isSupported(item.name)) {
            unsupported++;
            continue;
          }

          files.add(item);
          if (files.length > maximumFiles) {
            throw StateError(
              'Repository contains more than the configured maximum of '
              '$maximumFiles compatible files.',
            );
          }
        }

        onProgress?.call(GitHubRepositoryImportProgress(
          directoriesScanned: directoriesScanned,
          filesDiscovered: files.length,
          filesProcessed: 0,
          remotesImported: 0,
          duplicateRemotes: 0,
          unsupportedFiles: unsupported,
          failedFiles: failures.length,
          currentPath: work.path,
          discovering: true,
        ));
      }

      for (final item in files) {
        token.throwIfCancelled();
        final fullPath = item.path;
        try {
          final payload = await github.fetchFileText(ref, fullPath);
          final parsed = parseImportedRemotesFromText(
            payload.text,
            filename: payload.name,
            fallbackRemoteName: fallbackRemoteName,
            fallbackButtonLabel: fallbackButtonLabel,
          );

          if (parsed.isEmpty) {
            throw const FormatException(
              'No importable remote definitions were found.',
            );
          }

          for (final remote in parsed) {
            final identity = _remoteIdentity(remote);
            if (!seenRemoteIds.add(identity)) {
              duplicateRemotes++;
              continue;
            }
            imported.add(remote);
          }
        } catch (error) {
          failures.add(GitHubRepositoryImportFailure(
            path: fullPath,
            error: error,
          ));
        }

        processed++;
        onProgress?.call(GitHubRepositoryImportProgress(
          directoriesScanned: directoriesScanned,
          filesDiscovered: files.length,
          filesProcessed: processed,
          remotesImported: imported.length,
          duplicateRemotes: duplicateRemotes,
          unsupportedFiles: unsupported,
          failedFiles: failures.length,
          currentPath: fullPath,
        ));
      }
    } on GitHubRepositoryImportCancelled {
      cancelled = true;
      onProgress?.call(GitHubRepositoryImportProgress(
        directoriesScanned: directoriesScanned,
        filesDiscovered: files.length,
        filesProcessed: processed,
        remotesImported: imported.length,
        duplicateRemotes: duplicateRemotes,
        unsupportedFiles: unsupported,
        failedFiles: failures.length,
        cancelled: true,
      ));
    }

    return GitHubRepositoryImportResult(
      importedRemotes: List<Remote>.unmodifiable(imported),
      failures: List<GitHubRepositoryImportFailure>.unmodifiable(failures),
      directoriesScanned: directoriesScanned,
      filesDiscovered: files.length,
      filesProcessed: processed,
      duplicateRemotes: duplicateRemotes,
      unsupportedFiles: unsupported,
      cancelled: cancelled,
    );
  }

  static bool _isSupported(String fileName) {
    final lower = fileName.trim().toLowerCase();
    if (lower.isEmpty) return false;
    return supportedExtensions.any(lower.endsWith);
  }

  static String _relativeToRepoRoot(RepoRef ref, String fullPath) {
    final root = ref.path.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    final normalized = fullPath.trim().replaceAll(RegExp(r'^/+'), '');
    if (root.isEmpty) return normalized;
    if (normalized == root) return '';
    if (normalized.startsWith('$root/')) {
      return normalized.substring(root.length + 1);
    }
    return normalized;
  }

  static String _remoteIdentity(Remote remote) {
    final buffer = StringBuffer()
      ..write(remote.name.trim().toLowerCase())
      ..write('|')
      ..write(remote.buttons.length);

    for (final button in remote.buttons) {
      buffer
        ..write('|')
        ..write(button.image.trim().toLowerCase())
        ..write(':')
        ..write(button.protocol?.trim().toLowerCase() ?? '')
        ..write(':')
        ..write(button.frequency ?? '')
        ..write(':')
        ..write(button.code ?? '')
        ..write(':')
        ..write(button.rawData?.trim() ?? '');
    }
    return buffer.toString();
  }
}

class _DirectoryWork {
  final String path;
  final int depth;

  const _DirectoryWork({
    required this.path,
    required this.depth,
  });
}
