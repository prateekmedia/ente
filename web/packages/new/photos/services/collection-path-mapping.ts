/**
 * @file Service for managing path-to-collection-ID mappings for nested folder watch.
 *
 * When using the "nested" collection mapping mode, we need to track which
 * relative folder paths correspond to which collection IDs. This service
 * provides an in-memory map for this purpose.
 *
 * The mapping uses a "first-seen wins" conflict resolution strategy - if a path
 * is already mapped to a collection ID, subsequent attempts to map the same path
 * to a different ID are ignored.
 */

/**
 * Internal state for path-to-collection-ID mapping.
 *
 * The key is a relative folder path (e.g., "A/B"), and the value is the
 * collection ID for that path.
 */
class PathMappingState {
    /**
     * Map of relative folder paths to collection IDs.
     *
     * Example: 'A/B' -> collectionId
     */
    pathToCollectionId = new Map<string, number>();
}

/** State shared by the functions in this module. */
let _state = new PathMappingState();

/**
 * Update the path-to-collection-ID mapping.
 *
 * This function uses a "first-seen wins" strategy - if a path is already
 * mapped, the new mapping is ignored.
 *
 * @param path The relative folder path (e.g., "A/B").
 * @param collectionId The collection ID associated with this path.
 */
export const updatePathMapping = (path: string, collectionId: number): void => {
    if (!_state.pathToCollectionId.has(path)) {
        _state.pathToCollectionId.set(path, collectionId);
    }
};

/**
 * Get the collection ID for a given path.
 *
 * @param path The relative folder path to look up.
 * @returns The collection ID if found, undefined otherwise.
 */
export const getCollectionIdForPath = (path: string): number | undefined => {
    return _state.pathToCollectionId.get(path);
};

/**
 * Clear all path-to-collection-ID mappings.
 *
 * This should be called when starting a new upload session or when the user
 * logs out.
 */
export const clearPathMapping = (): void => {
    _state = new PathMappingState();
};
