import 'package:photos/models/collection/collection.dart';

class SetParentRequest {
  final int? newParentID; // null for root level

  SetParentRequest({this.newParentID});

  Map<String, dynamic> toMap() {
    return {
      'newParentID': newParentID,
    };
  }
}

class ShareScopeRequest {
  final List<int> recipients;
  final String scope; // "direct_only" or "include_sub_collections"
  final String encryptedKey;

  ShareScopeRequest({
    required this.recipients,
    required this.scope,
    required this.encryptedKey,
  });

  Map<String, dynamic> toMap() {
    return {
      'recipients': recipients,
      'scope': scope,
      'encryptedKey': encryptedKey,
    };
  }
}

class BackupScopeRequest {
  final String scope; // "direct_only" or "include_sub_collections"
  final List<int>? excludedSubCollections;

  BackupScopeRequest({
    required this.scope,
    this.excludedSubCollections,
  });

  Map<String, dynamic> toMap() {
    return {
      'scope': scope,
      'excludedSubCollections': excludedSubCollections,
    };
  }
}

class ShareScopeResponse {
  final bool success;
  final int sharedCount;
  final int subCollectionsCount;

  ShareScopeResponse({
    required this.success,
    required this.sharedCount,
    required this.subCollectionsCount,
  });

  static ShareScopeResponse fromMap(Map<String, dynamic> map) {
    return ShareScopeResponse(
      success: map['success'] ?? false,
      sharedCount: map['shared_count'] ?? 0,
      subCollectionsCount: map['sub_collections_count'] ?? 0,
    );
  }
}

class BackupScopeResponse {
  final String backupJobId;
  final int filesCount;

  BackupScopeResponse({
    required this.backupJobId,
    required this.filesCount,
  });

  static BackupScopeResponse fromMap(Map<String, dynamic> map) {
    return BackupScopeResponse(
      backupJobId: map['backup_job_id'] ?? '',
      filesCount: map['files_count'] ?? 0,
    );
  }
}

class CollectionSearchResult {
  final int collectionId;
  final String name;
  final String path;
  final int photoCount;

  CollectionSearchResult({
    required this.collectionId,
    required this.name,
    required this.path,
    required this.photoCount,
  });

  static CollectionSearchResult fromMap(Map<String, dynamic> map) {
    return CollectionSearchResult(
      collectionId: map['collection_id'] ?? 0,
      name: map['name'] ?? '',
      path: map['path'] ?? '',
      photoCount: map['photo_count'] ?? 0,
    );
  }
}

class CollectionHierarchy {
  final List<Collection> hierarchy;

  CollectionHierarchy({required this.hierarchy});

  static CollectionHierarchy fromMap(Map<String, dynamic> map) {
    final List<dynamic> hierarchyList = map['hierarchy'] ?? [];
    final hierarchy = hierarchyList
        .map((item) => Collection.fromMap(item as Map<String, dynamic>))
        .where((collection) => collection != null)
        .cast<Collection>()
        .toList();
    
    return CollectionHierarchy(hierarchy: hierarchy);
  }
}