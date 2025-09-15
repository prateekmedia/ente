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
import 'package:photos/services/feature_flags_service.dart';
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
        });
      }
    });
  }

  @override
  void dispose() {
    _selectedFiles.removeListener(_onFileSelectionChanged);
    _selectedAlbums.removeListener(_onAlbumSelectionChanged);
    _nestedSettingSubscription?.cancel();
    super.dispose();
  }

  void _onFileSelectionChanged() {
    final hasFileSelection = _selectedFiles.files.isNotEmpty;
    if (hasFileSelection && _isAlbumSelectionActive) {
      _selectedAlbums.clearAll();
      _isAlbumSelectionActive = false;
    }
    _isFileSelectionActive = hasFileSelection;
    setState(() {
      // Force rebuild to show/hide overlay immediately
    });
  }

  void _onAlbumSelectionChanged() {
    final hasAlbumSelection = _selectedAlbums.albums.isNotEmpty;
    if (hasAlbumSelection && _isFileSelectionActive) {
      _selectedFiles.clearAll();
      _isFileSelectionActive = false;
    }
    _isAlbumSelectionActive = hasAlbumSelection;
    setState(() {
      // Force rebuild to show/hide overlay immediately
    });
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
    final gallery = Gallery(
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
                            : _buildGalleryWithSubAlbums(gallery);
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
                  AlbumSelectionOverlayBar(
                    _selectedAlbums,
                    UISectionType.homeCollections,
                    const [], // We need to provide sub-albums here, but for now empty is fine
                    showSelectAllButton: false,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGalleryWithSubAlbums(Widget gallery) {
    // Check if nested collections are enabled
    final bool localEnabled = localSettings.isNestedViewEnabled ?? false;
    final bool serverEnabled =
        FeatureFlagsService().isNestedCollectionsEnabled();
    final bool showHierarchy = localEnabled && serverEnabled;

    if (!showHierarchy) {
      return gallery; // Just show photos if hierarchy is disabled
    }

    return FutureBuilder<List<Collection>>(
      future: _getSubAlbums(),
      builder: (context, snapshot) {
        if (snapshot.hasError ||
            snapshot.connectionState == ConnectionState.waiting) {
          return gallery;
        }

        final subAlbums = snapshot.data ?? [];

        if (subAlbums.isEmpty) {
          return gallery;
        }

        // Always show sub-albums section, even if the main album is empty
        return _buildGalleryWithSubAlbumsHeader(subAlbums, gallery);
      },
    );
  }

  Widget _buildGalleryWithSubAlbumsHeader(List<Collection> subAlbums, Widget originalGallery) {
    // Create the sub-albums header widget
    final subAlbumsHeader = _buildSubAlbumsGrid(subAlbums);

    // Create a custom scrollable layout that always shows sub-albums at the top
    return CustomScrollView(
      slivers: [
        // Sub-albums section always at top
        SliverToBoxAdapter(
          child: subAlbumsHeader,
        ),
        // Original gallery content below (photos or empty state)
        SliverFillRemaining(
          child: originalGallery,
        ),
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
      _logger.info('Found ${subAlbums.length} subalbums for ${widget.c.collection.displayName}');
      if (subAlbums.isNotEmpty) {
        _logger.info('Sub-albums will be shown even if parent album is empty');
        for (final album in subAlbums) {
          _logger.fine('  - ${album.displayName} (parentID: ${album.parentID})');
        }
      }

      return subAlbums;
    } catch (e) {
      _logger.warning('Error getting subalbums', e);
      return [];
    }
  }

  Widget _buildSubAlbumsGrid(List<Collection> subAlbums) {
    // Limit display to match "On Ente" section (max 2 rows)
    const int maxItemsToShow = 6; // 2 rows typically
    final hasMoreAlbums = subAlbums.length > maxItemsToShow;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Albums heading with navigation (exactly like "On Ente" section)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: GestureDetector(
            onTap: () => _navigateToAllSubAlbums(subAlbums),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'On ${widget.c.collection.displayName}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                if (hasMoreAlbums)
                  const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
              ],
            ),
          ),
        ),

        // Use exact same grid as "On Ente" section  
        Padding(
          padding: const EdgeInsets.only(
            top: 4,
            left: 8,
            right: 8,
            bottom: 4,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final screenWidth = constraints.maxWidth;
              const double maxThumbnailWidth = 224.0;
              const double crossAxisSpacing = 8.0;
              const double horizontalPadding = 16.0;
              
              final int albumsCountInCrossAxis = math.max((screenWidth / maxThumbnailWidth).floor(), 3);
              final double totalCrossAxisSpacing = crossAxisSpacing * (albumsCountInCrossAxis - 1);
              final double sideOfThumbnail = (screenWidth - totalCrossAxisSpacing - horizontalPadding) / albumsCountInCrossAxis;
              
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: albumsCountInCrossAxis,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: crossAxisSpacing,
                  childAspectRatio: sideOfThumbnail / (sideOfThumbnail + 46), // +46 for text space
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
                    onTapCallback: (c) => _navigateToSubAlbum(c),
                    onLongPressCallback: (c) => _selectedAlbums.toggleSelection(c),
                  );
                },
              );
            },
          ),
        ),

        // Show count indicator if there are more albums
        if (hasMoreAlbums)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              '${subAlbums.length} albums total',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
            ),
          ),

        // Bottom spacing
        const SizedBox(height: 8),
      ],
    );
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
        disableHierarchicalFiltering: true, // Don't filter subalbums as root albums
      ),
    );
  }

}
