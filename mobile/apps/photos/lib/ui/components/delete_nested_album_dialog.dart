import "package:flutter/material.dart";
import "package:photos/generated/l10n.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/collection/collection_job.dart";
import "package:photos/services/collections_job_service.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/services/collections_tree_service.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/components/buttons/button_widget.dart";
import "package:photos/ui/components/models/button_type.dart";
import "package:uuid/uuid.dart";

/// Result from delete nested album dialog
enum DeleteNestedAlbumAction {
  cancel,
  deleteAlbumOnly,
  deleteSubtree,
}

/// Shows a dialog to delete album with options for handling descendants
Future<DeleteNestedAlbumAction> showDeleteNestedAlbumDialog(
  BuildContext context, {
  required Collection collection,
  required bool keepPhotos,
}) async {
  final treeService = CollectionsTreeService.instance;
  final descendants = treeService.getDescendants(collection.id);
  final hasChildren = descendants.isNotEmpty;

  final colorScheme = getEnteColorScheme(context);
  final textTheme = getEnteTextTheme(context);

  if (!hasChildren) {
    // No descendants, just confirm and proceed
    return DeleteNestedAlbumAction.deleteAlbumOnly;
  }

  final result = await showDialog<DeleteNestedAlbumAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        "Delete \"${collection.displayName}\"",
        style: textTheme.largeBold,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "This album has ${descendants.length} sub-album${descendants.length == 1 ? '' : 's'}.",
            style: textTheme.body,
          ),
          const SizedBox(height: 16),
          Text(
            "What would you like to do?",
            style: textTheme.bodyBold,
          ),
          const SizedBox(height: 12),
          // Option 1: Delete album only (reparent children)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.backgroundElevated,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.strokeFaint),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.drive_file_move_outline,
                      size: 16,
                      color: colorScheme.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Keep sub-albums",
                        style: textTheme.bodyBold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: Text(
                    "Sub-albums will be moved to root level",
                    style: textTheme.small.copyWith(
                      color: colorScheme.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Option 2: Delete entire subtree
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.fillFaintPressed,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.strokeFaint),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.delete_sweep,
                      size: 16,
                      color: colorScheme.warning700,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Delete all (${descendants.length + 1} albums)",
                        style: textTheme.bodyBold.copyWith(
                          color: colorScheme.warning700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: Text(
                    "This will delete all sub-albums as well",
                    style: textTheme.small.copyWith(
                      color: colorScheme.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(DeleteNestedAlbumAction.cancel),
          child: Text(
            AppLocalizations.of(context).cancel,
            style: textTheme.body.copyWith(color: colorScheme.textMuted),
          ),
        ),
        ButtonWidget(
          buttonType: ButtonType.neutral,
          labelText: "Keep sub-albums",
          buttonSize: ButtonSize.small,
          onTap: () async {
            // Reparent children to root
            await _reparentChildrenToRoot(collection, descendants);
            if (dialogContext.mounted) {
              Navigator.of(dialogContext)
                  .pop(DeleteNestedAlbumAction.deleteAlbumOnly);
            }
          },
        ),
        ButtonWidget(
          buttonType: ButtonType.critical,
          labelText: "Delete all",
          buttonSize: ButtonSize.small,
          onTap: () async {
            // Create subtree delete job
            await _createSubtreeDeleteJob(
              collection,
              descendants,
              keepPhotos,
            );
            if (dialogContext.mounted) {
              Navigator.of(dialogContext)
                  .pop(DeleteNestedAlbumAction.deleteSubtree);
            }
          },
        ),
      ],
    ),
  );

  return result ?? DeleteNestedAlbumAction.cancel;
}

/// Reparents all direct children to root (parentID = 0)
Future<void> _reparentChildrenToRoot(
  Collection parent,
  List<Collection> descendants,
) async {
  final collectionsService = CollectionsService.instance;
  final treeService = CollectionsTreeService.instance;

  // Get only direct children
  final directChildren = treeService.getChildren(parent.id);

  // Reparent each direct child to root
  for (final child in directChildren) {
    await collectionsService.setParent(child, 0);
  }
}

/// Creates a job to delete the entire subtree
Future<void> _createSubtreeDeleteJob(
  Collection collection,
  List<Collection> descendants,
  bool keepPhotos,
) async {
  final jobService = CollectionsJobService.instance;

  final job = CollectionJob(
    id: const Uuid().v4(),
    type: CollectionJobType.subtreeDelete,
    targetCollectionID: collection.id,
    params: {
      'keepPhotos': keepPhotos,
      'descendantIDs': descendants.map((c) => c.id).toList(),
    },
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );

  await jobService.enqueueJob(job);
}
