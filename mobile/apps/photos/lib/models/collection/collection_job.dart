/// Types of collection jobs that can be queued
enum CollectionJobType {
  move,
  subtreeShare,
  subtreeUnshare,
  cascadeHide,
  cascadeArchive,
  cascadeDelete,
  subtreeDelete,
}

/// Status of a collection job
enum CollectionJobStatus {
  pending,
  running,
  completed,
  failed,
  cancelled,
}

/// Represents a job for batch collection operations
class CollectionJob {
  final String id;
  final CollectionJobType type;
  final int targetCollectionID;
  final Map<String, dynamic> params;
  CollectionJobStatus status;
  int totalItems;
  int completedItems;
  String? errorMessage;
  final int createdAt;
  int? startedAt;
  int? completedAt;

  /// Rollback data for undoing the operation
  /// Stores previous state needed to revert changes
  Map<String, dynamic>? rollbackData;

  CollectionJob({
    required this.id,
    required this.type,
    required this.targetCollectionID,
    required this.params,
    this.status = CollectionJobStatus.pending,
    this.totalItems = 0,
    this.completedItems = 0,
    this.errorMessage,
    required this.createdAt,
    this.startedAt,
    this.completedAt,
    this.rollbackData,
  });

  /// Progress as a percentage (0.0 to 1.0)
  double get progress {
    if (totalItems == 0) return 0.0;
    return completedItems / totalItems;
  }

  /// Whether the job is in a terminal state
  bool get isTerminal =>
      status == CollectionJobStatus.completed ||
      status == CollectionJobStatus.failed ||
      status == CollectionJobStatus.cancelled;

  /// Whether the job can be retried
  bool get canRetry =>
      status == CollectionJobStatus.failed ||
      status == CollectionJobStatus.cancelled;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'targetCollectionID': targetCollectionID,
      'params': params,
      'status': status.name,
      'totalItems': totalItems,
      'completedItems': completedItems,
      'errorMessage': errorMessage,
      'createdAt': createdAt,
      'startedAt': startedAt,
      'completedAt': completedAt,
      'rollbackData': rollbackData,
    };
  }

  factory CollectionJob.fromJson(Map<String, dynamic> json) {
    return CollectionJob(
      id: json['id'] as String,
      type: CollectionJobType.values.byName(json['type'] as String),
      targetCollectionID: json['targetCollectionID'] as int,
      params: Map<String, dynamic>.from(json['params'] as Map),
      status: CollectionJobStatus.values.byName(json['status'] as String),
      totalItems: json['totalItems'] as int? ?? 0,
      completedItems: json['completedItems'] as int? ?? 0,
      errorMessage: json['errorMessage'] as String?,
      createdAt: json['createdAt'] as int,
      startedAt: json['startedAt'] as int?,
      completedAt: json['completedAt'] as int?,
      rollbackData: json['rollbackData'] != null
          ? Map<String, dynamic>.from(json['rollbackData'] as Map)
          : null,
    );
  }

  CollectionJob copyWith({
    String? id,
    CollectionJobType? type,
    int? targetCollectionID,
    Map<String, dynamic>? params,
    CollectionJobStatus? status,
    int? totalItems,
    int? completedItems,
    String? errorMessage,
    int? createdAt,
    int? startedAt,
    int? completedAt,
    Map<String, dynamic>? rollbackData,
  }) {
    return CollectionJob(
      id: id ?? this.id,
      type: type ?? this.type,
      targetCollectionID: targetCollectionID ?? this.targetCollectionID,
      params: params ?? this.params,
      status: status ?? this.status,
      totalItems: totalItems ?? this.totalItems,
      completedItems: completedItems ?? this.completedItems,
      errorMessage: errorMessage ?? this.errorMessage,
      createdAt: createdAt ?? this.createdAt,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      rollbackData: rollbackData ?? this.rollbackData,
    );
  }
}

/// Result of a job operation
class CollectionJobResult {
  final bool success;
  final String? errorMessage;
  final int processedCount;

  const CollectionJobResult({
    required this.success,
    this.errorMessage,
    this.processedCount = 0,
  });

  const CollectionJobResult.success(this.processedCount)
      : success = true,
        errorMessage = null;

  const CollectionJobResult.failure(this.errorMessage)
      : success = false,
        processedCount = 0;
}
