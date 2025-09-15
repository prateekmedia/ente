import type { Collection } from "ente-media/collection";
import { getCollectionParentID } from "ente-media/collection";
import { createAlbum, updateCollectionHierarchy } from "./collection";
import { wouldCreateCycle } from "./collection-hierarchy";

/**
 * Create a new sub-album within a parent album.
 * 
 * @param parentCollection - The parent collection
 * @param albumName - Name for the new sub-album
 * @returns Promise resolving to the new sub-album
 */
export const createSubAlbum = async (
    parentCollection: Collection,
    albumName: string,
    allCollections: Collection[]
): Promise<Collection> => {
    // Create the album first
    const newAlbum = await createAlbum(albumName);
    
    // Then move it to be a child of the parent
    await moveAlbumToParent(newAlbum.id, parentCollection.id, allCollections);
    
    // Return the album with updated hierarchy in public magic metadata
    // Note: In practice, the caller should refetch collections to get the updated metadata
    return {
        ...newAlbum,
        pubMagicMetadata: {
            ...newAlbum.pubMagicMetadata,
            data: {
                ...newAlbum.pubMagicMetadata?.data,
                parentID: parentCollection.id,
                hierarchyPath: `${parentCollection.id}/${newAlbum.id}`,
            },
        },
    };
};

/**
 * Move an album to a new parent (or to root level).
 * 
 * @param albumID - ID of the album to move
 * @param newParentID - ID of the new parent album (undefined for root level)
 * @param allCollections - All collections to check for cycles (optional)
 * @returns Promise that resolves when the move is complete
 */
export const moveAlbumToParent = async (
    albumID: number,
    newParentID: number | undefined,
    allCollections: Collection[]
): Promise<void> => {
    // Check for cycles and find the album
    const album = allCollections.find(c => c.id === albumID);
    if (!album) {
        throw new Error(`Album with ID ${albumID} not found`);
    }
    
    const newParent = newParentID ? allCollections.find(c => c.id === newParentID) : undefined;
    
    if (wouldCreateCycle(album, newParent, allCollections)) {
        throw new Error("Moving album would create a cycle in the hierarchy");
    }
    
    // Calculate hierarchy path if needed
    const hierarchyPath = newParentID 
        ? `${newParentID}/${albumID}`
        : undefined;
        
    // Update the collection's hierarchy metadata
    await updateCollectionHierarchy(album, newParentID, hierarchyPath);
};

/**
 * Check if an album can be moved to a specific parent.
 * 
 * @param album - The album to move
 * @param targetParent - The target parent (undefined for root level)
 * @param allCollections - All available collections
 * @returns true if the move is valid
 */
export const canMoveAlbum = (
    album: Collection,
    targetParent?: Collection,
    allCollections?: Collection[]
): boolean => {
    // Can't move to itself
    if (targetParent && album.id === targetParent.id) {
        return false;
    }
    
    // Check for cycle prevention if collections are provided
    if (allCollections) {
        return !wouldCreateCycle(album, targetParent, allCollections);
    }
    
    return true;
};

/**
 * Get collections that can serve as valid parents for a given collection.
 * 
 * @param collection - The collection to find valid parents for
 * @param allCollections - All available collections
 * @returns Array of collections that can be parents
 */
export const getValidParentCollections = (
    collection: Collection,
    allCollections: Collection[]
): Collection[] => {
    return allCollections.filter(potentialParent => 
        canMoveAlbum(collection, potentialParent, allCollections)
    );
};

/**
 * Check if a collection can have sub-albums created within it.
 * 
 * @param collection - The collection to check
 * @returns true if sub-albums can be created
 */
export const canCreateSubAlbums = (collection: Collection): boolean => {
    // System collections typically shouldn't have sub-albums
    const systemTypes = ['favorites', 'uncategorized'];
    return !systemTypes.includes(collection.type);
};

/**
 * Estimate the new hierarchy path for a collection after moving.
 * This is used for optimistic UI updates.
 * 
 * @param collection - The collection being moved
 * @param newParent - The new parent (undefined for root level)
 * @param allCollections - All available collections
 * @returns Estimated new hierarchy path
 */
export const estimateNewHierarchyPath = (
    collection: Collection,
    newParent?: Collection,
    allCollections?: Collection[]
): string | undefined => {
    if (!newParent) {
        // Moving to root level
        return undefined;
    }
    
    if (!allCollections) {
        // Can't estimate without all collections
        return undefined;
    }
    
    // Simple path estimation: parent_path + "/" + collection_id
    const parentPath = newParent.hierarchyPath || newParent.id.toString();
    return `${parentPath}/${collection.id}`;
};

/**
 * Batch move multiple albums to a new parent.
 * 
 * @param albumIDs - Array of album IDs to move
 * @param newParentID - ID of the new parent (undefined for root level)
 * @param allCollections - All collections to validate moves
 * @returns Promise that resolves when all moves are complete
 */
export const batchMoveAlbums = async (
    albumIDs: number[],
    newParentID: number | undefined,
    allCollections: Collection[]
): Promise<void> => {
    // Validate all moves first
    const newParent = newParentID ? allCollections.find(c => c.id === newParentID) : undefined;
    
    for (const albumID of albumIDs) {
        const album = allCollections.find(c => c.id === albumID);
        if (album && !canMoveAlbum(album, newParent, allCollections)) {
            throw new Error(`Cannot move album "${album.name}" to the specified parent`);
        }
    }
    
    // Perform all moves
    await Promise.all(
        albumIDs.map(albumID => moveAlbumToParent(albumID, newParentID, allCollections))
    );
};