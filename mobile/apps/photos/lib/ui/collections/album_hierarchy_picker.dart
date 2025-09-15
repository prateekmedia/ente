import 'package:flutter/material.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/services/collections_service.dart';
import 'package:photos/theme/ente_theme.dart';
import 'package:photos/ui/components/buttons/button_widget.dart';
import 'package:photos/ui/components/models/button_type.dart';

class AlbumHierarchyPicker extends StatefulWidget {
  final Collection? collectionToMove;
  final Collection? currentParent;
  final Function(Collection?) onDestinationSelected;

  const AlbumHierarchyPicker({
    super.key,
    this.collectionToMove,
    this.currentParent,
    required this.onDestinationSelected,
  });

  @override
  State<AlbumHierarchyPicker> createState() => _AlbumHierarchyPickerState();
}

class _AlbumHierarchyPickerState extends State<AlbumHierarchyPicker> {
  Collection? _selectedDestination;
  late List<Collection> _allCollections;
  final Map<int, bool> _expandedCollections = {};

  @override
  void initState() {
    super.initState();
    _selectedDestination = widget.currentParent;
    _loadCollections();
  }

  void _loadCollections() {
    final userId = Configuration.instance.getUserID()!;
    _allCollections = CollectionsService.instance
        .getActiveCollections()
        .where((c) => c.owner?.id == userId)
        .where((c) => !_isDescendantOf(c, widget.collectionToMove))
        .where((c) => c.id != widget.collectionToMove?.id)
        .toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
  }

  bool _isDescendantOf(Collection? child, Collection? parent) {
    if (child == null || parent == null) return false;
    if (child.parentID == null) return false;
    if (child.parentID == parent.id) return true;
    
    // Check recursively
    Collection? parentCollection;
    try {
      parentCollection = _allCollections.firstWhere(
        (c) => c.id == child.parentID,
      );
    } catch (e) {
      return false;
    }
    if (parentCollection == null) return false;
    return _isDescendantOf(parentCollection, parent);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = getEnteTextTheme(context);
    final colorScheme = getEnteColorScheme(context);
    
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.collectionToMove != null 
              ? 'Move "${widget.collectionToMove!.displayName}"'
              : 'Select Destination',
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                // Root option at the top
                _buildRootOption(context),
                const Divider(height: 1),
                // Other collections
                ..._buildCollectionTree(null, 0),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: ButtonWidget(
                buttonType: ButtonType.primary,
                labelText: "Move",
                onTap: _canMove() ? () async => _performMove() : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRootOption(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);
    final isSelected = _selectedDestination == null;
    
    return InkWell(
      onTap: () {
        setState(() {
          _selectedDestination = null;
        });
      },
      child: Container(
        color: isSelected ? colorScheme.fillFaint : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              Icons.home_outlined,
              color: colorScheme.strokeBase,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Root Level',
                    style: textTheme.body,
                  ),
                  Text(
                    'Move to top level of your library',
                    style: textTheme.miniMuted,
                  ),
                ],
              ),
            ),
            Radio<Collection?>(
              value: null,
              groupValue: _selectedDestination,
              onChanged: (value) {
                setState(() {
                  _selectedDestination = value;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildCollectionTree(int? parentId, int level) {
    final collections = _allCollections
        .where((c) => c.parentID == parentId)
        .toList();
    
    final widgets = <Widget>[];
    for (final collection in collections) {
      widgets.add(_buildCollectionItem(collection, level));
      
      // Add children if expanded
      if (_expandedCollections[collection.id] ?? false) {
        widgets.addAll(_buildCollectionTree(collection.id, level + 1));
      }
    }
    
    return widgets;
  }

  Widget _buildCollectionItem(Collection collection, int level) {
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);
    final hasChildren = _allCollections.any((c) => c.parentID == collection.id);
    final isSelected = _selectedDestination?.id == collection.id;
    final isCurrentParent = widget.currentParent?.id == collection.id;
    
    return InkWell(
      onTap: () {
        setState(() {
          _selectedDestination = collection;
        });
      },
      child: Container(
        color: isSelected ? colorScheme.fillFaint : null,
        padding: EdgeInsets.only(
          left: 16 + (level * 24.0),
          right: 16,
          top: 8,
          bottom: 8,
        ),
        child: Row(
          children: [
            if (hasChildren)
              GestureDetector(
                onTap: () {
                  setState(() {
                    _expandedCollections[collection.id] = 
                        !(_expandedCollections[collection.id] ?? false);
                  });
                },
                child: Icon(
                  _expandedCollections[collection.id] ?? false
                      ? Icons.expand_more
                      : Icons.chevron_right,
                  size: 20,
                  color: colorScheme.strokeMuted,
                ),
              )
            else
              const SizedBox(width: 20),
            const SizedBox(width: 8),
            Icon(
              Icons.folder_outlined,
              color: colorScheme.strokeBase,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    collection.displayName,
                    style: textTheme.body,
                  ),
                  if (isCurrentParent)
                    Text(
                      'Current location',
                      style: textTheme.miniMuted.copyWith(
                        color: colorScheme.primary500,
                      ),
                    ),
                ],
              ),
            ),
            Radio<Collection?>(
              value: collection,
              groupValue: _selectedDestination,
              onChanged: (value) {
                setState(() {
                  _selectedDestination = value;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  bool _canMove() {
    // Can't move if no destination selected and already at root
    if (_selectedDestination == null && widget.currentParent == null) {
      return false;
    }
    // Can't move to the same parent
    if (_selectedDestination?.id == widget.currentParent?.id) {
      return false;
    }
    return true;
  }

  void _performMove() {
    widget.onDestinationSelected(_selectedDestination);
    Navigator.of(context).pop();
  }
}