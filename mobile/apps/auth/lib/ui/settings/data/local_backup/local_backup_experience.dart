import 'dart:io';

import 'package:ente_auth/l10n/l10n.dart';
import 'package:ente_auth/services/icloud_backup_service.dart';
import 'package:ente_auth/services/local_backup_service.dart';
import 'package:ente_auth/theme/ente_theme.dart';
import 'package:ente_auth/ui/components/buttons/button_widget.dart';
import 'package:ente_auth/ui/components/dialog_widget.dart';
import 'package:ente_auth/ui/components/models/button_type.dart';
import 'package:ente_lock_screen/local_authentication_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saf_util/saf_util.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef LocalBackupVariantBuilder = Widget Function(
  BuildContext context,
  LocalBackupExperienceController controller,
);

class LocalBackupExperience extends StatefulWidget {
  const LocalBackupExperience({super.key, required this.builder});

  final LocalBackupVariantBuilder builder;

  @override
  State<LocalBackupExperience> createState() => _LocalBackupExperienceState();
}

class LocalBackupExperienceController {
  const LocalBackupExperienceController._(this._state);

  final _LocalBackupExperienceState _state;

  bool get hasLoaded => _state._hasLoaded;
  bool get isBusy => _state._isBusy;
  bool get isManualBackupRunning => _state._isManualBackupRunning;
  bool get shouldShowBusyOverlay => _state._shouldShowBusyOverlay;
  bool get isBackupEnabled => _state._isBackupEnabled;
  String? get backupPath => _state._backupPath;
  String? get backupTreeUri => _state._backupTreeUri;
  bool get useICloud => _state._useICloud;

  Future<void> toggleBackup(bool shouldEnable) =>
      _state._handleToggle(shouldEnable);

  Future<bool> changeLocation({String? successMessage}) =>
      _state._pickAndSaveBackupLocation(successMessage: successMessage);

  Future<bool> openLocationSetup() => _state._handleLocationSetup();

  Future<bool> resetBackupLocation() => _state._resetBackupLocation();

  Future<void> runManualBackup({bool showSnackBar = true}) =>
      _state._runManualBackup(showSnackBar: showSnackBar);

  Future<bool> updatePassword(BuildContext context) =>
      _state._updatePassword(context);

  Future<bool> hasPasswordConfigured() => _state._hasStoredPassword();

  Future<bool> clearBackupPassword() => _state._clearBackupPassword();

  String simplifyPath(String fullPath) => _state._simplifyPath(fullPath);

  void showSnackBar(String message) => _state._showSnackBar(message);

  Future<void> refreshState() => _state._loadSettings();
}

class _LocalBackupExperienceState extends State<LocalBackupExperience> {
  static const _passwordKey = 'autoBackupPassword';
  static const _locationConfiguredKey = 'hasConfiguredBackupLocation';
  static const _treeUriKey = 'autoBackupTreeUri';
  static const _useICloudKey = 'useICloudBackup';

  bool _isBackupEnabled = false;
  String? _backupPath;
  String? _backupTreeUri;
  bool _useICloud = false;
  bool _isBusy = false;
  bool _isManualBackupRunning = false;
  bool _shouldShowBusyOverlay = true;
  bool _hasLoaded = false;

  late final LocalBackupExperienceController _controller;

