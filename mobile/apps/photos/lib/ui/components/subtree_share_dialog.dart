import "package:flutter/material.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/collection/collection_job.dart";
import "package:photos/services/collections_job_service.dart";
import "package:photos/services/collections_tree_service.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/components/buttons/button_widget.dart";
import "package:photos/ui/components/models/button_type.dart";
import "package:uuid/uuid.dart";

/// Shows a dialog to share album with option to include descendants
Future<bool> showSubtreeShareDialog(
  BuildContext context, {
  required Collection collection,
  required String email,
  required String publicKey,
  required CollectionParticipantRole role,
}) async {
  final treeService = CollectionsTreeService.instance;
  final descendants = treeService.getDescendants(collection.id);
  final totalCount = descendants.length + 1; // +1 for the album itself

  final colorScheme = getEnteColorScheme(context);
  final textTheme = getEnteTextTheme(context);

  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        "Share album",
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
              "Do you want to share the sub-albums as well?",
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
                      "This will share $totalCount album${totalCount == 1 ? '' : 's'} with $email",
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
              await _createSubtreeShareJob(
                collection,
                email,
                publicKey,
                role,
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

/// Shows a dialog to unshare album with option to include descendants
Future<bool> showSubtreeUnshareDialog(
  BuildContext context, {
  required Collection collection,
  required String email,
}) async {
  final treeService = CollectionsTreeService.instance;
  final descendants = treeService.getDescendants(collection.id);
  final totalCount = descendants.length + 1;

  final colorScheme = getEnteColorScheme(context);
  final textTheme = getEnteTextTheme(context);

  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        "Remove participant",
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
              "Do you want to remove $email from the sub-albums as well?",
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
                      "This will remove $email from $totalCount album${totalCount == 1 ? '' : 's'}",
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
              await _createSubtreeUnshareJob(collection, email);
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

Future<void> _createSubtreeShareJob(
  Collection collection,
  String email,
  String publicKey,
  CollectionParticipantRole role,
) async {
  final jobService = CollectionsJobService.instance;

  final job = CollectionJob(
    id: const Uuid().v4(),
    type: CollectionJobType.subtreeShare,
    targetCollectionID: collection.id,
    params: {
      'email': email,
      'publicKey': publicKey,
      'role': role.toStringVal(),
    },
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );

  await jobService.enqueueJob(job);
}

Future<void> _createSubtreeUnshareJob(
  Collection collection,
  String email,
) async {
  final jobService = CollectionsJobService.instance;

  final job = CollectionJob(
    id: const Uuid().v4(),
    type: CollectionJobType.subtreeUnshare,
    targetCollectionID: collection.id,
    params: {
      'email': email,
    },
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );

  await jobService.enqueueJob(job);
}
