import 'package:flutter/material.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/generated/l10n.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/collection/collection_items.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/collections_service.dart';
import 'package:photos/theme/ente_theme.dart';
import 'package:photos/ui/collections/collection_item_widget.dart';
import 'package:photos/ui/components/buttons/button_widget.dart';
import 'package:photos/ui/components/models/button_type.dart';

/// A hierarchical album picker that allows navigation through nested albums
/// with breadcrumb navigation and optional multi-selection.
class HierarchicalAlbumPicker extends StatefulWidget {
  final Function(Collection)? onAlbumSelected;
  final Function(List<Collection>)? onMultipleAlbumsSelected;
  final bool allowMultipleSelection;
  final bool showCreateAlbumOption;
  final String? searchQuery;
  final List<Collection>? excludedCollections;
  final bool showOnlyOwnedAlbums;
  final bool showHiddenAlbums;
  final String title;
  final String? actionButtonText;

  const HierarchicalAlbumPicker({
    super.key,
    this.onAlbumSelected,
    this.onMultipleAlbumsSelected,
    this.allowMultipleSelection = false,
    this.showCreateAlbumOption = true,
    this.searchQuery,
    this.excludedCollections,
    this.showOnlyOwnedAlbums = false,
    this.showHiddenAlbums = false,
    required this.title,
    this.actionButtonText,
  });

  @override
  State<HierarchicalAlbumPicker> createState() => _HierarchicalAlbumPickerState();
}

class _HierarchicalAlbumPickerState extends State<HierarchicalAlbumPicker> {
  Collection? _currentLocation;
  final List<Collection?> _navigationStack = [null]; // null represents root
  final Set<Collection> _selectedCollections = {};
  List<Collection> _allCollections = [];
  List<Collection> _currentLevelCollections = [];

  @override
  void initState() {
    super.initState();
    _loadCollections();
  }

  void _loadCollections() {
    final userId = Configuration.instance.getUserID()!;
    
    // Get collections based on filters
    if (widget.showHiddenAlbums) {
      _allCollections = CollectionsService.instance
          .getHiddenCollections(includeDefaultHidden: false)
          .toList();
    } else {
      _allCollections = CollectionsService.instance
          .getActiveCollections()
          .toList();
    }

    // Apply additional filters
    if (widget.showOnlyOwnedAlbums) {
      _allCollections = _allCollections
          .where((c) => c.owner?.id == userId)
          .toList();
    }

    // Exclude specified collections
    if (widget.excludedCollections != null) {
      _allCollections = _allCollections
          .where((c) => !widget.excludedCollections!.contains(c))
          .toList();
    }

    // Filter out system collections from nested view
    _allCollections = _allCollections
        .where((c) => c.type != CollectionType.favorites && 
                      c.type != CollectionType.uncategorized &&
                      !c.isDefaultHidden())
        .toList();

    // Sort by name
    _allCollections.sort((a, b) => a.displayName.compareTo(b.displayName));

    // Update current level collections
    _updateCurrentLevelCollections();
  }

  void _updateCurrentLevelCollections() {
    if (widget.searchQuery != null && widget.searchQuery!.isNotEmpty) {
      // Show filtered collections flat when searching
      _currentLevelCollections = _allCollections
          .where((c) => c.displayName
              .toLowerCase()
              .contains(widget.searchQuery!.toLowerCase()))
          .toList();
    } else {
      // Show hierarchical view
      final localEnabled = localSettings.isNestedViewEnabled ?? false;
      final serverEnabled = flagService.isNestedAlbumsEnabled;
      final useHierarchical = localEnabled && serverEnabled;

      if (useHierarchical) {
        // Get collections at current level
        _currentLevelCollections = _allCollections
            .where((c) => c.parentID == _currentLocation?.id)
            .toList();
      } else {
        // Show flat list
        _currentLevelCollections = _allCollections;
      }
    }

    setState(() {});
  }

  void _navigateTo(Collection? collection) {
    setState(() {
      _currentLocation = collection;
      
      // Update navigation stack
      if (collection == null) {
        // Going to root
        _navigationStack.clear();
        _navigationStack.add(null);
      } else {
        // Check if we're going back in the stack
        final existingIndex = _navigationStack.indexOf(collection);
        if (existingIndex != -1) {
          // Remove everything after this point
          _navigationStack.removeRange(existingIndex + 1, _navigationStack.length);
        } else {
          // Going forward
          _navigationStack.add(collection);
        }
      }
      
      _updateCurrentLevelCollections();
    });
  }

