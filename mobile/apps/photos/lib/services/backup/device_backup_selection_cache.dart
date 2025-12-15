import 'package:photos/db/device_files_db.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/models/device_collection.dart';

class DeviceBackupSelectionCache {
  DeviceBackupSelectionCache._();

  static final DeviceBackupSelectionCache instance =
      DeviceBackupSelectionCache._();

  final Map<String, bool> _selection = {};
  bool _hydrated = false;

  Future<void> hydrateIfNeeded() async {
    if (_hydrated) {
      return;
    }
    final List<DeviceCollection> deviceCollections =
        await FilesDB.instance.getDeviceCollections();
    _selection
      ..clear()
      ..addEntries(
        deviceCollections.map(
          (collection) => MapEntry(collection.id, collection.shouldBackup),
        ),
      );
    _hydrated = true;
  }

  void applyUpdate(Map<String, bool> updates) {
    if (updates.isEmpty) {
      return;
    }
    _selection.addAll(updates);
  }

  bool isSelected(String? queueSource) {
    if (queueSource == null) {
      return true;
    }
    if (!_hydrated) {
      // Prefer not to drop uploads if cache is not yet ready.
      return true;
    }
    return _selection[queueSource] ?? false;
  }
}
