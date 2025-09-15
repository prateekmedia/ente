import 'dart:convert';
import 'dart:typed_data';

import 'package:ente_crypto/ente_crypto.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/derivation/derivation_manifest.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Service for managing derivation manifests for hierarchical collections
/// This enables cryptographic parent-child relationships without changing collection keys
class DerivationManifestService {
  static const String _manifestStorageKey = 'derivation_manifest_v1';
  static const String _sharedManifestsKey = 'shared_derivation_manifests_v1';
  
  final Logger _logger = Logger('DerivationManifestService');
  final Configuration _config;
  final Uuid _uuid = const Uuid();
  
  DerivationManifest? _cachedManifest;
  final Map<String, SharedDerivationManifest> _sharedManifests = {};

  DerivationManifestService(this._config);

  static DerivationManifestService? _instance;
  
  static DerivationManifestService get instance {
    _instance ??= DerivationManifestService(
      Configuration.instance,
    );
    return _instance!;
  }

  /// Generate a unique organizational ID for a collection
  String generateOrganizationalId() => _uuid.v4();

  /// Generate a random salt for derivation
  Uint8List generateSalt() {
    // Generate a 256-bit random salt
    return CryptoUtil.generateKey();
  }

  /// Load the user's derivation manifest from local storage
  Future<DerivationManifest?> loadManifest() async {
    if (_cachedManifest != null) {
      return _cachedManifest;
    }

    final prefs = await SharedPreferences.getInstance();
    final encryptedData = prefs.getString(_manifestStorageKey);
    
    if (encryptedData == null) {
      // Create new manifest if none exists
      _cachedManifest = DerivationManifest(
        manifestId: _uuid.v4(),
        entries: {},
        userId: _config.getUserID()?.toString() ?? '',
      );
      return _cachedManifest;
    }

    try {
      // Decrypt manifest using master key
      final masterKey = _config.getKey();
      if (masterKey == null) {
        return null;
      }

      final decodedData = jsonDecode(encryptedData);
      final encryptedBytes = CryptoUtil.base642bin(decodedData['data']);
      final nonce = CryptoUtil.base642bin(decodedData['nonce']);
      
      final decryptedData = await CryptoUtil.decrypt(
        encryptedBytes,
        masterKey,
        nonce,
      );
      
      _cachedManifest = DerivationManifest.fromBytes(decryptedData);
      return _cachedManifest;
    } catch (e) {
      _logger.warning('Error loading derivation manifest: $e');
      return null;
    }
  }

