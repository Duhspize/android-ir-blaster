import 'package:flutter/material.dart';
import 'package:irblaster_controller/github_store/github_repository_import_service.dart';
import 'package:irblaster_controller/github_store/github_store_service.dart';
import 'package:irblaster_controller/github_store/models.dart';
import 'package:irblaster_controller/state/remotes_state.dart';
import 'package:irblaster_controller/utils/remote.dart';

Future<GitHubRepositoryImportResult?> showGitHubRepositoryImportDialog(
  BuildContext context, {
  required RepoRef repository,
  required GitHubStoreService githubService,
  required String fallbackRemoteName,
  required String fallbackButtonLabel,
}) {
  return showDialog<GitHubRepositoryImportResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _GitHubRepositoryImportDialog(
      repository: repository,
      githubService: githubService,
      fallbackRemoteName: fallbackRemoteName,
      fallbackButtonLabel: fallbackButtonLabel,
    ),
  );
}

class _GitHubRepositoryImportDialog extends StatefulWidget {
  final RepoRef repository;
  final GitHubStoreService githubService;
  final String fallbackRemoteName;
  final String fallbackButtonLabel;

  const _GitHubRepositoryImportDialog({
    required this.repository,
    required this.githubService,
    required this.fallbackRemoteName,
    required this.fallbackButtonLabel,
  });

  @override
  State<_GitHubRepositoryImportDialog> createState() =>
      _GitHubRepositoryImportDialogState();
}

class _GitHubRepositoryImportDialogState
    extends State<_GitHubRepositoryImportDialog> {
  late final GitHubRepositoryImportCancellationToken _token;
  GitHubRepositoryImportProgress? _progress;
  GitHubRepositoryImportResult? _result;
  Object? _fatalError;
  bool _persisting = false;

  bool get _running => _result == null && _fatalError == null;

  @override
  void initState() {
    super.initState();
    _token = GitHubRepositoryImportCancellationToken();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    try {
      final service = GitHubRepositoryImportService(
        github: widget.githubService,
      );
      final result = await service.importRepository(
        widget.repository,
        existingRemotes: remotes,
        fallbackRemoteName: widget.fallbackRemoteName,
        fallbackButtonLabel: widget.fallbackButtonLabel,
        cancellationToken: _token,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
      if (!mounted) return;

      if (result.importedRemotes.isNotEmpty) {
        setState(() => _persisting = true);
        final next = <Remote>[...remotes, ...result.importedRemotes];
        _assignUniqueRemoteIds(next);
        await writeRemotelist(next);
        remotes = next;
        notifyRemotesChanged();
      }

      if (!mounted) return;
      setState(() {
        _persisting = false;
        _result = result;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _persisting = false;
        _fatalError = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = _progress;
    final result = _result;

    return AlertDialog(
      title: Text(
        result == null && _fatalError == null
            ? 'Importing repository'
            : 'Repository import',
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.repository.owner}/${widget.repository.repo}',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            if (widget.repository.path.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                widget.repository.path,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            if (_fatalError != null)
              _ErrorPanel(error: _fatalError!)
            else if (result != null)
              _ResultPanel(result: result)
            else ...[
              LinearProgressIndicator(
                value: _persisting || progress?.discovering == true
                    ? null
                    : progress?.fraction,
              ),
              const SizedBox(height: 12),
              Text(
                _statusText(progress),
                style: theme.textTheme.bodyMedium,
              ),
              if (progress?.currentPath?.trim().isNotEmpty == true) ...[
                const SizedBox(height: 8),
                Text(
                  progress!.currentPath!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  _Metric(label: 'Found', value: progress?.filesDiscovered ?? 0),
                  _Metric(label: 'Processed', value: progress?.filesProcessed ?? 0),
                  _Metric(label: 'Imported', value: progress?.remotesImported ?? 0),
                  _Metric(label: 'Duplicates', value: progress?.duplicateRemotes ?? 0),
                  _Metric(label: 'Failed', value: progress?.failedFiles ?? 0),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_running)
          TextButton(
            onPressed: _persisting ? null : _token.cancel,
            child: const Text('Cancel'),
          )
        else
          FilledButton(
            onPressed: () => Navigator.of(context).pop(result),
            child: const Text('Done'),
          ),
      ],
    );
  }

  String _statusText(GitHubRepositoryImportProgress? progress) {
    if (_persisting) return 'Saving imported remotes…';
    if (progress == null) return 'Preparing repository scan…';
    if (progress.cancelled) return 'Cancelling…';
    if (progress.discovering) {
      return 'Scanning folders (${progress.directoriesScanned})…';
    }
    return 'Processing ${progress.filesProcessed} of '
        '${progress.filesDiscovered} compatible files…';
  }
}

class _ResultPanel extends StatelessWidget {
  final GitHubRepositoryImportResult result;

  const _ResultPanel({required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = result.cancelled ? 'Import cancelled' : 'Import complete';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        _ResultRow('Remotes imported', result.importedRemotes.length),
        _ResultRow('Duplicate remotes skipped', result.duplicateRemotes),
        _ResultRow('Compatible files found', result.filesDiscovered),
        _ResultRow('Files processed', result.filesProcessed),
        _ResultRow('Unsupported files skipped', result.unsupportedFiles),
        _ResultRow('Failed files', result.failures.length),
        if (result.failures.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            result.failures.first.error.toString(),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  final Object error;

  const _ErrorPanel({required this.error});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        error.toString(),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final int value;

  const _Metric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Text('$label: $value');
  }
}

class _ResultRow extends StatelessWidget {
  final String label;
  final int value;

  const _ResultRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            '$value',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

void _assignUniqueRemoteIds(List<Remote> values) {
  final seen = <int>{};
  var nextId = values.fold<int>(
    0,
    (current, remote) => remote.id > current ? remote.id : current,
  );
  for (final remote in values) {
    if (remote.id <= 0 || !seen.add(remote.id)) {
      nextId++;
      remote.id = nextId;
      seen.add(remote.id);
    }
  }
}
