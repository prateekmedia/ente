import "dart:async";
import 'dart:io';

import 'package:flutter/material.dart';
import "package:logging/logging.dart";
import 'package:photo_manager/photo_manager.dart';
import "package:photos/core/configuration.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/permission_granted_event.dart";
import "package:photos/events/sync_status_update_event.dart";
import "package:photos/generated/l10n.dart";
import "package:photos/l10n/l10n.dart";
import "package:photos/service_locator.dart";
import 'package:photos/services/sync/sync_service.dart';
import "package:photos/theme/ente_theme.dart";
import "package:photos/utils/dialog_util.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:styled_text/styled_text.dart";

class GrantPermissionsWidget extends StatefulWidget {
  const GrantPermissionsWidget({super.key});

  @override
  State<GrantPermissionsWidget> createState() => _GrantPermissionsWidgetState();
}

class _GrantPermissionsWidgetState extends State<GrantPermissionsWidget> {
  final Logger _logger = Logger("_GrantPermissionsWidgetState");

  @override
  Widget build(BuildContext context) {
    final isLightMode = Theme.of(context).brightness == Brightness.light;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            key: const ValueKey("skipPermissionButton"),
            onPressed: () async {
              // Skip both permissions AND device folder selection
              // This makes the test behave as if both screens were skipped

              final prefs = await SharedPreferences.getInstance();

              // CRITICAL: Tell PhotoManager to ignore permission checks
              // This prevents the native iOS permission dialog from appearing
              await PhotoManager.setIgnorePermissionCheck(true);

              // Mark permissions as granted (skip permission check)
              await prefs.setBool('has_granted_permissions', true);
              await prefs.setString(
                'permission_state',
                'PermissionState.authorized',
              );

              // Mark first import as completed to skip LoadingPhotosWidget/device folders
              await prefs.setBool('has_completed_first_import', true);

              // Mark all folders selected to skip BackupFolderSelectionPage
              await Configuration.instance.setSelectAllFoldersForBackup(true);

              // Fire events to trigger home screen rebuild
              Bus.instance.fire(PermissionGrantedEvent());
              Bus.instance.fire(
                SyncStatusUpdate(SyncStatus.completedFirstGalleryImport),
              );
            },
            child: Text(
              'Skip',
              style: getEnteTextTheme(context).small.copyWith(
                    color: getEnteColorScheme(context).textMuted,
                  ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 120),
          child: Column(
            children: [
              const SizedBox(
                height: 24,
              ),
              Center(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    isLightMode
                        ? Image.asset(
                            'assets/loading_photos_background.png',
                            color: Colors.white.withValues(alpha: 0.4),
                            colorBlendMode: BlendMode.modulate,
                          )
                        : Image.asset(
                            'assets/loading_photos_background_dark.png',
                          ),
                    Center(
                      child: Column(
                        children: [
                          const SizedBox(height: 42),
                          Image.asset(
                            "assets/gallery_locked.png",
                            height: 160,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 36),
              Padding(
                padding: const EdgeInsets.fromLTRB(40, 0, 40, 0),
                child: StyledText(
                  text: AppLocalizations.of(context).entePhotosPerm,
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall!
                      .copyWith(fontWeight: FontWeight.w700),
                  tags: {
                    'i': StyledTextTag(
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall!
                          .copyWith(fontWeight: FontWeight.w400),
                    ),
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: Container(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: getEnteColorScheme(context).backgroundBase,
              spreadRadius: 190,
              blurRadius: 30,
              offset: const Offset(0, 170),
            ),
          ],
        ),
        width: double.infinity,
        padding: const EdgeInsets.only(
          left: 20,
          right: 20,
          bottom: 16,
        ),
        child: OutlinedButton(
          key: const ValueKey("grantPermissionButton"),
          child: Text(AppLocalizations.of(context).grantPermission),
          onPressed: () async {
            try {
              final state =
                  await permissionService.requestPhotoMangerPermissions();
              _logger.info("Permission state: $state");
              if (state == PermissionState.authorized ||
                  state == PermissionState.limited) {
                await onPermissionGranted(state);
              } else if (state == PermissionState.denied) {
                await showChoiceDialog(
                  context,
                  title: context.l10n.allowPermTitle,
                  body: context.l10n.allowPermBody,
                  firstButtonLabel: context.l10n.openSettings,
                  firstButtonOnTap: () async {
                    if (Platform.isIOS) {
                      await PhotoManager.openSetting();
                    }
                  },
                );
              } else {
                throw Exception("Unknown permission state: $state");
              }
            } catch (e) {
              _logger.severe(
                "Failed to request permission: ${e.toString()}",
                e,
              );
              showGenericErrorDialog(context: context, error: e).ignore();
            }
          },
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  Future<void> onPermissionGranted(PermissionState state) async {
    _logger.info("Permission granted " + state.toString());
    await permissionService.onUpdatePermission(state);
    if (state == PermissionState.limited) {
      // when limited permission is granted, by default mark all folders for
      // backup
      await Configuration.instance.setSelectAllFoldersForBackup(true);
    }
    SyncService.instance.onPermissionGranted().ignore();
    Bus.instance.fire(PermissionGrantedEvent());
  }
}