  /// Save the derivation manifest to local storage
  Future<void> saveManifest(DerivationManifest manifest) async {
    final masterKey = _config.getKey();
    if (masterKey == null) {
      throw Exception('Master key not available');
    }

    // Encrypt manifest with master key
    final manifestBytes = manifest.toBytes();
    final encryptedData = CryptoUtil.encryptSync(manifestBytes, masterKey);
    
    final storageData = jsonEncode({
      'data': CryptoUtil.bin2base64(encryptedData.encryptedData!),
      'nonce': CryptoUtil.bin2base64(encryptedData.nonce!),
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_manifestStorageKey, storageData);
    
    _cachedManifest = manifest;
  }

  /// Create a derivation entry for a sub-album
  Future<DerivationEntry> createDerivationEntry(
    Collection collection,
    Collection? parent,
  ) async {
    final manifest = await loadManifest() ?? DerivationManifest(
      manifestId: _uuid.v4(),
      entries: {},
      userId: _config.getUserID()?.toString() ?? '',
    );

    // Generate organizational ID if not present
    final String orgId = collection.pubMagicMetadata.orgId ?? generateOrganizationalId();
    
    // Create derivation entry
    final entry = DerivationEntry(
      collectionOrgId: orgId,
      parentOrgId: parent?.pubMagicMetadata.orgId,
      derivationSalt: generateSalt(),
      hierarchyLevel: (parent?.pubMagicMetadata.hierarchyLevel ?? -1) + 1,
    );

    manifest.addEntry(entry);
    await saveManifest(manifest);
    
    return entry;
  }

  /// Derive a hierarchy key for organizational purposes (not for file encryption)
  Future<Uint8List> deriveHierarchyKey(
    String collectionOrgId, {
    String? purpose,
  }) async {
    final manifest = await loadManifest();
    if (manifest == null) {
      throw Exception('Manifest not available');
    }

    final entry = manifest.getEntry(collectionOrgId);
    if (entry == null) {
      throw Exception('Collection not found in manifest');
    }

    // If root collection, derive from master key
    if (entry.parentOrgId == null) {
      final masterKey = _config.getKey();
      if (masterKey == null) {
        throw Exception('Master key not available');
      }
      
      return await _deriveSubKey(
        masterKey,
        collectionOrgId,
        entry.derivationSalt,
      );
    }

    // Recursively derive from parent
    final parentKey = await deriveHierarchyKey(entry.parentOrgId!);
    
    return await _deriveSubKey(
      parentKey,
      collectionOrgId,
      entry.derivationSalt,
    );
  }

  /// Derive a sub-key using a simplified approach
  Future<Uint8List> _deriveSubKey(
    Uint8List parentKey,
    String childId,
    Uint8List salt,
  ) async {
    // Combine parent key, child ID and salt to create a unique key
    // This is a simplified derivation for demonstration
    // In production, use proper HKDF or similar
    final combined = Uint8List.fromList([
      ...parentKey,
      ...utf8.encode(childId),
      ...salt,
    ]);
    
    // Use the crypto library's key derivation to generate a new key
    // This creates a deterministic key based on the inputs
    final derivedKey = await CryptoUtil.encryptChaCha(
      combined,
      parentKey,
    );
    
    // Return first 32 bytes as the derived key
    return Uint8List.fromList(derivedKey.encryptedData!.take(32).toList());
  }

  /// Build a derivation manifest for sharing a hierarchy
  Future<SharedDerivationManifest> buildShareManifest(
    Collection rootCollection,
    String targetUserId,
  ) async {
    final manifest = await loadManifest();
    if (manifest == null) {
      throw Exception('Manifest not available');
    }

    // Build hierarchy manifest starting from root
    final hierarchyManifest = await _buildHierarchyManifest(
      rootCollection.pubMagicMetadata.orgId ?? '',
      manifest,
    );

    // Encrypt manifest for target user
    // In production, this would use the target user's public key
    // For now, we'll use master key as a placeholder
    final masterKey = _config.getKey()!;
    final manifestBytes = hierarchyManifest.toBytes();
    final encryptedData = CryptoUtil.encryptSync(manifestBytes, masterKey);

    final sharedManifest = SharedDerivationManifest(
      shareId: _uuid.v4(),
      rootCollectionId: rootCollection.id.toString(),
      targetUserId: targetUserId,
      encryptedManifestData: encryptedData.encryptedData!,
      manifestNonce: encryptedData.nonce!,
    );

    // Store shared manifest
    await _saveSharedManifest(sharedManifest);
    
    return sharedManifest;
  }

  /// Build a manifest containing only the hierarchy from a given root
  Future<DerivationManifest> _buildHierarchyManifest(
    String rootOrgId,
    DerivationManifest fullManifest,
  ) async {
    final hierarchyEntries = <String, DerivationEntry>{};
    
    // Add root entry
    final rootEntry = fullManifest.getEntry(rootOrgId);
    if (rootEntry != null) {
      hierarchyEntries[rootOrgId] = rootEntry;
      
      // Recursively add children
      await _addChildrenToManifest(
        rootOrgId,
        fullManifest,
        hierarchyEntries,
      );
    }

    return DerivationManifest(
      manifestId: _uuid.v4(),
      entries: hierarchyEntries,
      userId: fullManifest.userId,
    );
  }

  Future<void> _addChildrenToManifest(
    String parentOrgId,
    DerivationManifest fullManifest,
    Map<String, DerivationEntry> targetEntries,
  ) async {
    final children = fullManifest.getChildrenOf(parentOrgId);
    for (final child in children) {
      targetEntries[child.collectionOrgId] = child;
      await _addChildrenToManifest(
        child.collectionOrgId,
        fullManifest,
        targetEntries,
      );
    }
  }

  /// Save a shared manifest to local storage
  Future<void> _saveSharedManifest(SharedDerivationManifest manifest) async {
    final prefs = await SharedPreferences.getInstance();
    
    // Load existing shared manifests
    final existingData = prefs.getString(_sharedManifestsKey);
    if (existingData != null) {
      final decoded = jsonDecode(existingData) as Map<String, dynamic>;
      decoded.forEach((key, value) {
        _sharedManifests[key] = SharedDerivationManifest.fromJson(value);
      });
    }

    // Add new manifest
    _sharedManifests[manifest.shareId] = manifest;

    // Save updated manifests
    final storageData = jsonEncode(
      _sharedManifests.map((key, value) => MapEntry(key, value.toJson())),
    );
    await prefs.setString(_sharedManifestsKey, storageData);
  }

  /// Load shared manifests from storage
  Future<Map<String, SharedDerivationManifest>> loadSharedManifests() async {
    if (_sharedManifests.isNotEmpty) {
      return _sharedManifests;
    }

    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_sharedManifestsKey);
    
    if (data != null) {
      final decoded = jsonDecode(data) as Map<String, dynamic>;
      decoded.forEach((key, value) {
        _sharedManifests[key] = SharedDerivationManifest.fromJson(value);
      });
    }

    return _sharedManifests;
  }

  /// Clear cached manifest (useful for logout)
  void clearCache() {
    _cachedManifest = null;
    _sharedManifests.clear();
  }
}