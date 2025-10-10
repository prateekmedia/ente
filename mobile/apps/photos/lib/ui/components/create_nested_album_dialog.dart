import "package:flutter/material.dart";
import "package:photos/l10n/l10n.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/components/buttons/button_widget.dart";
import "package:photos/ui/components/collection_tree_picker.dart";
import "package:photos/ui/components/models/button_type.dart";
import "package:photos/ui/components/text_input_widget.dart";

/// Shows a dialog to create a new nested album with parent selection
Future<Collection?> showCreateNestedAlbumDialog(
  BuildContext context, {
  Collection? defaultParent,
}) async {
  return showDialog<Collection>(
    context: context,
    builder: (dialogContext) => _CreateNestedAlbumDialog(
      defaultParent: defaultParent,
    ),
  );
}

class _CreateNestedAlbumDialog extends StatefulWidget {
  final Collection? defaultParent;

  const _CreateNestedAlbumDialog({this.defaultParent});

  @override
  State<_CreateNestedAlbumDialog> createState() =>
      _CreateNestedAlbumDialogState();
}

class _CreateNestedAlbumDialogState extends State<_CreateNestedAlbumDialog> {
  final TextEditingController _nameController = TextEditingController();
  final CollectionsService _collectionsService = CollectionsService.instance;
  Collection? _selectedParent;
  bool _isCreating = false;

  @override
  void initState() {
    super.initState();
    _selectedParent = widget.defaultParent;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _createAlbum() async {
    final albumName = _nameController.text.trim();

    if (albumName.isEmpty) {
      return;
    }

    setState(() {
      _isCreating = true;
    });

    try {
      // Create the album
      final newAlbum = await _collectionsService.createAlbum(albumName);

      // Set parent if selected
      if (_selectedParent != null) {
        await _collectionsService.setParent(newAlbum, _selectedParent!.id);
      }

      if (mounted) {
        Navigator.of(context).pop(newAlbum);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCreating = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to create album: $e")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);

    return AlertDialog(
      title: Text(
        "Create album",
        style: textTheme.largeBold,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Album name input
            TextInputWidget(
              hintText: "Album name",
              prefixIcon: Icons.photo_album_outlined,
              textCapitalization: TextCapitalization.words,
              textEditingController: _nameController,
              autoFocus: true,
              onSubmit: (_) => _createAlbum(),
            ),

            const SizedBox(height: 24),

            // Parent album selection
            Text(
              "Parent album (optional):",
              style: textTheme.small.copyWith(color: colorScheme.textMuted),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: _isCreating
                  ? null
                  : () async {
                      await Navigator.of(context).push<int?>(
                        MaterialPageRoute(
                          builder: (pickerContext) => CollectionTreePicker(
                            title: "Select parent album",
                            currentParent: _selectedParent,
                            excludedCollectionIDs: const {},
                            onSelect: (parentID) {
                              setState(() {
                                _selectedParent = parentID != null
                                    ? _collectionsService
                                        .getCollectionByID(parentID)
                                    : null;
                              });
                            },
                          ),
                        ),
                      );
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
                      _selectedParent != null
                          ? Icons.folder
                          : Icons.folder_open,
                      color: colorScheme.textMuted,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _selectedParent?.displayName ?? "Root (No parent)",
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
      ),
      actions: [
        TextButton(
          onPressed: _isCreating ? null : () => Navigator.of(context).pop(),
          child: Text(
            context.l10n.cancel,
            style: textTheme.body.copyWith(color: colorScheme.textMuted),
          ),
        ),
        ButtonWidget(
          buttonType: ButtonType.neutral,
          labelText: "Create",
          isDisabled: _isCreating,
          onTap: _createAlbum,
          buttonSize: ButtonSize.small,
        ),
      ],
    );
  }
}
