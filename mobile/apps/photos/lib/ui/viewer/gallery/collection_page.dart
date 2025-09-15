import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/db/files_db.dart';
import "package:photos/events/collection_meta_event.dart";
import 'package:photos/events/collection_updated_event.dart';
import 'package:photos/events/files_updated_event.dart';
import 'package:photos/events/nested_collections_setting_event.dart';
import "package:photos/models/collection/collection.dart";
import 'package:photos/models/collection/collection_items.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file_load_result.dart';
import 'package:photos/models/gallery_type.dart';
import "package:photos/models/search/hierarchical/album_filter.dart";
import "package:photos/models/search/hierarchical/hierarchical_search_filter.dart";
import 'package:photos/models/selected_albums.dart';
import 'package:photos/models/selected_files.dart';
import "package:photos/service_locator.dart";
import 'package:photos/services/collections_service.dart';
import 'package:photos/services/ignored_files_service.dart';
import "package:photos/ui/collections/album/row_item.dart";
import 'package:photos/ui/collections/collection_list_page.dart';
import "package:photos/ui/tabs/section_title.dart";
import 'package:photos/ui/viewer/actions/album_selection_overlay_bar.dart';
import 'package:photos/ui/viewer/actions/file_selection_overlay_bar.dart';
import "package:photos/ui/viewer/actions/smart_albums_status_widget.dart";
import "package:photos/ui/viewer/gallery/collect_photos_bottom_buttons.dart";
import "package:photos/ui/viewer/gallery/empty_album_state.dart";
import 'package:photos/ui/viewer/gallery/empty_state.dart';
import 'package:photos/ui/viewer/gallery/gallery.dart';
import "package:photos/ui/viewer/gallery/gallery_app_bar_widget.dart";
import "package:photos/ui/viewer/gallery/hierarchical_search_gallery.dart";
import "package:photos/ui/viewer/gallery/state/gallery_files_inherited_widget.dart";
import "package:photos/ui/viewer/gallery/state/inherited_search_filter_data.dart";
import "package:photos/ui/viewer/gallery/state/search_filter_data_provider.dart";
import "package:photos/ui/viewer/gallery/state/selection_state.dart";
import "package:photos/utils/navigation_util.dart";

class CollectionPage extends StatefulWidget {
  final CollectionWithThumbnail c;
  final String tagPrefix;
  final bool? hasVerifiedLock;
  final bool isFromCollectPhotos;

  const CollectionPage(
    this.c, {
    this.tagPrefix = "collection",
    this.hasVerifiedLock = false,
    this.isFromCollectPhotos = false,
    super.key,
  });

