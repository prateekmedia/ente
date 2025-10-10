import "dart:async";
import "dart:convert";

import "package:logging/logging.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/collection/collection_job.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/services/collections_tree_service.dart";
import "package:shared_preferences/shared_preferences.dart";

/// Service for managing persistent, resumable collection jobs
class CollectionsJobService {
  static final _logger = Logger("CollectionsJobService");

  static const String _jobQueueKey = "collection_jobs_queue";
  static const int _maxConcurrentJobs = 1; // Process one job at a time
  static const int _batchSize = 50; // Items per batch

  final CollectionsService _collectionsService;
  final CollectionsTreeService _treeService;
  late SharedPreferences _prefs;

  final Map<String, CollectionJob> _activeJobs = {};
  final StreamController<CollectionJob> _jobUpdateController =
      StreamController.broadcast();

  bool _isProcessing = false;

  CollectionsJobService._privateConstructor()
      : _collectionsService = CollectionsService.instance,
        _treeService = CollectionsTreeService.instance;

  static final CollectionsJobService instance =
      CollectionsJobService._privateConstructor();

  Future<void> init(SharedPreferences preferences) async {
    _prefs = preferences;
    await _resumePendingJobs();
  }

  /// Stream of job updates
  Stream<CollectionJob> get jobUpdates => _jobUpdateController.stream;

  /// Gets all jobs (active and completed)
  Future<List<CollectionJob>> getAllJobs() async {
    final jobsJson = _prefs.getStringList(_jobQueueKey) ?? [];
    return jobsJson
        .map((json) => CollectionJob.fromJson(jsonDecode(json)))
        .toList();
  }

  /// Gets active jobs (pending or running)
  Future<List<CollectionJob>> getActiveJobs() async {
    final allJobs = await getAllJobs();
    return allJobs.where((job) => !job.isTerminal).toList();
  }

  /// Enqueues a new job
  Future<CollectionJob> enqueueJob(CollectionJob job) async {
    _logger.info("Enqueuing job ${job.id} of type ${job.type}");

    final allJobs = await getAllJobs();
    allJobs.add(job);
    await _saveJobs(allJobs);

    _jobUpdateController.add(job);
    unawaited(_processQueue());

    return job;
  }

  /// Cancels a job
  Future<void> cancelJob(String jobId) async {
    _logger.info("Cancelling job $jobId");

    final allJobs = await getAllJobs();
    final jobIndex = allJobs.indexWhere((j) => j.id == jobId);

    if (jobIndex == -1) return;

    final job = allJobs[jobIndex];
    if (job.status == CollectionJobStatus.running) {
      // Mark for cancellation, actual cancellation happens in processing loop
      _activeJobs[jobId]?.status = CollectionJobStatus.cancelled;
    } else {
      job.status = CollectionJobStatus.cancelled;
      job.completedAt = DateTime.now().millisecondsSinceEpoch;
      allJobs[jobIndex] = job;
      await _saveJobs(allJobs);
      _jobUpdateController.add(job);
    }
  }

  /// Retries a failed or cancelled job
  Future<CollectionJob?> retryJob(String jobId) async {
    final allJobs = await getAllJobs();
    final jobIndex = allJobs.indexWhere((j) => j.id == jobId);

    if (jobIndex == -1) return null;

    final job = allJobs[jobIndex];
    if (!job.canRetry) return null;

    final retriedJob = job.copyWith(
      status: CollectionJobStatus.pending,
      completedItems: 0,
      errorMessage: null,
      startedAt: null,
      completedAt: null,
    );

    allJobs[jobIndex] = retriedJob;
    await _saveJobs(allJobs);

    _jobUpdateController.add(retriedJob);
    unawaited(_processQueue());

    return retriedJob;
  }

  /// Clears completed jobs
  Future<void> clearCompletedJobs() async {
    final allJobs = await getAllJobs();
    final activeJobs =
        allJobs.where((job) => !job.isTerminal || job.canRetry).toList();
    await _saveJobs(activeJobs);
  }