  Widget _buildBreadcrumb() {
    if (widget.searchQuery != null && widget.searchQuery!.isNotEmpty) {
      return const SizedBox.shrink();
    }

    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);
    
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: colorScheme.backgroundElevated,
        border: Border(
          bottom: BorderSide(
            color: colorScheme.strokeFaint,
            width: 1,
          ),
        ),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _navigationStack.length,
        itemBuilder: (context, index) {
          final item = _navigationStack[index];
          final isLast = index == _navigationStack.length - 1;
          
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: isLast ? null : () => _navigateTo(item),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    item?.displayName ?? AppLocalizations.of(context).albums,
                    style: textTheme.body.copyWith(
                      color: isLast 
                          ? colorScheme.textBase 
                          : colorScheme.primary500,
                      fontWeight: isLast ? FontWeight.w500 : FontWeight.normal,
                    ),
                  ),
                ),
              ),
              if (!isLast)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: colorScheme.strokeMuted,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildAlbumItem(Collection collection) {
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);
    
    // Check if has children (only in hierarchical mode)
    final localEnabled = localSettings.isNestedViewEnabled ?? false;
    final serverEnabled = flagService.isNestedAlbumsEnabled;
    final useHierarchical = localEnabled && serverEnabled;
    
    final hasChildren = useHierarchical &&
        _allCollections.any((c) => c.parentID == collection.id);
    
    final isSelected = _selectedCollections.contains(collection);
    
    return InkWell(
      onTap: () {
        if (widget.allowMultipleSelection) {
          setState(() {
            if (isSelected) {
              _selectedCollections.remove(collection);
            } else {
              _selectedCollections.add(collection);
            }
          });
        } else if (hasChildren && widget.searchQuery?.isEmpty != false) {
          _navigateTo(collection);
        } else {
          widget.onAlbumSelected?.call(collection);
          Navigator.of(context).pop();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            if (widget.allowMultipleSelection)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Icon(
                  isSelected 
                      ? Icons.check_box
                      : Icons.check_box_outline_blank,
                  color: isSelected 
                      ? colorScheme.primary500
                      : colorScheme.strokeBase,
                  size: 24,
                ),
              ),
            Icon(
              Icons.folder_outlined,
              color: colorScheme.strokeBase,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    collection.displayName,
                    style: textTheme.body,
                  ),
                  if (widget.searchQuery != null && widget.searchQuery!.isNotEmpty)
                    Text(
                      _getAlbumPath(collection),
                      style: textTheme.miniMuted,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (hasChildren && widget.searchQuery?.isEmpty != false)
              Icon(
                Icons.chevron_right,
                size: 20,
                color: colorScheme.strokeMuted,
              ),
          ],
        ),
      ),
    );
  }

  String _getAlbumPath(Collection collection) {
    final path = <String>[];
    Collection? current = collection;
    
    while (current != null && current.parentID != null) {
      final parent = _allCollections.firstWhere(
        (c) => c.id == current!.parentID,
        orElse: () => collection,
      );
      if (parent.id == collection.id) break;
      path.insert(0, parent.displayName);
      current = parent;
    }
    
    return path.isEmpty ? '' : path.join(' > ');
  }

  Widget _buildCreateAlbumOption() {
    if (!widget.showCreateAlbumOption || 
        (widget.searchQuery != null && widget.searchQuery!.isNotEmpty)) {
      return const SizedBox.shrink();
    }

    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);
    
    return InkWell(
      onTap: () async {
        // Show create album dialog
        final albumName = await _showCreateAlbumDialog();
        if (albumName != null && albumName.isNotEmpty) {
          Collection newCollection;
          if (_currentLocation != null) {
            // Create sub-album
            newCollection = await CollectionsService.instance
                .createSubAlbum(_currentLocation!, albumName);
          } else {
            // Create root album
            newCollection = await CollectionsService.instance
                .createAlbum(albumName);
          }
          
          if (widget.allowMultipleSelection) {
            setState(() {
              _selectedCollections.add(newCollection);
              _allCollections.add(newCollection);
              _updateCurrentLevelCollections();
            });
          } else {
            widget.onAlbumSelected?.call(newCollection);
            Navigator.of(context).pop();
          }
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: colorScheme.fillFaint,
        ),
        child: Row(
          children: [
            Icon(
              Icons.add,
              color: colorScheme.primary500,
              size: 24,
            ),
            const SizedBox(width: 12),
            Text(
              _currentLocation != null
                  ? AppLocalizations.of(context).createNewSubAlbum
                  : AppLocalizations.of(context).createNewAlbum,
              style: textTheme.body.copyWith(
                color: colorScheme.primary500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _showCreateAlbumDialog() async {
    String? albumName;
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            _currentLocation != null
                ? AppLocalizations.of(context).createNewSubAlbum
                : AppLocalizations.of(context).createNewAlbum,
          ),
          content: TextField(
            autofocus: true,
            decoration: InputDecoration(
              hintText: AppLocalizations.of(context).albumName,
            ),
            onChanged: (value) {
              albumName = value;
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(AppLocalizations.of(context).cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(albumName),
              child: Text(AppLocalizations.of(context).create),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);
    
    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: textTheme.largeBold,
                ),
              ),
              if (widget.allowMultipleSelection && _selectedCollections.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: colorScheme.fillFaint,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_selectedCollections.length}',
                    style: textTheme.small,
                  ),
                ),
            ],
          ),
        ),
        
        // Breadcrumb
        _buildBreadcrumb(),
        
        // Albums list
        Expanded(
          child: _currentLevelCollections.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.folder_off_outlined,
                        size: 64,
                        color: colorScheme.strokeFaint,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        AppLocalizations.of(context).noAlbumsFound,
                        style: textTheme.body.copyWith(
                          color: colorScheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView(
                  children: [
                    _buildCreateAlbumOption(),
                    ..._currentLevelCollections.map(_buildAlbumItem),
                  ],
                ),
        ),
        
        // Action button for multiple selection
        if (widget.allowMultipleSelection)
          SafeArea(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: colorScheme.strokeFaint,
                  ),
                ),
              ),
              child: ButtonWidget(
                buttonType: ButtonType.primary,
                labelText: widget.actionButtonText ?? 
                    AppLocalizations.of(context).add,
                isDisabled: _selectedCollections.isEmpty,
                onTap: () {
                  widget.onMultipleAlbumsSelected?.call(
                    _selectedCollections.toList(),
                  );
                  Navigator.of(context).pop();
                },
              ),
            ),
          ),
      ],
    );
  }
}