import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import "package:photos/core/configuration.dart";
import 'package:photos/core/event_bus.dart';
import 'package:photos/events/collection_updated_event.dart';
import "package:photos/generated/l10n.dart";
import 'package:photos/models/collection/collection.dart';
import 'package:photos/services/collections_service.dart';
import "package:photos/theme/ente_theme.dart";
import 'package:photos/ui/common/loading_widget.dart';
import "package:photos/ui/viewer/gallery/empty_state.dart";

class NestedCollectionView extends StatefulWidget {
  final Collection? parentCollection;
  final Function(Collection)? onCollectionTap;

  const NestedCollectionView({
    super.key,
    this.parentCollection,
    this.onCollectionTap,
  });

  @override
  State<NestedCollectionView> createState() => _NestedCollectionViewState();
}

class _NestedCollectionViewState extends State<NestedCollectionView>
    with AutomaticKeepAliveClientMixin {
  final _logger = Logger((_NestedCollectionViewState).toString());
  late StreamSubscription<CollectionUpdatedEvent> _collectionUpdatesSubscription;
  
  List<Collection> _collections = [];
  bool _isLoading = true;
  
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _collectionUpdatesSubscription =
        Bus.instance.on<CollectionUpdatedEvent>().listen((event) {
      if (mounted) {
        _loadCollections();
      }
    });
    _loadCollections();
  }

  @override
  void dispose() {
    _collectionUpdatesSubscription.cancel();
    super.dispose();
  }

  Future<void> _loadCollections() async {
    if (mounted) {
      setState(() => _isLoading = true);
    }
    
    try {
      List<Collection> collections;
      
      if (widget.parentCollection == null) {
        // Load root level collections
        collections = CollectionsService.instance.getRootCollections();
      } else {
        // Load child collections of parent
        collections = CollectionsService.instance
            .getChildCollections(widget.parentCollection!.id);
      }
      
      collections.sort((a, b) => a.displayName.compareTo(b.displayName));
      
      if (mounted) {
        setState(() {
          _collections = collections;
          _isLoading = false;
        });
      }
    } catch (e, s) {
      _logger.severe("Failed to load collections", e, s);
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    
    if (_isLoading) {
      return const EnteLoadingWidget();
    }
    
    if (_collections.isEmpty) {
      return EmptyState(
        text: widget.parentCollection == null
            ? S.of(context).noAlbumsFound
            : S.of(context).noSubAlbumsFound,
        detailText: widget.parentCollection == null
            ? S.of(context).createYourFirstAlbum
            : S.of(context).createSubAlbum,
      );
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.parentCollection != null) ...[
          _buildBreadcrumb(),
          const SizedBox(height: 16),
        ],
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadCollections,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _collections.length,
              itemBuilder: (context, index) {
                final collection = _collections[index];
                return _buildCollectionTile(collection);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBreadcrumb() {
    final parts = widget.parentCollection!.breadcrumbPath.split(' > ');
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        children: parts.asMap().entries.map((entry) {
          final index = entry.key;
          final part = entry.value;
          final isLast = index == parts.length - 1;
          
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (index > 0) ...[
                const Icon(Icons.chevron_right, size: 16),
                const SizedBox(width: 4),
              ],
              Text(
                part,
                style: TextStyle(
                  color: isLast 
                      ? getEnteColorScheme(context).textMuted
                      : getEnteColorScheme(context).primary500,
                  fontWeight: isLast ? FontWeight.normal : FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCollectionTile(Collection collection) {
    final hasChildren = CollectionsService.instance
        .getChildCollections(collection.id)
        .isNotEmpty;
    
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: getEnteColorScheme(context).primary500.withOpacity(0.1),
          child: Icon(
            hasChildren ? Icons.folder : Icons.photo_album,
            color: getEnteColorScheme(context).primary500,
          ),
        ),
        title: Text(
          collection.displayName,
          style: getEnteTextTheme(context).bodyBold,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (collection.hierarchyPath != null) ...[
              Text(
                collection.hierarchyPath!,
                style: getEnteTextTheme(context).miniMuted,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
            ],
            Row(
              children: [
                if (hasChildren)
                  Text(
                    '${CollectionsService.instance.getChildCollections(collection.id).length} sub-albums • ',
                    style: getEnteTextTheme(context).miniMuted,
                  ),
                Text(
                  '${collection.id} photos', // Placeholder - would need actual file count
                  style: getEnteTextTheme(context).miniMuted,
                ),
              ],
            ),
          ],
        ),
        trailing: hasChildren
            ? const Icon(Icons.keyboard_arrow_right)
            : null,
        onTap: () {
          if (widget.onCollectionTap != null) {
            widget.onCollectionTap!(collection);
          }
        },
      ),
    );
  }
}