  /// Rollback a completed job using stored rollback data
  Future<CollectionJob?> rollbackJob(String jobId) async {
    final allJobs = await getAllJobs();
    final jobIndex = allJobs.indexWhere((j) => j.id == jobId);

    if (jobIndex == -1) return null;

    final job = allJobs[jobIndex];

    // Can only rollback completed jobs with rollback data
    if (job.status != CollectionJobStatus.completed ||
        job.rollbackData == null) {
      return null;
    }

    try {
      await _performRollback(job);

      // Mark job as rolled back by adding to params
      job.params['_rolledBack'] = true;
      await _updateJob(job);

      return job;
    } catch (e) {
      _logger.severe("Failed to rollback job $jobId", e);
      return null;
    }
  }

  /// Performs rollback based on job type
  Future<void> _performRollback(CollectionJob job) async {
    switch (job.type) {
      case CollectionJobType.move:
        final childID = job.rollbackData!['childID'] as int;
        final previousParentID = job.rollbackData!['previousParentID'] as int?;
        final child = _collectionsService.getCollectionByID(childID);
        if (child != null) {
          await _collectionsService.setParent(child, previousParentID);
        }
        break;
      case CollectionJobType.cascadeHide:
      case CollectionJobType.cascadeArchive:
        // Rollback visibility changes for all affected collections
        final affectedCollections =
            job.rollbackData!['collections'] as List<Map<String, dynamic>>?;
        if (affectedCollections != null) {
          for (final collData in affectedCollections) {
            final collID = collData['id'] as int;
            final previousVisibility = collData['visibility'] as int;
            final collection = _collectionsService.getCollectionByID(collID);
            if (collection != null) {
              await _collectionsService.updateMagicMetadata(
                collection,
                {"visibility": previousVisibility},
              );
            }
          }
        }
        break;
      default:
        // Other job types don't support rollback yet
        _logger.warning("Rollback not supported for job type ${job.type}");
    }
  }

  /// Resumes pending jobs on app restart
  Future<void> _resumePendingJobs() async {
    final activeJobs = await getActiveJobs();
    if (activeJobs.isNotEmpty) {
      _logger.info("Resuming ${activeJobs.length} pending jobs");
      unawaited(_processQueue());
    }
  }

