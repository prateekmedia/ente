import "package:flutter/material.dart";
import "package:photos/l10n/l10n.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/collection/collection_job.dart";
import "package:photos/services/collections_job_service.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/services/collections_tree_service.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/components/buttons/button_widget.dart";
import "package:photos/ui/components/collection_tree_picker.dart";
import "package:photos/utils/collection_validation_util.dart";
import "package:photos/utils/dialog_util.dart";
import "package:uuid/uuid.dart";

/// Shows a dialog to move an album to a different parent
Future<void> showMoveAlbumDialog(
  BuildContext context,
  Collection album,
) async {
  final colorScheme = getEnteColorScheme(context);
  final textTheme = getEnteTextTheme(context);
  final treeService = CollectionsTreeService.instance;
  final collectionsService = CollectionsService.instance;
  final jobService = CollectionsJobService.instance;

  // Get current parent
  final currentParentID = album.pubMagicMetadata.parentID;
  Collection? currentParent;
  if (currentParentID != null && currentParentID != 0) {
    currentParent = collectionsService.getCollectionByID(currentParentID);
  }

  // Build exclusion list (album itself and its descendants)
  final tree = treeService.getTree(forceRefresh: true);
  final descendants = treeService.getDescendants(album.id);
  final excludedIDs = {
    album.id,
    ...descendants.map((c) => c.id),
  };

  int? selectedParentID = currentParentID;
  Collection? selectedParent = currentParent;

  await showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        "Move \"${album.displayName}\"",
        style: textTheme.largeBold,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Current location:",
            style: textTheme.small.copyWith(color: colorScheme.textMuted),
          ),
          const SizedBox(height: 4),
          Text(
            currentParent?.displayName ?? "Root",
            style: textTheme.body,
          ),
          const SizedBox(height: 16),
          Text(
            "Select new parent album:",
            style: textTheme.small.copyWith(color: colorScheme.textMuted),
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: () async {
              final result = await Navigator.of(dialogContext).push<int?>(
                MaterialPageRoute(
                  builder: (pickerContext) => CollectionTreePicker(
                    title: "Select parent album",
                    currentParent: selectedParent,
                    excludedCollectionIDs: excludedIDs,
                    onSelect: (parentID) {
                      selectedParentID = parentID;
                      selectedParent = parentID != null
                          ? collectionsService.getCollectionByID(parentID)
                          : null;
                    },
                  ),
                ),
              );

              // Trigger rebuild if selection changed
              if (result != selectedParentID) {
                (dialogContext as Element).markNeedsBuild();
              }
            },
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: colorScheme.strokeFaint),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    selectedParent != null ? Icons.folder : Icons.folder_open,
                    color: colorScheme.textMuted,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      selectedParent?.displayName ?? "Root (No parent)",
                      style: textTheme.body,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    color: colorScheme.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(
            context.l10n.cancel,
            style: textTheme.body.copyWith(color: colorScheme.textMuted),
          ),
        ),
        TextButton(
          onPressed: () async {
            // Check if parent changed
            if (selectedParentID == currentParentID) {
              Navigator.of(dialogContext).pop();
              return;
            }

            // Validate move
            final validation = CollectionValidationUtil.validateSetParent(
              child: album,
              newParent: selectedParent,
              currentUserID: collectionsService.config.getUserID()!,
              tree: tree,
            );

            if (!validation.isValid) {
              Navigator.of(dialogContext).pop();
              await showGenericErrorDialog(
                context: context,
                error: validation.errorMessage ?? "Unknown error",
              );
              return;
            }

            // Show warning if present
            if (validation.hasWarning) {
              final proceed = await showChoiceActionSheet(
                context,
                title: "Warning",
                body: validation.warningMessage!,
                firstButtonLabel: "Cancel",
                secondButtonLabel: "Continue",
              );
              if (proceed?.action != ButtonAction.second) {
                Navigator.of(dialogContext).pop();
                return;
              }
            }

            // Create job and execute
            final job = CollectionJob(
              id: const Uuid().v4(),
              type: CollectionJobType.move,
              targetCollectionID: album.id,
              params: {
                'childID': album.id,
                'newParentID': selectedParentID,
              },
              createdAt: DateTime.now().millisecondsSinceEpoch,
            );

            await jobService.enqueueJob(job);

            Navigator.of(dialogContext).pop();

            // Show success message
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    selectedParent != null
                        ? "Moving \"${album.displayName}\" to \"${selectedParent!.displayName}\""
                        : "Moving \"${album.displayName}\" to root",
                  ),
                ),
              );
            }
          },
          child: Text(
            "Move",
            style: textTheme.body.copyWith(color: colorScheme.primary700),
          ),
        ),
      ],
    ),
  );
}
