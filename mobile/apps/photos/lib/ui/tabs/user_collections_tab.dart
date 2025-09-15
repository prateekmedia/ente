import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import "package:photos/core/configuration.dart";
import 'package:photos/core/event_bus.dart';
import "package:photos/events/album_sort_order_change_event.dart";
import 'package:photos/events/collection_updated_event.dart';
import "package:photos/events/favorites_service_init_complete_event.dart";
import 'package:photos/events/local_photos_updated_event.dart';
import "package:photos/events/nested_collections_setting_event.dart";
import 'package:photos/events/user_logged_out_event.dart';
import "package:photos/generated/l10n.dart";
import 'package:photos/models/collection/collection.dart';
import "package:photos/models/selected_albums.dart";
import "package:photos/service_locator.dart";
import 'package:photos/services/collections_service.dart';
import "package:photos/services/feature_flags_service.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/collections/button/archived_button.dart";
import "package:photos/ui/collections/button/hidden_button.dart";
import "package:photos/ui/collections/button/trash_button.dart";
import "package:photos/ui/collections/button/uncategorized_button.dart";
import "package:photos/ui/collections/collection_list_page.dart";
import "package:photos/ui/collections/device/device_folders_grid_view.dart";
import "package:photos/ui/collections/device/device_folders_vertical_grid_view.dart";
import "package:photos/ui/collections/flex_grid_view.dart";
import 'package:photos/ui/common/loading_widget.dart';
import 'package:photos/ui/components/buttons/icon_button_widget.dart';
import "package:photos/ui/tabs/section_title.dart";
import "package:photos/ui/viewer/actions/album_selection_overlay_bar.dart";
import "package:photos/ui/viewer/actions/delete_empty_albums.dart";
import "package:photos/ui/viewer/gallery/empty_state.dart";
import "package:photos/utils/navigation_util.dart";
import "package:photos/utils/standalone/debouncer.dart";

class UserCollectionsTab extends StatefulWidget {
  const UserCollectionsTab({super.key, this.selectedAlbums});

  final SelectedAlbums? selectedAlbums;

  @override
  State<UserCollectionsTab> createState() => _UserCollectionsTabState();
}