  @override
  State<CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<CollectionPage> {
  final _logger = Logger("CollectionPage");
  final _selectedFiles = SelectedFiles();
  final _selectedAlbums = SelectedAlbums();
  bool _isAlbumSelectionActive = false;
  bool _isFileSelectionActive = false;
  StreamSubscription<NestedCollectionsSettingChangedEvent>?
      _nestedSettingSubscription;
  Future<List<Collection>>? _subAlbumsFuture;

  @override
  void initState() {
    super.initState();
    _selectedFiles.addListener(_onFileSelectionChanged);
    _selectedAlbums.addListener(_onAlbumSelectionChanged);
    _nestedSettingSubscription =
        Bus.instance.on<NestedCollectionsSettingChangedEvent>().listen((event) {
      if (mounted) {
        setState(() {
          // Rebuild to show/hide sub-albums based on new setting
          _subAlbumsFuture = null; // Reset to force refresh
        });
      }
    });
    // Initialize sub-albums future
    _subAlbumsFuture = _getSubAlbums();
  }

  @override
  void dispose() {
    _selectedFiles.removeListener(_onFileSelectionChanged);
    _selectedAlbums.removeListener(_onAlbumSelectionChanged);
    _nestedSettingSubscription?.cancel();
    super.dispose();
  }

  void _onFileSelectionChanged() {
    if (!mounted) return;
    
    final hasFileSelection = _selectedFiles.files.isNotEmpty;
    
    // Clear album selection if file selection is active
    if (hasFileSelection && _isAlbumSelectionActive) {
      _selectedAlbums.clearAll();
      _isAlbumSelectionActive = false;
    }
    
    // Update file selection state
    if (_isFileSelectionActive != hasFileSelection) {
      setState(() {
        _isFileSelectionActive = hasFileSelection;
      });
    }
  }

  void _onAlbumSelectionChanged() {
    if (!mounted) return;
    
    final hasAlbumSelection = _selectedAlbums.albums.isNotEmpty;
    
    // Clear file selection if album selection is active
    if (hasAlbumSelection && _isFileSelectionActive) {
      _selectedFiles.clearAll();
      _isFileSelectionActive = false;
    }
    
    // Update album selection state
    if (_isAlbumSelectionActive != hasAlbumSelection) {
      setState(() {
        _isAlbumSelectionActive = hasAlbumSelection;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hasVerifiedLock == false && widget.c.collection.isHidden()) {
      return const EmptyState();
    }

    final galleryType = getGalleryType(
      widget.c.collection,
      Configuration.instance.getUserID()!,
    );
    final List<EnteFile>? initialFiles =
        widget.c.thumbnail != null ? [widget.c.thumbnail!] : null;
    // Build sub-albums header if needed
    Widget? galleryHeader;
    final bool localEnabled = localSettings.isNestedViewEnabled ?? false;
    final bool serverEnabled = flagService.isNestedAlbumsEnabled;
    final bool showHierarchy = localEnabled && serverEnabled;
    
    if (showHierarchy) {
      _subAlbumsFuture ??= _getSubAlbums();
      galleryHeader = FutureBuilder<List<Collection>>(
        future: _subAlbumsFuture,
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data!.isNotEmpty) {
            return _buildCompactSubAlbumsGrid(snapshot.data!);
          }
          return const SizedBox.shrink();
        },
      );
    }

    final gallery = Gallery(
      key: ValueKey('gallery_${widget.c.collection.id}'), // Stable key to prevent rebuilds
      asyncLoader: (creationStartTime, creationEndTime, {limit, asc}) async {
        final FileLoadResult result =
            await FilesDB.instance.getFilesInCollection(
          widget.c.collection.id,
          creationStartTime,
          creationEndTime,
          limit: limit,
          asc: asc,
        );
        // hide ignored files from home page UI
        final ignoredIDs =
            await IgnoredFilesService.instance.idToIgnoreReasonMap;
        result.files.removeWhere(
          (f) =>
              f.uploadedFileID == null &&
              IgnoredFilesService.instance.shouldSkipUpload(ignoredIDs, f),
        );
        return result;
      },
      reloadEvent: Bus.instance
          .on<CollectionUpdatedEvent>()
          .where((event) => event.collectionID == widget.c.collection.id),
      forceReloadEvents: [
        Bus.instance.on<CollectionMetaEvent>().where(
              (event) =>
                  event.id == widget.c.collection.id &&
                  event.type == CollectionMetaEventType.sortChanged,
            ),
      ],
      removalEventTypes: const {
        EventType.deletedFromRemote,
        EventType.deletedFromEverywhere,
        EventType.hide,
      },
      tagPrefix: widget.tagPrefix,
      selectedFiles: _selectedFiles,
      initialFiles: initialFiles,
      albumName: widget.c.collection.displayName,
      sortAsyncFn: () => widget.c.collection.pubMagicMetadata.asc ?? false,
      addHeaderOrFooterEmptyState: false,
      showSelectAll: galleryType != GalleryType.sharedCollection,
      header: galleryHeader,
      emptyState: galleryType == GalleryType.ownedCollection
          ? EmptyAlbumState(
              widget.c.collection,
              isFromCollectPhotos: widget.isFromCollectPhotos,
              onAddPhotos: () {
                Bus.instance.fire(
                  CollectionMetaEvent(
                    widget.c.collection.id,
                    CollectionMetaEventType.autoAddPeople,
                  ),
                );
              },
            )
          : const EmptyState(),
      footer: widget.isFromCollectPhotos
          ? const SizedBox(height: 20)
          : const SizedBox(height: 212),
    );

    return GalleryFilesState(
      child: InheritedSearchFilterDataWrapper(
        searchFilterDataProvider: SearchFilterDataProvider(
          initialGalleryFilter: AlbumFilter(
            collectionID: widget.c.collection.id,
            albumName: widget.c.collection.displayName,
            occurrence: kMostRelevantFilter,
          ),
        ),
        child: Scaffold(
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(90.0),
            child: GalleryAppBarWidget(
              galleryType,
              widget.c.collection.displayName,
              _selectedFiles,
              collection: widget.c.collection,
              isFromCollectPhotos: widget.isFromCollectPhotos,
            ),
          ),
          bottomNavigationBar: widget.isFromCollectPhotos
              ? CollectPhotosBottomButtons(
                  widget.c.collection,
                  selectedFiles: _selectedFiles,
                )
              : null,
          body: SelectionState(
            selectedFiles: _selectedFiles,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                Builder(
                  builder: (context) {
                    return ValueListenableBuilder(
                      valueListenable: InheritedSearchFilterData.of(context)
                          .searchFilterDataProvider!
                          .isSearchingNotifier,
                      builder: (context, value, _) {
                        return value
                            ? HierarchicalSearchGallery(
                                tagPrefix: widget.tagPrefix,
                                selectedFiles: _selectedFiles,
                              )
                            : gallery;
                      },
                    );
                  },
                ),
                SmartAlbumsStatusWidget(
                  collection: widget.c.collection,
                ),
                if (_isFileSelectionActive)
                  FileSelectionOverlayBar(
                    galleryType,
                    _selectedFiles,
                    collection: widget.c.collection,
                  ),
                if (_isAlbumSelectionActive)
                  FutureBuilder<List<Collection>>(
                    future: _getSubAlbums(),
                    builder: (context, snapshot) {
                      return AlbumSelectionOverlayBar(
                        _selectedAlbums,
                        UISectionType.homeCollections,
                        snapshot.data ?? [],
                        showSelectAllButton: false,
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }


  Widget _buildCompactSubAlbumsGrid(List<Collection> subAlbums) {
    // More compact version for inline display as part of gallery scroll
    const int maxItemsToShow = 6;
    final hasMoreAlbums = subAlbums.length > maxItemsToShow;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Section heading - matches gallery date headers style
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: GestureDetector(
            onTap: () => _navigateToAllSubAlbums(subAlbums),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Albums in ${widget.c.collection.displayName}',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).textTheme.bodyLarge?.color?.withOpacity(0.8),
                      ),
                ),
                if (hasMoreAlbums)
                  Icon(
                    Icons.arrow_forward_ios,
                    color: Theme.of(context).textTheme.bodyLarge?.color?.withOpacity(0.5),
                    size: 16,
                  ),
              ],
            ),
          ),
        ),

        // Albums grid
        Padding(
          padding: const EdgeInsets.only(left: 8, right: 8, bottom: 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final screenWidth = constraints.maxWidth;
              const double maxThumbnailWidth = 224.0;
              const double crossAxisSpacing = 8.0;
              const double horizontalPadding = 16.0;

              final int albumsCountInCrossAxis =
                  math.max((screenWidth / maxThumbnailWidth).floor(), 3);
              final double totalCrossAxisSpacing =
                  crossAxisSpacing * (albumsCountInCrossAxis - 1);
              final double sideOfThumbnail =
                  (screenWidth - totalCrossAxisSpacing - horizontalPadding) /
                      albumsCountInCrossAxis;

              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: albumsCountInCrossAxis,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: crossAxisSpacing,
                  childAspectRatio: sideOfThumbnail /
                      (sideOfThumbnail + 46), // +46 for text space
                ),
                itemCount: subAlbums.take(maxItemsToShow).length,
                itemBuilder: (context, index) {
                  final collection = subAlbums[index];
                  return AlbumRowItemWidget(
                    collection,
                    sideOfThumbnail,
                    showFileCount: true,
                    tag: "${widget.tagPrefix}_subalbum",
                    hasVerifiedLock: widget.hasVerifiedLock,
                    selectedAlbums: _selectedAlbums,
                    onTapCallback: (c) {
                      // If albums are being selected, toggle selection on tap
                      if (_isAlbumSelectionActive) {
                        _selectedAlbums.toggleSelection(c);
                      } else {
                        _navigateToSubAlbum(c);
                      }
                    },
                    onLongPressCallback: (c) =>
                        _selectedAlbums.toggleSelection(c),
                  );
                },
              );
            },
          ),
        ),
        