  /// Processes the job queue
  Future<void> _processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      while (true) {
        final activeJobs = await getActiveJobs();
        final pendingJobs = activeJobs
            .where((job) => job.status == CollectionJobStatus.pending)
            .toList();

        if (pendingJobs.isEmpty) break;
        if (_activeJobs.length >= _maxConcurrentJobs) break;

        final job = pendingJobs.first;
        _activeJobs[job.id] = job;

        unawaited(_executeJob(job));

        // Small delay to prevent tight loop
        await Future.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      _isProcessing = false;
    }
  }

  /// Executes a single job
  Future<void> _executeJob(CollectionJob job) async {
    _logger.info("Executing job ${job.id} of type ${job.type}");

    job.status = CollectionJobStatus.running;
    job.startedAt = DateTime.now().millisecondsSinceEpoch;
    await _updateJob(job);

    try {
      final result = await _processJob(job);

      if (result.success) {
        job.status = CollectionJobStatus.completed;
        job.completedItems = result.processedCount;
      } else {
        job.status = CollectionJobStatus.failed;
        job.errorMessage = result.errorMessage;
      }
    } catch (e, s) {
      _logger.severe("Job ${job.id} failed", e, s);
      job.status = CollectionJobStatus.failed;
      job.errorMessage = e.toString();
    }

    job.completedAt = DateTime.now().millisecondsSinceEpoch;
    await _updateJob(job);
    _activeJobs.remove(job.id);

    // Process next job in queue
    unawaited(_processQueue());
  }

  /// Processes a job based on its type
  Future<CollectionJobResult> _processJob(CollectionJob job) async {
    switch (job.type) {
      case CollectionJobType.move:
        return _processMoveJob(job);
      case CollectionJobType.subtreeShare:
        return _processSubtreeShareJob(job);
      case CollectionJobType.subtreeUnshare:
        return _processSubtreeUnshareJob(job);
      case CollectionJobType.cascadeHide:
        return _processCascadeHideJob(job);
      case CollectionJobType.cascadeArchive:
        return _processCascadeArchiveJob(job);
      case CollectionJobType.cascadeDelete:
        return _processCascadeDeleteJob(job);
      case CollectionJobType.subtreeDelete:
        return _processSubtreeDeleteJob(job);
    }
  }

  /// Processes a move job
  Future<CollectionJobResult> _processMoveJob(CollectionJob job) async {
    final childID = job.params['childID'] as int;
    final newParentID = job.params['newParentID'] as int?;

    final child = _collectionsService.getCollectionByID(childID);
    if (child == null) {
      return const CollectionJobResult.failure("Collection not found");
    }

    // Capture previous state for rollback
    final previousParentID = child.pubMagicMetadata.parentID;
    job.rollbackData = {
      'childID': childID,
      'previousParentID': previousParentID,
    };
    await _updateJob(job);

    await _collectionsService.setParent(child, newParentID);
    return const CollectionJobResult.success(1);
  }

  /// Processes subtree share job
  Future<CollectionJobResult> _processSubtreeShareJob(CollectionJob job) async {
    final parentID = job.targetCollectionID;
    final email = job.params['email'] as String;
    final publicKey = job.params['publicKey'] as String;
    final role = job.params['role'] as String;

    final descendants = _treeService.getDescendants(parentID);

    job.totalItems = descendants.length + 1;
    await _updateJob(job);

    int processed = 0;

    // Share parent first
    try {
      await _collectionsService.share(
        parentID,
        email,
        publicKey,
        CollectionParticipantRoleExtn.fromString(role),
      );
      processed++;
      job.completedItems = processed;
      await _updateJob(job);
    } catch (e) {
      return CollectionJobResult.failure("Failed to share parent: $e");
    }

    // Share descendants in batches
    for (int i = 0; i < descendants.length; i += _batchSize) {
      if (job.status == CollectionJobStatus.cancelled) {
        return const CollectionJobResult.failure("Job cancelled");
      }

      final batch = descendants.skip(i).take(_batchSize).toList();

      for (final descendant in batch) {
        try {
          await _collectionsService.share(
            descendant.id,
            email,
            publicKey,
            CollectionParticipantRoleExtn.fromString(role),
          );
          processed++;
          job.completedItems = processed;
          await _updateJob(job);
        } catch (e) {
          _logger.warning(
            "Failed to share descendant ${descendant.id}: $e",
          );
        }
      }
    }

    return CollectionJobResult.success(processed);
  }

  /// Processes subtree unshare job
  Future<CollectionJobResult> _processSubtreeUnshareJob(
    CollectionJob job,
  ) async {
    final parentID = job.targetCollectionID;
    final email = job.params['email'] as String;

    final descendants = _treeService.getDescendants(parentID);
    job.totalItems = descendants.length + 1;
    await _updateJob(job);

    int processed = 0;

    // Unshare from all including parent
    final allCollections = [
      _collectionsService.getCollectionByID(parentID),
      ...descendants,
    ].whereType<Collection>();

    for (final collection in allCollections) {
      if (job.status == CollectionJobStatus.cancelled) {
        return const CollectionJobResult.failure("Job cancelled");
      }

      try {
        await _collectionsService.unshare(collection.id, email);
        processed++;
        job.completedItems = processed;
        await _updateJob(job);
      } catch (e) {
        _logger.warning("Failed to unshare from ${collection.id}: $e");
      }
    }

    return CollectionJobResult.success(processed);
  }

  /// Processes cascade hide job
  Future<CollectionJobResult> _processCascadeHideJob(
    CollectionJob job,
  ) async {
    final parentID = job.targetCollectionID;
    final shouldHide = job.params['hide'] as bool;

    final descendants = _treeService.getDescendants(parentID);
    job.totalItems = descendants.length + 1;

    final allCollections = [
      _collectionsService.getCollectionByID(parentID),
      ...descendants,
    ].whereType<Collection>().toList();

    // Capture previous state for rollback
    job.rollbackData = {
      'collections': allCollections
          .map(
            (c) => {
              'id': c.id,
              'visibility': c.magicMetadata.visibility,
            },
          )
          .toList(),
    };
    await _updateJob(job);

    int processed = 0;

    for (final collection in allCollections) {
      if (job.status == CollectionJobStatus.cancelled) {
        return const CollectionJobResult.failure("Job cancelled");
      }

      try {
        await _collectionsService.updateMagicMetadata(
          collection,
          {"visibility": shouldHide ? 2 : 0},
        );
        processed++;
        job.completedItems = processed;
        await _updateJob(job);
      } catch (e) {
        _logger.warning("Failed to update visibility for ${collection.id}: $e");
      }
    }

    return CollectionJobResult.success(processed);
  }

  /// Processes cascade archive job
  Future<CollectionJobResult> _processCascadeArchiveJob(
    CollectionJob job,
  ) async {
    final parentID = job.targetCollectionID;
    final shouldArchive = job.params['archive'] as bool;

    final descendants = _treeService.getDescendants(parentID);
    job.totalItems = descendants.length + 1;

    final allCollections = [
      _collectionsService.getCollectionByID(parentID),
      ...descendants,
    ].whereType<Collection>().toList();

    // Capture previous state for rollback
    job.rollbackData = {
      'collections': allCollections
          .map(
            (c) => {
              'id': c.id,
              'visibility': c.magicMetadata.visibility,
            },
          )
          .toList(),
    };
    await _updateJob(job);

    int processed = 0;

    for (final collection in allCollections) {
      if (job.status == CollectionJobStatus.cancelled) {
        return const CollectionJobResult.failure("Job cancelled");
      }

      try {
        await _collectionsService.updateMagicMetadata(
          collection,
          {"visibility": shouldArchive ? 1 : 0},
        );
        processed++;
        job.completedItems = processed;
        await _updateJob(job);
      } catch (e) {
        _logger.warning("Failed to update archive for ${collection.id}: $e");
      }
    }

    return CollectionJobResult.success(processed);
  }

  /// Processes cascade delete job (reparent children to root)
  Future<CollectionJobResult> _processCascadeDeleteJob(
    CollectionJob job,
  ) async {
    final collectionID = job.targetCollectionID;

    final collection = _collectionsService.getCollectionByID(collectionID);
    if (collection == null) {
      return const CollectionJobResult.failure("Collection not found");
    }

    // Reparent immediate children to root
    final children = _treeService.getChildren(collectionID);

    for (final child in children) {
      try {
        await _collectionsService.setParent(child, 0);
      } catch (e) {
        _logger.warning("Failed to reparent child ${child.id}: $e");
      }
    }

    // Delete the collection
    await _collectionsService.trashEmptyCollection(collection);

    return const CollectionJobResult.success(1);
  }

  /// Processes subtree delete job (delete all descendants)
  Future<CollectionJobResult> _processSubtreeDeleteJob(
    CollectionJob job,
  ) async {
    final parentID = job.targetCollectionID;

    final descendants = _treeService.getDescendants(parentID);
    job.totalItems = descendants.length + 1;
    await _updateJob(job);

    int processed = 0;

    // Delete deepest first (children before parents)
    final sortedDescendants = descendants.toList()
      ..sort(
        (a, b) => _treeService.getDepth(b.id).compareTo(
              _treeService.getDepth(a.id),
            ),
      );

    for (final descendant in sortedDescendants) {
      if (job.status == CollectionJobStatus.cancelled) {
        return const CollectionJobResult.failure("Job cancelled");
      }

      try {
        await _collectionsService.trashEmptyCollection(descendant);
        processed++;
        job.completedItems = processed;
        await _updateJob(job);
      } catch (e) {
        _logger.warning("Failed to delete descendant ${descendant.id}: $e");
      }
    }

    // Finally delete the parent
    final parent = _collectionsService.getCollectionByID(parentID);
    if (parent != null) {
      await _collectionsService.trashEmptyCollection(parent);
      processed++;
      job.completedItems = processed;
      await _updateJob(job);
    }

    return CollectionJobResult.success(processed);
  }

  /// Updates a job and persists to storage
  Future<void> _updateJob(CollectionJob job) async {
    final allJobs = await getAllJobs();
    final jobIndex = allJobs.indexWhere((j) => j.id == job.id);

    if (jobIndex != -1) {
      allJobs[jobIndex] = job;
      await _saveJobs(allJobs);
      _jobUpdateController.add(job);
    }
  }

  /// Saves jobs to persistent storage
  Future<void> _saveJobs(List<CollectionJob> jobs) async {
    final jobsJson = jobs.map((job) => jsonEncode(job.toJson())).toList();
    await _prefs.setStringList(_jobQueueKey, jobsJson);
  }

  void dispose() {
    _jobUpdateController.close();
  }
}
