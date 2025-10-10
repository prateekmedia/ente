import "package:flutter/material.dart";
import "package:photos/models/collection/collection_job.dart";
import "package:photos/services/collections_job_service.dart";
import "package:photos/theme/ente_theme.dart";

/// Widget that displays progress for active collection jobs
class CollectionJobProgressWidget extends StatefulWidget {
  const CollectionJobProgressWidget({super.key});

  @override
  State<CollectionJobProgressWidget> createState() =>
      _CollectionJobProgressWidgetState();
}

class _CollectionJobProgressWidgetState
    extends State<CollectionJobProgressWidget> {
  final CollectionsJobService _jobService = CollectionsJobService.instance;
  CollectionJob? _activeJob;

  @override
  void initState() {
    super.initState();
    _loadActiveJob();
    _jobService.jobUpdates.listen(_onJobUpdate);
  }

  Future<void> _loadActiveJob() async {
    final activeJobs = await _jobService.getActiveJobs();
    if (activeJobs.isNotEmpty && mounted) {
      setState(() {
        _activeJob = activeJobs.first;
      });
    }
  }

  void _onJobUpdate(CollectionJob job) {
    if (mounted) {
      setState(() {
        if (job.isTerminal) {
          _activeJob = null;
        } else {
          _activeJob = job;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_activeJob == null) {
      return const SizedBox.shrink();
    }

    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.backgroundElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.strokeFaint),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _getJobTitle(_activeJob!),
                  style: textTheme.bodyBold,
                ),
              ),
              if (_activeJob!.status == CollectionJobStatus.running)
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => _cancelJob(),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: _activeJob!.progress,
              backgroundColor: colorScheme.strokeFaint,
              valueColor: AlwaysStoppedAnimation(colorScheme.primary700),
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "${_activeJob!.completedItems} / ${_activeJob!.totalItems}",
            style: textTheme.mini.copyWith(color: colorScheme.textMuted),
          ),
        ],
      ),
    );
  }

  String _getJobTitle(CollectionJob job) {
    switch (job.type) {
      case CollectionJobType.move:
        return "Moving album...";
      case CollectionJobType.subtreeShare:
        return "Sharing albums...";
      case CollectionJobType.subtreeUnshare:
        return "Removing share access...";
      case CollectionJobType.cascadeHide:
        return job.params['hide'] as bool
            ? "Hiding albums..."
            : "Unhiding albums...";
      case CollectionJobType.cascadeArchive:
        return job.params['archive'] as bool
            ? "Archiving albums..."
            : "Unarchiving albums...";
      case CollectionJobType.cascadeDelete:
        return "Deleting album...";
      case CollectionJobType.subtreeDelete:
        return "Deleting albums...";
    }
  }

  Future<void> _cancelJob() async {
    if (_activeJob != null) {
      await _jobService.cancelJob(_activeJob!.id);
    }
  }
}