  @override
  void initState() {
    super.initState();
    _controller = LocalBackupExperienceController._(this);
    _loadSettings();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _controller);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final storedPath = prefs.getString('autoBackupPath');
    final storedTreeUri = prefs.getString(_treeUriKey);
    final storedUseICloud = prefs.getBool(_useICloudKey) ?? false;
    if (!mounted) return;
    setState(() {
      _isBackupEnabled = prefs.getBool('isAutoBackupEnabled') ?? false;
      _backupPath = storedPath;
      _backupTreeUri = storedTreeUri;
      _useICloud = storedUseICloud;
      _hasLoaded = true;
    });
  }

  Future<void> _handleToggle(bool shouldEnable) async {
    await _withBusyGuard(
      () async {
        if (shouldEnable) {
          final success = await _startEnableFlow();
          if (!success) {
            return;
          }
        } else {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('isAutoBackupEnabled', false);
          if (!mounted) return;
          setState(() {
            _isBackupEnabled = false;
          });
        }
      },
      showOverlay: false,
    );
  }

  Future<bool> _startEnableFlow() async {
    final hasPassword = await _ensurePasswordConfigured(disableOnCancel: true);
    if (!hasPassword) {
      return false;
    }

    final hasLocation = await _ensureBackupLocationSelected();
    if (!hasLocation) {
      return false;
    }
    if (Platform.isAndroid &&
        (_backupTreeUri == null || _backupTreeUri!.isEmpty) &&
        (_backupPath == null || _backupPath!.isEmpty)) {
      _showSnackBar(context.l10n.noDefaultBackupFolder);
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isAutoBackupEnabled', true);
    if (!mounted) return false;
    setState(() {
      _isBackupEnabled = true;
    });
    await LocalBackupService.instance.triggerAutomaticBackup(isManual: false);
    return true;
  }

  Future<void> _runManualBackup({bool showSnackBar = true}) async {
    if (_isManualBackupRunning) return;

    setState(() {
      _isManualBackupRunning = true;
    });

    try {
      final hasPassword =
          await _ensurePasswordConfigured(disableOnCancel: false);
      if (!hasPassword) return;

      final hasLocation = await _ensureBackupLocationSelected();
      if (!hasLocation) return;

      try {
        final success = await LocalBackupService.instance
            .triggerAutomaticBackup(isManual: true);
        if (!success && showSnackBar) {
          _showSnackBar(context.l10n.somethingWentWrongPleaseTryAgain);
        }
      } catch (_) {
        if (showSnackBar) {
          _showSnackBar(context.l10n.somethingWentWrongPleaseTryAgain);
        }
        return;
      }
      if (showSnackBar) {
        _showSnackBar(context.l10n.backupCreated);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isManualBackupRunning = false;
        });
      }
    }
  }

  Future<bool> _ensurePasswordConfigured({
    required bool disableOnCancel,
  }) async {
    if (await _hasStoredPassword()) {
      return true;
    }
    return _promptPassword(
      forcePrompt: true,
      disableOnCancel: disableOnCancel,
      isUpdateFlow: false,
    );
  }

  Future<bool> _ensureBackupLocationSelected() async {
    if (Platform.isAndroid) {
      if ((_backupTreeUri == null || _backupTreeUri!.isEmpty) &&
          (_backupPath == null || _backupPath!.isEmpty)) {
        return _pickAndSaveBackupLocation(
          requireSelection: true,
          shouldTriggerBackup: false,
        );
      }
      return true;
    }

    // On iOS, check if iCloud is already enabled
    if (Platform.isIOS && _useICloud) {
      return true;
    }

    var resolvedPath = _backupPath;
    if (resolvedPath == null || resolvedPath.isEmpty) {
      // On iOS, show the iCloud/local folder selection dialog
      if (Platform.isIOS) {
        final success = await _handleIosLocationSetup();
        if (!success) {
          return false;
        }
        // If iCloud was enabled, we're done
        if (_useICloud) {
          return true;
        }
        resolvedPath = _backupPath;
      } else {
        final saved = await _pickAndSaveBackupLocation(
          requireSelection: true,
          shouldTriggerBackup: false,
        );
        if (!saved) {
          return false;
        }
        resolvedPath = _backupPath;
      }
    }
    if (resolvedPath != null && resolvedPath.isNotEmpty) {
      await Directory(resolvedPath).create(recursive: true);
    }
    return true;
  }

  Future<bool> _authenticateForBackupAction(
    String reason, {
    bool forceAuthPrompt = false,
  }) async {
    if (forceAuthPrompt) {
      // Reset cached auth window to force a fresh prompt for sensitive flows.
      LocalAuthenticationService.instance.lastAuthTime = 0;
    }
    return LocalAuthenticationService.instance.requestLocalAuthentication(
      context,
      reason,
    );
  }

  Future<void> _withBusyGuard(
    Future<void> Function() action, {
    bool showOverlay = true,
  }) async {
    if (_isBusy) {
      return;
    }
    setState(() {
      _isBusy = true;
      _shouldShowBusyOverlay = showOverlay;
    });
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _shouldShowBusyOverlay = true;
        });
      }
    }
  }

  Future<bool> _updatePassword(BuildContext context) async => _promptPassword(
        forcePrompt: true,
        disableOnCancel: false,
        isUpdateFlow: true,
      );

  Future<bool> _promptPassword({
    required bool forcePrompt,
    bool disableOnCancel = false,
    bool isUpdateFlow = false,
  }) async {
    final hasAuthenticated = await _authenticateForBackupAction(
      isUpdateFlow
          ? context.l10n.authToUpdateBackupPassword
          : context.l10n.authToSetBackupPassword,
      forceAuthPrompt: true,
    );
    if (!hasAuthenticated) {
      if (disableOnCancel && mounted) {
        setState(() {
          _isBackupEnabled = false;
        });
      }
      return false;
    }

    if (!forcePrompt) {
      final stored = await _readStoredPassword();
      if (stored != null && stored.isNotEmpty) {
        return true;
      }
    }

    final String? password = await _showCustomPasswordDialog(
      isUpdateFlow: isUpdateFlow,
    );
    if (password == null) {
      if (disableOnCancel && mounted) {
        setState(() {
          _isBackupEnabled = false;
        });
      }
      return false;
    }

    const storage = FlutterSecureStorage();
    await storage.write(key: _passwordKey, value: password);
    return true;
  }

  Future<bool> _hasStoredPassword() async {
    final stored = await _readStoredPassword();
    return stored != null && stored.isNotEmpty;
  }

  Future<bool> _clearBackupPassword() async {
    if (_isBackupEnabled) {
      return false;
    }
    const storage = FlutterSecureStorage();
    await storage.delete(key: _passwordKey);
    _showSnackBar(context.l10n.backupPasswordCleared);
    return true;
  }

  Future<String?> _readStoredPassword() async {
    const storage = FlutterSecureStorage();
    try {
      return storage.read(key: _passwordKey);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _resetBackupLocation() async {
    if (_isBackupEnabled) {
      return false;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('autoBackupPath');
    await prefs.remove(_treeUriKey);
    await prefs.remove(_locationConfiguredKey);
    await prefs.remove(_useICloudKey);
    if (!mounted) return false;
    setState(() {
      _backupPath = null;
      _backupTreeUri = null;
      _useICloud = false;
    });
    return true;
  }

  Future<String?> _showCustomPasswordDialog({
    required bool isUpdateFlow,
  }) async {
    final l10n = context.l10n;
    final textController = TextEditingController();
    bool isPasswordHidden = true;
    String? errorText;

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text(
                isUpdateFlow
                    ? l10n.updateBackupPassword
                    : l10n.setBackupPassword,
                style: getEnteTextTheme(context).largeBold,
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.backupPasswordHint,
                    style: getEnteTextTheme(context).smallFaint,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: textController,
                    autofocus: true,
                    obscureText: isPasswordHidden,
                    decoration: InputDecoration(
                      hintText: l10n.enterPassword,
                      hintStyle: getEnteTextTheme(context).mini,
                      suffixIcon: IconButton(
                        icon: Icon(
                          isPasswordHidden
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () {
                          setState(() {
                            isPasswordHidden = !isPasswordHidden;
                          });
                        },
                      ),
                      errorText: errorText,
                    ),
                    onChanged: (text) {
                      setState(() {
                        if (text.length >= 8 && errorText != null) {
                          errorText = null;
                        }
                      });
                    },
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: errorText == null
                        ? const SizedBox.shrink()
                        : Padding(
                            key: ValueKey(errorText),
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              errorText!,
                              style: getEnteTextTheme(context)
                                  .mini
                                  .copyWith(color: Colors.redAccent),
                            ),
                          ),
                  ),
                ],
              ),
              actions: [
                Row(
                  children: [
                    Expanded(
                      child: ButtonWidget(
                        buttonType: ButtonType.secondary,
                        labelText: l10n.cancel,
                        onTap: () async => Navigator.of(context).pop(null),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ButtonWidget(
                        buttonType: ButtonType.primary,
                        labelText: l10n.saveAction,
                        isDisabled: textController.text.isEmpty,
                        onTap: () async {
                          if (textController.text.length < 8) {
                            setState(() {
                              errorText = l10n.passwordTooShort;
                            });
                            return;
                          }
                          Navigator.of(context).pop(textController.text.trim());
                        },
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<bool> _handleLocationSetup() async {
    if (Platform.isAndroid) {
      return _pickAndPersistAndroidLocation();
    }

    if (Platform.isIOS) {
      return _handleIosLocationSetup();
    }

    final pickedPath = await FilePicker.platform.getDirectoryPath();
    if (pickedPath != null) {
      return _persistLocation(
        pickedPath,
        successMessage: context.l10n.initialBackupCreated,
      );
    }
    return false;
  }

  /// Show iOS-specific backup location setup with iCloud option
  Future<bool> _handleIosLocationSetup() async {
    final l10n = context.l10n;

    // Check if iCloud is available
    final isICloudAvailable =
        await ICloudBackupService.instance.isICloudAvailable();

    final result = await showDialogWidget(
      title: l10n.chooseBackupLocation,
      context: context,
      body: l10n.iCloudBackupDescription,
      buttons: [
        if (isICloudAvailable)
          ButtonWidget(
            buttonType: ButtonType.primary,
            labelText: l10n.useICloud,
            isInAlert: true,
            buttonSize: ButtonSize.large,
            buttonAction: ButtonAction.first,
          ),
        ButtonWidget(
          buttonType:
              isICloudAvailable ? ButtonType.secondary : ButtonType.primary,
          labelText: l10n.selectLocalFolder,
          isInAlert: true,
          buttonSize: ButtonSize.large,
          buttonAction: ButtonAction.second,
        ),
        ButtonWidget(
          buttonType: ButtonType.secondary,
          labelText: l10n.cancel,
          isInAlert: true,
          buttonSize: ButtonSize.large,
          buttonAction: ButtonAction.cancel,
        ),
      ],
    );

    if (result?.action == ButtonAction.first && isICloudAvailable) {
      // Enable iCloud backup
      return _enableICloudBackup();
    } else if (result?.action == ButtonAction.second) {
      // Pick local folder
      final pickedPath = await FilePicker.platform.getDirectoryPath();
      if (pickedPath != null) {
        // Reject iCloud Drive paths
        if (_isICloudPath(pickedPath)) {
          _showSnackBar(l10n.iCloudNotSupported);
          return false;
        }
        // Disable iCloud if it was previously enabled
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_useICloudKey, false);
        if (mounted) {
          setState(() {
            _useICloud = false;
          });
        }
        return _persistLocation(
          pickedPath,
          successMessage: l10n.initialBackupCreated,
        );
      }
    }
    return false;
  }

  /// Enable iCloud backup on iOS
  Future<bool> _enableICloudBackup() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_useICloudKey, true);
    await prefs.remove('autoBackupPath');
    await prefs.remove(_treeUriKey);
    await prefs.setBool(_locationConfiguredKey, true);

    if (!mounted) return false;
    setState(() {
      _useICloud = true;
      _backupPath = null;
      _backupTreeUri = null;
    });

    _showSnackBar(context.l10n.iCloudBackupEnabled);
    return true;
  }

  String _simplifyPath(String fullPath) {
    if (fullPath.isEmpty) {
      return fullPath;
    }

    if (Platform.isAndroid) {
      if (fullPath.startsWith('content://')) {
        final decoded = Uri.decodeComponent(fullPath.split('/').last);
        return decoded.replaceFirst('primary:', '');
      }

      const rootsToRemove = <String>[
        '/storage/emulated/0/',
        '/storage/self/primary/',
      ];

      for (final root in rootsToRemove) {
        if (fullPath.startsWith(root)) {
          return fullPath.substring(root.length);
        }
      }
      return fullPath.split('/').last;
    }

    if (Platform.isIOS || Platform.isMacOS) {
      var simplified = fullPath;
      const fileScheme = 'file://';
      if (simplified.startsWith(fileScheme)) {
        simplified = simplified.substring(fileScheme.length);
      }
      final homePath = Platform.environment['HOME'];
      if (homePath != null && simplified.startsWith(homePath)) {
        simplified = simplified.replaceFirst(homePath, '~');
      }
      // iOS often prepends /private when surfacing sandboxed locations.
      const privatePrefix = '/private';
      if (simplified.startsWith(privatePrefix)) {
        simplified = simplified.substring(privatePrefix.length);
      }

      const icloudMarker = '/Mobile Documents/';
      if (simplified.contains(icloudMarker)) {
        final afterMarker = simplified.split(icloudMarker).last;
        const cloudDocsPrefix = 'com~apple~CloudDocs/';
        if (afterMarker.startsWith(cloudDocsPrefix)) {
          final remaining = afterMarker.substring(cloudDocsPrefix.length);
          return remaining.isNotEmpty
              ? 'iCloud Drive/$remaining'
              : 'iCloud Drive';
        }
        if (afterMarker.isNotEmpty) {
          return afterMarker;
        }
      }

      const markers = <String>[
        '/File Provider Storage/',
        '/Documents/',
        '/tmp/',
      ];

      for (final marker in markers) {
        final index = simplified.indexOf(marker);
        if (index != -1) {
          final afterMarker = simplified.substring(index + marker.length);
          if (afterMarker.isNotEmpty) {
            return afterMarker;
          }
          final fallbackSegments =
              marker.split('/').where((segment) => segment.isNotEmpty).toList();
          if (fallbackSegments.isNotEmpty) {
            return fallbackSegments.last;
          }
          return simplified;
        }
      }

      final segments =
          simplified.split('/').where((segment) => segment.isNotEmpty).toList();
      if (segments.length >= 2) {
        return segments.sublist(segments.length - 2).join('/');
      }
      if (segments.isNotEmpty) {
        return segments.last;
      }
      return simplified;
    }

    return fullPath;
  }

  Future<bool> _pickAndSaveBackupLocation({
    String? successMessage,
    bool requireSelection = false,
    bool shouldTriggerBackup = true,
  }) async {
    if (Platform.isAndroid) {
      final saved = await _pickAndPersistAndroidLocation();
      if (saved) {
        if (shouldTriggerBackup) {
          await LocalBackupService.instance.triggerAutomaticBackup(
            isManual: true,
          );
        }
      } else if (requireSelection) {
        _showSnackBar(context.l10n.selectFolderToContinue);
      }
      return saved;
    } else {
      String? directoryPath = await FilePicker.platform.getDirectoryPath();

      if (directoryPath != null) {
        // On iOS, reject iCloud Drive paths as they don't work reliably
        if (Platform.isIOS && _isICloudPath(directoryPath)) {
          _showSnackBar(context.l10n.iCloudNotSupported);
          return false;
        }

        final saved = await _persistLocation(
          directoryPath,
          successMessage:
              successMessage ?? context.l10n.locationUpdatedAndBackupCreated,
        );
        if (saved) {
          if (shouldTriggerBackup) {
            await LocalBackupService.instance.triggerAutomaticBackup(
              isManual: true,
            );
          }
        }
        return saved;
      }
      if (requireSelection) {
        _showSnackBar(context.l10n.selectFolderToContinue);
      }
      return false;
    }
  }

  /// Check if the path is an iCloud Drive path
  bool _isICloudPath(String path) {
    return path.contains('/Mobile Documents/') ||
        path.contains('com~apple~CloudDocs');
  }

  Future<bool> _persistLocation(
    String path, {
    String? successMessage,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    Future<bool> savePath(String target) async {
      try {
        await Directory(target).create(recursive: true);
        await prefs.setString('autoBackupPath', target);
        await prefs.remove(_treeUriKey);
        await prefs.setBool(_locationConfiguredKey, true);
        if (!mounted) return false;
        setState(() {
          _backupPath = target;
          _backupTreeUri = null;
        });
        if (successMessage != null) {
          _showSnackBar(successMessage);
        }
        return true;
      } catch (_) {
        return false;
      }
    }

    if (await savePath(path)) {
      return true;
    }

    if (Platform.isAndroid) {
      final fallbackPath = await _androidPrivateBackupPath();
      if (fallbackPath != null && fallbackPath != path) {
        final savedFallback = await savePath(fallbackPath);
        if (savedFallback) {
          return true;
        }
      }
    }

    _showSnackBar(context.l10n.noDefaultBackupFolder);
    return false;
  }

  Future<String?> _androidPrivateBackupPath() async {
    final androidBasePath = await _androidBackupBasePath();
    return androidBasePath != null ? '$androidBasePath/EnteAuthBackups' : null;
  }

  Future<bool> _pickAndPersistAndroidLocation() async {
    final saf = SafUtil();
    final picked = await saf.pickDirectory(
      writePermission: true,
      persistablePermission: true,
    );
    final treeUri = picked?.uri;
    if (treeUri == null || treeUri.isEmpty) {
      return false;
    }
    return _persistAndroidLocation(treeUri);
  }

  Future<bool> _persistAndroidLocation(String treeUri) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString(_treeUriKey, treeUri);
      await prefs.setBool(_locationConfiguredKey, true);
      if (!mounted) return false;
      setState(() {
        _backupTreeUri = treeUri;
        _backupPath = null;
      });
      _showSnackBar(context.l10n.locationUpdatedAndBackupCreated);
      return true;
    } catch (_) {
      _showSnackBar(context.l10n.noDefaultBackupFolder);
      return false;
    }
  }

  Future<String?> _androidBackupBasePath() async {
    Directory directory = Directory('/storage/emulated/0/Download');
    if (await directory.exists()) {
      return directory.path;
    }

    final externalDir = await getExternalStorageDirectory();
    if (externalDir != null) {
      return externalDir.path;
    }

    return null;
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