        // Show count if there are more albums
        if (hasMoreAlbums)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '${subAlbums.length} albums total • Tap to see all',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).textTheme.bodySmall?.color?.withOpacity(0.6),
                  ),
            ),
          ),
        
        // Subtle divider to separate from photos
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          height: 0.5,
          color: Theme.of(context).dividerColor.withOpacity(0.2),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  Future<List<Collection>> _getSubAlbums() async {
    try {
      final allCollections = CollectionsService.instance.getActiveCollections();
      final subAlbums = allCollections
          .where((collection) => collection.parentID == widget.c.collection.id)
          .toList()
        ..sort((a, b) => a.displayName.compareTo(b.displayName));

      // Debug: Log found subalbums
      _logger.info(
        'Found ${subAlbums.length} subalbums for ${widget.c.collection.displayName}',
      );
      if (subAlbums.isNotEmpty) {
        _logger.info('Sub-albums will be shown even if parent album is empty');
        for (final album in subAlbums) {
          _logger
              .fine('  - ${album.displayName} (parentID: ${album.parentID})');
        }
      }

      return subAlbums;
    } catch (e) {
      _logger.warning('Error getting subalbums', e);
      return [];
    }
  }


  void _navigateToSubAlbum(Collection collection) async {
    final thumbnail = await CollectionsService.instance.getCover(collection);
    await routeToPage(
      context,
      CollectionPage(
        CollectionWithThumbnail(collection, thumbnail),
        tagPrefix: widget.tagPrefix,
        hasVerifiedLock: widget.hasVerifiedLock,
      ),
    );
  }

  void _navigateToAllSubAlbums(List<Collection> subAlbums) async {
    // Debug: Log navigation data
    _logger.info('Navigating to all subalbums. Count: ${subAlbums.length}');
    for (final album in subAlbums) {
      _logger.info('  - Subalbum: ${album.displayName} (id: ${album.id})');
    }

    // Navigate to CollectionListPage showing only the subalbums (like "On ente" does)
    await routeToPage(
      context,
      CollectionListPage(
        subAlbums,
        sectionType: UISectionType.homeCollections,
        appTitle: SectionTitle(
          title: '${widget.c.collection.displayName} Albums',
        ),
        disableHierarchicalFiltering:
            true, // Don't filter subalbums as root albums
      ),
    );
  }
}
