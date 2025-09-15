import type { Collection } from "ente-media/collection";
import type { EnteFile } from "ente-media/file";
import type { CollectionSummary } from "./collection-summary";
import { getDisplayCollections } from "./collection-hierarchy";

/**
 * Convert a Collection to a CollectionSummary for compatibility with existing UI components.
 * 
 * @param collection - The Collection to convert
 * @param files - Files in the collection for metadata calculation
 * @returns CollectionSummary compatible with existing components
 */
export const collectionToSummary = (
    collection: Collection,
    files: EnteFile[] = []
): CollectionSummary => {
    const latestFile = files.length > 0 
        ? files.reduce((latest, file) => 
            file.metadata.creationTime > latest.metadata.creationTime ? file : latest
          )
        : undefined;

    // Create basic attributes set
    const attributes = new Set<string>();
    
    // Add type-based attributes
    if (collection.type === "favorites") {
        attributes.add("system");
    }
    if (collection.type === "uncategorized") {
        attributes.add("system");
    }
    
    // Add sharing attributes
    if (collection.sharees.length > 0) {
        attributes.add("shared");
        attributes.add("sharedOutgoing");
    }

    // Add visibility attributes from magic metadata
    const visibility = collection.magicMetadata?.data.visibility;
    if (visibility === "archived") {
        attributes.add("archived");
    }
    if (visibility === "hidden") {
        attributes.add("hideFromCollectionBar");
    }

    return {
        id: collection.id,
        type: collection.type as any,
        attributes: attributes as any,
        name: collection.name,
        latestFile: latestFile,
        coverFile: latestFile, // Use latest as cover for now
        fileCount: files.length,
        updationTime: collection.updationTime,
        sortPriority: collection.type === "favorites" ? 8 : 0,
        order: collection.magicMetadata?.data.order,
    };
};

/**
 * Convert Collections to CollectionSummaries with hierarchy filtering applied.
 * 
 * @param collections - All collections
 * @param collectionFiles - Map of collection ID to files
 * @returns CollectionSummaries with hierarchy filtering applied
 */
export const collectionsToSummariesWithHierarchy = (
    collections: Collection[],
    collectionFiles: Map<number, EnteFile[]>
): Map<number, CollectionSummary> => {
    // Apply hierarchy filtering to get display collections
    const displayCollections = getDisplayCollections(collections);
    
    const summaries = new Map<number, CollectionSummary>();
    
    displayCollections.forEach(collection => {
        const files = collectionFiles.get(collection.id) || [];
        const summary = collectionToSummary(collection, files);
        summaries.set(collection.id, summary);
    });
    
    return summaries;
};

/**
 * Convert a CollectionSummary back to a Collection (partial conversion for compatibility).
 * Note: This creates a minimal Collection object for use with hierarchy components.
 * 
 * @param summary - The CollectionSummary to convert
 * @returns Partial Collection with hierarchy support
 */
export const summaryToCollection = (summary: CollectionSummary): Collection => {
    return {
        id: summary.id,
        name: summary.name,
        type: summary.type,
        owner: { id: 0, name: "", email: "" }, // Minimal owner
        key: "", // Empty key for UI-only usage
        sharees: [],
        publicURLs: [],
        updationTime: summary.updationTime || Date.now() * 1000,
        parentID: undefined, // This needs to be populated from actual data
        hierarchyPath: undefined,
        // Magic metadata would need to be reconstructed if needed
    };
};

/**
 * Get the hierarchy-aware file count including descendant collections.
 * This is used to show total counts in hierarchical views.
 * 
 * @param collection - The collection to get count for
 * @param allCollections - All collections for hierarchy traversal
 * @param collectionFiles - Map of collection ID to files
 * @returns Total file count including descendants
 */
export const getHierarchicalFileCount = (
    collection: Collection,
    allCollections: Collection[],
    collectionFiles: Map<number, EnteFile[]>
): number => {
    let totalCount = collectionFiles.get(collection.id)?.length || 0;
    
    // Add files from all descendant collections
    const descendants = allCollections.filter(c => {
        if (!c.hierarchyPath) return false;
        return c.hierarchyPath.startsWith(`${collection.hierarchyPath || collection.id}/`);
    });
    
    descendants.forEach(descendant => {
        totalCount += collectionFiles.get(descendant.id)?.length || 0;
    });
    
    return totalCount;
};