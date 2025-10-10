import "package:flutter/material.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/collection/collection_job.dart";
import "package:photos/services/collections_job_service.dart";
import "package:photos/services/collections_tree_service.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/components/buttons/button_widget.dart";
import "package:photos/ui/components/models/button_type.dart";
import "package:uuid/uuid.dart";

/// Shows a dialog to apply visibility changes (hide/archive) to album and descendants
Future<bool> showCascadeVisibilityDialog(
  BuildContext context, {
  required Collection collection,
  required int newVisibility,
  required bool isArchive,
}) async {
  final treeService = CollectionsTreeService.instance;
  final descendants = treeService.getDescendants(collection.id);
  final totalCount = descendants.length + 1; // +1 for the album itself

  final colorScheme = getEnteColorScheme(context);
  final textTheme = getEnteTextTheme(context);

  final actionName = isArchive ? "archive" : "hide";
  final title = isArchive ? "Archive album" : "Hide album";

  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        title,
        style: textTheme.largeBold,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "\"${collection.displayName}\" ${descendants.isEmpty ? 'has no sub-albums' : 'has ${descendants.length} sub-album${descendants.length == 1 ? '' : 's'}'}.",
            style: textTheme.body,
          ),
          if (descendants.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              "Do you want to $actionName the sub-albums as well?",
              style: textTheme.bodyBold,
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.backgroundElevated,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colorScheme.strokeFaint),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: colorScheme.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "This will $actionName $totalCount album${totalCount == 1 ? '' : 's'} in total",
                      style: textTheme.small.copyWith(
                        color: colorScheme.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(
            descendants.isEmpty ? "Cancel" : "Only this album",
            style: textTheme.body.copyWith(color: colorScheme.textMuted),
          ),
        ),
        if (descendants.isNotEmpty)
          ButtonWidget(
            buttonType: ButtonType.neutral,
            labelText: "Include sub-albums",
            buttonSize: ButtonSize.small,
            onTap: () async {
              await _createCascadeVisibilityJob(
                collection,
                descendants,
                newVisibility,
                isArchive,
              );
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop(true);
              }
            },
          )
        else
          ButtonWidget(
            buttonType: ButtonType.neutral,
            labelText: "OK",
            buttonSize: ButtonSize.small,
            onTap: () async => Navigator.of(dialogContext).pop(false),
          ),
      ],
    ),
  );

  return result ?? false;
}

Future<void> _createCascadeVisibilityJob(
  Collection collection,
  List<Collection> descendants,
  int newVisibility,
  bool isArchive,
) async {
  final jobService = CollectionsJobService.instance;

  // Determine if we're hiding/archiving (true) or unhiding/unarchiving (false)
  final shouldApply = isArchive
      ? (newVisibility == 1) // 1 = archive
      : (newVisibility == 2); // 2 = hidden

  // Create job for cascade visibility change
  final job = CollectionJob(
    id: const Uuid().v4(),
    type: isArchive
        ? CollectionJobType.cascadeArchive
        : CollectionJobType.cascadeHide,
    targetCollectionID: collection.id,
    params: {
      if (isArchive) 'archive': shouldApply else 'hide': shouldApply,
    },
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );

  await jobService.enqueueJob(job);
}
