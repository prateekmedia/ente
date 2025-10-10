import "dart:async";

import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:photos/models/collection/collection_job.dart";
import "package:photos/services/collections_job_service.dart";

/// Service for handling user notifications for collection jobs
/// Listens to job updates and shows appropriate notifications
class CollectionsJobNotificationService {
  static final _logger = Logger("CollectionsJobNotificationService");

  final CollectionsJobService _jobService;
  StreamSubscription<CollectionJob>? _jobSubscription;
  BuildContext? _context;

  CollectionsJobNotificationService._privateConstructor()
      : _jobService = CollectionsJobService.instance;

  static final CollectionsJobNotificationService instance =
      CollectionsJobNotificationService._privateConstructor();

  /// Initialize notification service with a context
  /// Should be called when app is ready to show notifications
  void init(BuildContext context) {
    _context = context;
    _jobSubscription?.cancel();
    _jobSubscription = _jobService.jobUpdates.listen(_handleJobUpdate);
    _logger.info("Job notification service initialized");
  }

  /// Dispose of resources
  void dispose() {
    _jobSubscription?.cancel();
    _jobSubscription = null;
    _context = null;
  }

  void _handleJobUpdate(CollectionJob job) {
    if (_context == null || !_context!.mounted) return;

    switch (job.status) {
      case CollectionJobStatus.completed:
        _showCompletionNotification(job);
        break;
      case CollectionJobStatus.failed:
        _showFailureNotification(job);
        break;
      case CollectionJobStatus.cancelled:
        _showCancellationNotification(job);
        break;
      case CollectionJobStatus.pending:
      case CollectionJobStatus.running:
        // No notification for pending/running, shown in progress UI
        break;
    }
  }

  void _showCompletionNotification(CollectionJob job) {
    if (_context == null || !_context!.mounted) return;

    final message = _getCompletionMessage(job);
    final isPartialSuccess = job.totalItems > 0 &&
        job.completedItems > 0 &&
        job.completedItems < job.totalItems;

    ScaffoldMessenger.of(_context!).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isPartialSuccess ? Colors.orange : Colors.green,
        duration: const Duration(seconds: 4),
        action: isPartialSuccess
            ? SnackBarAction(
                label: "Details",
                textColor: Colors.white,
                onPressed: () => _showJobDetailsDialog(job),
              )
            : null,
      ),
    );

    _logger.info(
      "Job ${job.id} completed: ${job.completedItems}/${job.totalItems} items",
    );
  }

  void _showFailureNotification(CollectionJob job) {
    if (_context == null || !_context!.mounted) return;

    final message = _getFailureMessage(job);

    ScaffoldMessenger.of(_context!).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: "Retry",
          textColor: Colors.white,
          onPressed: () => _jobService.retryJob(job.id),
        ),
      ),
    );

    _logger.warning("Job ${job.id} failed: ${job.errorMessage}");
  }

  void _showCancellationNotification(CollectionJob job) {
    if (_context == null || !_context!.mounted) return;

    ScaffoldMessenger.of(_context!).showSnackBar(
      SnackBar(
        content: Text("${_getJobTypeDisplayName(job.type)} cancelled"),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _getCompletionMessage(CollectionJob job) {
    final isPartialSuccess = job.totalItems > 0 &&
        job.completedItems > 0 &&
        job.completedItems < job.totalItems;

    if (isPartialSuccess) {
      return "${_getJobTypeDisplayName(job.type)} partially completed: "
          "${job.completedItems}/${job.totalItems} albums";
    }

    switch (job.type) {
      case CollectionJobType.move:
        return "Album moved successfully";
      case CollectionJobType.subtreeShare:
        return "Shared ${job.completedItems} album${job.completedItems == 1 ? '' : 's'}";
      case CollectionJobType.subtreeUnshare:
        return "Unshared from ${job.completedItems} album${job.completedItems == 1 ? '' : 's'}";
      case CollectionJobType.cascadeHide:
        return "Hidden ${job.completedItems} album${job.completedItems == 1 ? '' : 's'}";
      case CollectionJobType.cascadeArchive:
        return "Archived ${job.completedItems} album${job.completedItems == 1 ? '' : 's'}";
      case CollectionJobType.cascadeDelete:
        return "Album deleted, children moved to root";
      case CollectionJobType.subtreeDelete:
        return "Deleted ${job.completedItems} album${job.completedItems == 1 ? '' : 's'}";
    }
  }

  String _getFailureMessage(CollectionJob job) {
    final errorMsg = job.errorMessage ?? "Unknown error";

    if (job.completedItems > 0 && job.totalItems > 0) {
      return "${_getJobTypeDisplayName(job.type)} failed after processing "
          "${job.completedItems}/${job.totalItems} albums: $errorMsg";
    }

    return "${_getJobTypeDisplayName(job.type)} failed: $errorMsg";
  }

  String _getJobTypeDisplayName(CollectionJobType type) {
    switch (type) {
      case CollectionJobType.move:
        return "Move album";
      case CollectionJobType.subtreeShare:
        return "Share albums";
      case CollectionJobType.subtreeUnshare:
        return "Unshare albums";
      case CollectionJobType.cascadeHide:
        return "Hide albums";
      case CollectionJobType.cascadeArchive:
        return "Archive albums";
      case CollectionJobType.cascadeDelete:
        return "Delete album";
      case CollectionJobType.subtreeDelete:
        return "Delete albums";
    }
  }

  void _showJobDetailsDialog(CollectionJob job) {
    if (_context == null || !_context!.mounted) return;

    showDialog(
      context: _context!,
      builder: (context) => AlertDialog(
        title: const Text("Job Details"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Type: ${_getJobTypeDisplayName(job.type)}"),
            const SizedBox(height: 8),
            Text("Status: ${job.status.name}"),
            const SizedBox(height: 8),
            Text(
              "Progress: ${job.completedItems}/${job.totalItems} albums",
            ),
            if (job.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                "Error: ${job.errorMessage}",
                style: const TextStyle(color: Colors.red),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("Close"),
          ),
          if (job.canRetry)
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _jobService.retryJob(job.id);
              },
              child: const Text("Retry"),
            ),
        ],
      ),
    );
  }
}
