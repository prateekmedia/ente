import 'dart:convert';
import 'dart:typed_data';

import 'package:ente_crypto/ente_crypto.dart';

/// Represents a derivation entry for a collection in the hierarchy
class DerivationEntry {
  final String collectionOrgId;
  final String? parentOrgId;
  final Uint8List derivationSalt;
  final int hierarchyLevel;
  final DateTime createdAt;

  DerivationEntry({
    required this.collectionOrgId,
    this.parentOrgId,
    required this.derivationSalt,
    required this.hierarchyLevel,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'collectionOrgId': collectionOrgId,
        'parentOrgId': parentOrgId,
        'derivationSalt': CryptoUtil.bin2base64(derivationSalt),
        'hierarchyLevel': hierarchyLevel,
        'createdAt': createdAt.toIso8601String(),
      };

  factory DerivationEntry.fromJson(Map<String, dynamic> json) {
    return DerivationEntry(
      collectionOrgId: json['collectionOrgId'],
      parentOrgId: json['parentOrgId'],
      derivationSalt: CryptoUtil.base642bin(json['derivationSalt']),
      hierarchyLevel: json['hierarchyLevel'],
      createdAt: DateTime.parse(json['createdAt']),
    );
  }
}

/// Represents the complete derivation manifest for a user's hierarchy
class DerivationManifest {
  final String manifestId;
  final Map<String, DerivationEntry> entries;
  final String userId;
  final int version;
  final DateTime lastUpdated;

  DerivationManifest({
    required this.manifestId,
    required this.entries,
    required this.userId,
    this.version = 1,
    DateTime? lastUpdated,
  }) : lastUpdated = lastUpdated ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'manifestId': manifestId,
        'entries': entries.map((key, value) => MapEntry(key, value.toJson())),
        'userId': userId,
        'version': version,
        'lastUpdated': lastUpdated.toIso8601String(),
      };

  factory DerivationManifest.fromJson(Map<String, dynamic> json) {
    final entriesMap = <String, DerivationEntry>{};
    final entriesJson = json['entries'] as Map<String, dynamic>;
    entriesJson.forEach((key, value) {
      entriesMap[key] = DerivationEntry.fromJson(value);
    });

    return DerivationManifest(
      manifestId: json['manifestId'],
      entries: entriesMap,
      userId: json['userId'],
      version: json['version'] ?? 1,
      lastUpdated: DateTime.parse(json['lastUpdated']),
    );
  }

  Uint8List toBytes() => utf8.encode(jsonEncode(toJson()));

  factory DerivationManifest.fromBytes(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    return DerivationManifest.fromJson(json);
  }

  void addEntry(DerivationEntry entry) {
    entries[entry.collectionOrgId] = entry;
  }

  DerivationEntry? getEntry(String collectionOrgId) {
    return entries[collectionOrgId];
  }

  List<DerivationEntry> getChildrenOf(String? parentOrgId) {
    return entries.values
        .where((entry) => entry.parentOrgId == parentOrgId)
        .toList();
  }

  List<DerivationEntry> getRootEntries() {
    return getChildrenOf(null);
  }
}

/// Represents a shared derivation manifest for hierarchy sharing
class SharedDerivationManifest {
  final String shareId;
  final String rootCollectionId;
  final String targetUserId;
  final Uint8List encryptedManifestData;
  final Uint8List manifestNonce;
  final DateTime sharedAt;

  SharedDerivationManifest({
    required this.shareId,
    required this.rootCollectionId,
    required this.targetUserId,
    required this.encryptedManifestData,
    required this.manifestNonce,
    DateTime? sharedAt,
  }) : sharedAt = sharedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'shareId': shareId,
        'rootCollectionId': rootCollectionId,
        'targetUserId': targetUserId,
        'encryptedManifestData': CryptoUtil.bin2base64(encryptedManifestData),
        'manifestNonce': CryptoUtil.bin2base64(manifestNonce),
        'sharedAt': sharedAt.toIso8601String(),
      };

  factory SharedDerivationManifest.fromJson(Map<String, dynamic> json) {
    return SharedDerivationManifest(
      shareId: json['shareId'],
      rootCollectionId: json['rootCollectionId'],
      targetUserId: json['targetUserId'],
      encryptedManifestData:
          CryptoUtil.base642bin(json['encryptedManifestData']),
      manifestNonce: CryptoUtil.base642bin(json['manifestNonce']),
      sharedAt: DateTime.parse(json['sharedAt']),
    );
  }
}