class _UserCollectionsTabState extends State<UserCollectionsTab>
    with AutomaticKeepAliveClientMixin {
  final _logger = Logger((_UserCollectionsTabState).toString());
  late StreamSubscription<LocalPhotosUpdatedEvent> _localFilesSubscription;
  late StreamSubscription<CollectionUpdatedEvent>
      _collectionUpdatesSubscription;
  late StreamSubscription<UserLoggedOutEvent> _loggedOutEvent;
  late StreamSubscription<FavoritesServiceInitCompleteEvent>
      _favoritesServiceInitCompleteEvent;
  late StreamSubscription<AlbumSortOrderChangeEvent> _albumSortOrderChangeEvent;
  late StreamSubscription<NestedCollectionsSettingChangedEvent>
      _nestedSettingSubscription;

  String _loadReason = "init";
  final _scrollController = ScrollController();
  final _debouncer = Debouncer(
    const Duration(seconds: 2),
    executionInterval: const Duration(seconds: 5),
    leading: true,
  );

  static const int _kOnEnteItemLimitCount = 12;
  @override
  void initState() {
    super.initState();
    _localFilesSubscription =
        Bus.instance.on<LocalPhotosUpdatedEvent>().listen((event) {
      _debouncer.run(() async {
        if (mounted) {
          _loadReason = event.reason;
          setState(() {});
        }
      });
    });
    _collectionUpdatesSubscription =
        Bus.instance.on<CollectionUpdatedEvent>().listen((event) {
      _debouncer.run(() async {
        if (mounted) {
          _loadReason = event.reason;
          setState(() {});
        }
      });
    });
    _loggedOutEvent = Bus.instance.on<UserLoggedOutEvent>().listen((event) {
      _loadReason = event.reason;
      setState(() {});
    });
    _favoritesServiceInitCompleteEvent =
        Bus.instance.on<FavoritesServiceInitCompleteEvent>().listen((event) {
      _debouncer.run(() async {
        _loadReason = event.reason;
        setState(() {});
      });
    });
    _albumSortOrderChangeEvent =
        Bus.instance.on<AlbumSortOrderChangeEvent>().listen((event) {
      _loadReason = event.reason;
      setState(() {});
    });
    _nestedSettingSubscription =
        Bus.instance.on<NestedCollectionsSettingChangedEvent>().listen((event) {
      _loadReason = "nested_setting_changed";
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    _logger.info("Building, trigger: $_loadReason");
    return FutureBuilder<List<Collection>>(
      future: CollectionsService.instance.getCollectionForOnEnteSection(),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return _getCollectionsGalleryWidget(snapshot.data!);
        } else if (snapshot.hasError) {
          return Text(snapshot.error.toString());
        } else {
          return const EnteLoadingWidget();
        }
      },
    );
  }

  Widget _getCollectionsGalleryWidget(List<Collection> collections) {
    final TextStyle trashAndHiddenTextStyle =
        Theme.of(context).textTheme.titleMedium!.copyWith(
              color: Theme.of(context)
                  .textTheme
                  .titleMedium!
                  .color!
                  .withValues(alpha: 0.5),
            );

    return Stack(
      alignment: Alignment.bottomCenter,
      children: [
        CustomScrollView(
          physics: const BouncingScrollPhysics(),
          controller: _scrollController,
          slivers: [
            SliverToBoxAdapter(
              child: SectionOptions(
                onTap: () {
                  unawaited(
                    routeToPage(
                      context,
                      DeviceFolderVerticalGridView(
                        appTitle: SectionTitle(
                          title: AppLocalizations.of(context).onDevice,
                        ),
                        tag: "OnDeviceAppTitle",
                      ),
                    ),
                  );
                },
                Hero(
                  tag: "OnDeviceAppTitle",
                  child: SectionTitle(
                    title: AppLocalizations.of(context).onDevice,
                  ),
                ),
                trailingWidget: IconButtonWidget(
                  icon: Icons.chevron_right,
                  iconButtonType: IconButtonType.secondary,
                  iconColor: getEnteColorScheme(context).blurStrokePressed,
                ),
              ),
            ),
            const SliverToBoxAdapter(child: DeviceFoldersGridView()),
            SliverToBoxAdapter(
              child: SectionOptions(
                onTap: () {
                  // Always navigate to CollectionListPage but let it handle hierarchical view internally
                  unawaited(
                    routeToPage(
                      context,
                      CollectionListPage(
                        collections,
                        sectionType: UISectionType.homeCollections,
                        appTitle: SectionTitle(
                          titleWithBrand: getOnEnteSection(context),
                        ),
                      ),
                    ),
                  );
                },
                SectionTitle(titleWithBrand: getOnEnteSection(context)),
                trailingWidget: IconButtonWidget(
                  icon: Icons.chevron_right,
                  iconButtonType: IconButtonType.secondary,
                  iconColor: getEnteColorScheme(context).blurStrokePressed,
                ),
              ),
            ),
            SliverToBoxAdapter(child: DeleteEmptyAlbums(collections)),
            Configuration.instance.hasConfiguredAccount()
                ? _getCollectionViewWidget(collections)
                : const SliverToBoxAdapter(child: EmptyState()),
            SliverToBoxAdapter(
              child: Divider(
                color: getEnteColorScheme(context).strokeFaint,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  children: [
                    UnCategorizedCollections(trashAndHiddenTextStyle),
                    const SizedBox(height: 12),
                    ArchivedCollectionsButton(trashAndHiddenTextStyle),
                    const SizedBox(height: 12),
                    HiddenCollectionsButtonWidget(trashAndHiddenTextStyle),
                    const SizedBox(height: 12),
                    TrashSectionButton(trashAndHiddenTextStyle),
                  ],
                ),
              ),
            ),
            // Debug info sliver moved to end
            SliverToBoxAdapter(
              child: Container(
                margin: const EdgeInsets.all(8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '🔧 DEBUG: Nested Collections Status',
                      style:
                          TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'Local enabled: ${localSettings.isNestedViewEnabled ?? false} | '
                      'Server enabled: ${FeatureFlagsService().isNestedCollectionsEnabled()} | '
                      'Using hierarchical: ${(localSettings.isNestedViewEnabled ?? false) && FeatureFlagsService().isNestedCollectionsEnabled()}',
                      style: const TextStyle(fontSize: 9),
                    ),
                    Text(
                      'Collections: ${collections.length} | With parents: ${collections.where((c) => c.parentID != null).length}',
                      style: const TextStyle(fontSize: 9),
                    ),
                    if (collections
                        .where((c) => c.parentID != null)
                        .isNotEmpty) ...[
                      Text(
                        'Parent-child pairs: ${collections.where((c) => c.parentID != null).map((c) => '${c.displayName}→${c.parentID}').take(2).join(', ')}',
                        style: const TextStyle(fontSize: 8),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () async {
                            try {
                              final service = FeatureFlagsService();
                              service.init();
                              await service.fetchFeatureFlags();
                              setState(() {});
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '🔧 Feature flags refreshed: ${service.getAllFlags()}',
                                  ),
                                ),
                              );
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('🔧 Error fetching flags: $e'),
                                ),
                              );
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.blue.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '🔄 FETCH FLAGS',
                              style: TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () async {
                            try {
                              // Call debug endpoint to see server feature flags
                              final dio = Dio();
                              dio.options.baseUrl =
                                  Configuration.instance.getHttpEndpoint();
                              final response = await dio.get('/debug/feature-flags');
                              final debugInfo = response.data;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('🔧 Feature flags: $debugInfo'),
                                  duration: const Duration(seconds: 10),
                                ),
                              );
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('🔧 Debug error: $e')),
                              );
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.purple.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '🔍 FLAGS',
                              style: TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () async {
                            await CollectionsService.instance.sync();
                            setState(() {});
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('🔧 Collections refreshed'),
                              ),
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '🔄 SYNC',
                              style: TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child:
                  SizedBox(height: 64 + MediaQuery.paddingOf(context).bottom),
            ),
          ],
        ),
        AlbumSelectionOverlayBar(
          widget.selectedAlbums!,
          UISectionType.homeCollections,
          collections,
          showSelectAllButton: false,
        ),
      ],
    );
  }

  Widget _getCollectionViewWidget(List<Collection> collections) {
    // Check if nested view is enabled for hierarchical display
    final bool showHierarchy = (localSettings.isNestedViewEnabled ?? false) &&
        FeatureFlagsService().isNestedCollectionsEnabled();

    // Filter collections based on hierarchy navigation
    final List<Collection> displayCollections = showHierarchy
        ? _getCollectionsForCurrentLevel(collections)
        : collections;

    // Always use the same UI component
    return CollectionsFlexiGridViewWidget(
      displayCollections,
      displayLimitCount: _kOnEnteItemLimitCount,
      selectedAlbums: widget.selectedAlbums,
      shrinkWrap: true,
      shouldShowCreateAlbum: true,
      enableSelectionMode: true,
    );
  }

  /// Get collections to display at current hierarchy level
  /// Only shows root collections or children of current parent
  List<Collection> _getCollectionsForCurrentLevel(
    List<Collection> collections,
  ) {
    // For now, just show root collections (parentID == null)
    // This can be enhanced later with navigation state tracking
    final rootCollections = collections
        .where((c) => c.parentID == null)
        .toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));

    return rootCollections;
  }

  @override
  void dispose() {
    _localFilesSubscription.cancel();
    _collectionUpdatesSubscription.cancel();
    _loggedOutEvent.cancel();
    _favoritesServiceInitCompleteEvent.cancel();
    _scrollController.dispose();
    _debouncer.cancelDebounceTimer();
    _albumSortOrderChangeEvent.cancel();
    _nestedSettingSubscription.cancel();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;
}
