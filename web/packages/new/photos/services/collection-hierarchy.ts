import type { Collection } from "ente-media/collection";
import { getCollectionParentID } from "ente-media/collection";
import { isNestedAlbumsEnabled } from "./feature-flags";

/**
 * A collection node in a hierarchical tree structure.
 */
export interface CollectionNode {
    /** The collection itself */
    collection: Collection;
    /** Child collection nodes */
    children: CollectionNode[];
    /** Parent collection node (undefined for root nodes) */
    parent?: CollectionNode;
    /** Depth in the tree (0 for root nodes) */
    depth: number;
    /** Whether this node is expanded in the UI */
    isExpanded?: boolean;
}

/**
 * Build a hierarchical tree structure from a flat array of collections.
 * 
 * @param collections - Flat array of collections to organize into hierarchy
 * @returns Array of root-level collection nodes
 */
export const buildCollectionHierarchy = (collections: Collection[]): CollectionNode[] => {
    if (!collections.length) return [];
    
    // Create a map for efficient lookups
    const collectionMap = new Map<number, Collection>();
    const nodeMap = new Map<number, CollectionNode>();
    
    // First pass: create all nodes
    collections.forEach(collection => {
        collectionMap.set(collection.id, collection);
        nodeMap.set(collection.id, {
            collection,
            children: [],
            depth: 0,
            isExpanded: false,
        });
    });
    
    const rootNodes: CollectionNode[] = [];
    
    // Second pass: build relationships
    collections.forEach(collection => {
        const node = nodeMap.get(collection.id)!;
        const parentID = getCollectionParentID(collection);
        
        if (parentID) {
            // This is a child node
            const parentNode = nodeMap.get(parentID);
            if (parentNode) {
                parentNode.children.push(node);
                node.parent = parentNode;
                node.depth = parentNode.depth + 1;
            } else {
                // Parent not found, treat as root
                rootNodes.push(node);
            }
        } else {
            // This is a root node
            rootNodes.push(node);
        }
    });
    
    // Sort children at each level alphabetically
    const sortChildren = (nodes: CollectionNode[]) => {
        nodes.sort((a, b) => a.collection.name.localeCompare(b.collection.name));
        nodes.forEach(node => sortChildren(node.children));
    };
    
    sortChildren(rootNodes);
    return rootNodes;
};

/**
 * Filter collections to show only root-level collections when hierarchy is enabled.
 * 
 * @param collections - All collections
 * @returns Root-level collections only if hierarchy is enabled, all collections otherwise
 */
export const getDisplayCollections = (collections: Collection[]): Collection[] => {
    if (!isNestedAlbumsEnabled()) {
        return collections;
    }
    
    // Return only root-level collections (those without a parentID)
    return collections.filter(collection => !getCollectionParentID(collection));
};

/**
 * Get all descendant collections of a given collection.
 * 
 * @param parentCollection - The parent collection
 * @param allCollections - All available collections
 * @returns Array of descendant collections
 */
export const getDescendantCollections = (
    parentCollection: Collection,
    allCollections: Collection[]
): Collection[] => {
    const descendants: Collection[] = [];
    const queue = [parentCollection.id];
    
    while (queue.length > 0) {
        const currentId = queue.shift()!;
        const children = allCollections.filter(c => getCollectionParentID(c) === currentId);
        
        children.forEach(child => {
            descendants.push(child);
            queue.push(child.id);
        });
    }
    
    return descendants;
};

/**
 * Get the path from root to a given collection.
 * 
 * @param collection - The target collection
 * @param allCollections - All available collections
 * @returns Array of collections representing the path from root to target
 */
export const getCollectionPath = (
    collection: Collection,
    allCollections: Collection[]
): Collection[] => {
    const path: Collection[] = [collection];
    let current = collection;
    
    let parentID = getCollectionParentID(current);
    while (parentID) {
        const parent = allCollections.find(c => c.id === parentID);
        if (parent) {
            path.unshift(parent);
            current = parent;
            parentID = getCollectionParentID(current);
        } else {
            break; // Parent not found
        }
    }
    
    return path;
};

/**
 * Check if one collection is an ancestor of another.
 * 
 * @param potentialAncestor - The collection that might be an ancestor
 * @param collection - The collection to check
 * @param allCollections - All available collections
 * @returns true if potentialAncestor is an ancestor of collection
 */
export const isAncestor = (
    potentialAncestor: Collection,
    collection: Collection,
    allCollections: Collection[]
): boolean => {
    if (potentialAncestor.id === collection.id) {
        return false; // A collection is not its own ancestor
    }
    
    let current = collection;
    let parentID = getCollectionParentID(current);
    while (parentID) {
        if (parentID === potentialAncestor.id) {
            return true;
        }
        const parent = allCollections.find(c => c.id === parentID);
        if (!parent) break;
        current = parent;
        parentID = getCollectionParentID(current);
    }
    
    return false;
};

/**
 * Check if moving a collection to a new parent would create a cycle.
 * 
 * @param collection - The collection to move
 * @param newParent - The potential new parent (undefined for root level)
 * @param allCollections - All available collections
 * @returns true if moving would create a cycle
 */
export const wouldCreateCycle = (
    collection: Collection,
    newParent: Collection | undefined,
    allCollections: Collection[]
): boolean => {
    if (!newParent) {
        return false; // Moving to root level never creates a cycle
    }
    
    if (collection.id === newParent.id) {
        return true; // Can't be its own parent
    }
    
    // Check if newParent is a descendant of collection
    return isAncestor(collection, newParent, allCollections);
};

/**
 * Find the root collection for a given collection.
 * 
 * @param collection - The collection to find the root for
 * @param allCollections - All available collections
 * @returns The root collection in the hierarchy
 */
export const findRootCollection = (
    collection: Collection,
    allCollections: Collection[]
): Collection => {
    let current = collection;
    let parentID = getCollectionParentID(current);
    
    while (parentID) {
        const parent = allCollections.find(c => c.id === parentID);
        if (parent) {
            current = parent;
            parentID = getCollectionParentID(current);
        } else {
            break; // Parent not found, current is effectively root
        }
    }
    
    return current;
};

/**
 * Calculate the total file count for a collection including all its descendants.
 * 
 * @param collection - The parent collection
 * @param allCollections - All available collections
 * @param getFileCount - Function to get file count for a collection
 * @returns Total file count including descendants
 */
export const calculateTotalFileCount = (
    collection: Collection,
    allCollections: Collection[],
    getFileCount: (collection: Collection) => number
): number => {
    let totalCount = getFileCount(collection);
    
    const descendants = getDescendantCollections(collection, allCollections);
    descendants.forEach(descendant => {
        totalCount += getFileCount(descendant);
    });
    
    return totalCount;
};