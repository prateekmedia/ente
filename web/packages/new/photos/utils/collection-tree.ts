/**
 * Utilities for building and working with hierarchical collection trees.
 *
 * This module provides functionality to build a tree structure from flat
 * collections using their parent-child relationships stored in pubMagicMetadata.
 */

import type { Collection } from "ente-media/collection";

/**
 * Represents a node in the collection tree hierarchy.
 */
export interface CollectionTreeNode {
    /** The collection at this node */
    collection: Collection;
    /** Child nodes in the tree */
    children: CollectionTreeNode[];
    /** Depth of this node in the tree (0 for root) */
    depth: number;
}

/**
 * Represents the complete collection tree structure.
 */
export interface CollectionTree {
    /** Root nodes (collections with no parent) */
    roots: CollectionTreeNode[];
    /** Map from collection ID to node for fast lookups */
    nodeMap: Map<number, CollectionTreeNode>;
}

/**
 * Builds a collection tree from a flat list of collections.
 *
 * @param collections - Flat array of all collections
 * @returns The built collection tree
 */
export function buildCollectionTree(
    collections: Collection[],
): CollectionTree {
    const nodeMap = new Map<number, CollectionTreeNode>();
    const roots: CollectionTreeNode[];

    // Create nodes for all collections
    for (const collection of collections) {
        nodeMap.set(collection.id, {
            collection,
            children: [],
            depth: 0,
        });
    }

    // Build parent-child relationships
    const rootNodes: CollectionTreeNode[] = [];
    for (const collection of collections) {
        const node = nodeMap.get(collection.id)!;
        const parentID = collection.pubMagicMetadata?.data.parentID;

        if (!parentID || parentID === 0) {
            rootNodes.push(node);
        } else {
            const parent = nodeMap.get(parentID);
            if (parent) {
                parent.children.push(node);
            } else {
                // Parent not found, treat as root
                rootNodes.push(node);
            }
        }
    }

    // Calculate depths
    function calculateDepth(node: CollectionTreeNode, depth: number): void {
        node.depth = depth;
        for (const child of node.children) {
            calculateDepth(child, depth + 1);
        }
    }

    for (const root of rootNodes) {
        calculateDepth(root, 0);
    }

    return {
        roots: rootNodes,
        nodeMap,
    };
}

/**
 * Gets the path from root to a specific collection.
 *
 * @param tree - The collection tree
 * @param collectionID - The target collection ID
 * @returns Array of collections from root to target, or undefined if not found
 */
export function getCollectionPath(
    tree: CollectionTree,
    collectionID: number,
): Collection[] | undefined {
    const node = tree.nodeMap.get(collectionID);
    if (!node) return undefined;

    const path: Collection[] = [];
    let current: CollectionTreeNode | undefined = node;

    while (current) {
        path.unshift(current.collection);
        const parentID = current.collection.pubMagicMetadata?.data.parentID;
        if (!parentID || parentID === 0) break;
        current = tree.nodeMap.get(parentID);
    }

    return path;
}

/**
 * Gets breadcrumb names from root to a specific collection.
 *
 * @param tree - The collection tree
 * @param collectionID - The target collection ID
 * @returns Array of collection names from root to target
 */
export function getCollectionBreadcrumbs(
    tree: CollectionTree,
    collectionID: number,
): string[] {
    const path = getCollectionPath(tree, collectionID);
    return path ? path.map((c) => c.name) : [];
}

/**
 * Gets all descendant collections of a given collection.
 *
 * @param tree - The collection tree
 * @param collectionID - The parent collection ID
 * @returns Array of all descendant collections
 */
export function getDescendants(
    tree: CollectionTree,
    collectionID: number,
): Collection[] {
    const node = tree.nodeMap.get(collectionID);
    if (!node) return [];

    const descendants: Collection[] = [];

    function collectDescendants(n: CollectionTreeNode): void {
        for (const child of n.children) {
            descendants.push(child.collection);
            collectDescendants(child);
        }
    }

    collectDescendants(node);
    return descendants;
}

/**
 * Gets immediate children of a collection.
 *
 * @param tree - The collection tree
 * @param collectionID - The parent collection ID
 * @returns Array of immediate child collections
 */
export function getChildren(
    tree: CollectionTree,
    collectionID: number,
): Collection[] {
    const node = tree.nodeMap.get(collectionID);
    return node ? node.children.map((n) => n.collection) : [];
}

/**
 * Checks if moving a collection would create a cycle.
 *
 * @param tree - The collection tree
 * @param sourceID - The collection being moved
 * @param targetID - The new parent collection
 * @returns true if this would create a cycle
 */
export function wouldCreateCycle(
    tree: CollectionTree,
    sourceID: number,
    targetID: number,
): boolean {
    if (sourceID === targetID) return true;

    const sourceNode = tree.nodeMap.get(sourceID);
    if (!sourceNode) return false;

    // Check if target is a descendant of source
    const descendants = getDescendants(tree, sourceID);
    return descendants.some((d) => d.id === targetID);
}

/**
 * Gets the depth of a collection in the tree.
 *
 * @param tree - The collection tree
 * @param collectionID - The collection ID
 * @returns The depth (0 for root, -1 if not found)
 */
export function getCollectionDepth(
    tree: CollectionTree,
    collectionID: number,
): number {
    const node = tree.nodeMap.get(collectionID);
    return node ? node.depth : -1;
}

/**
 * Finds the maximum depth of descendants for a given node.
 *
 * @param node - The starting node
 * @returns The maximum depth of any descendant relative to this node
 */
export function getMaxDescendantDepth(node: CollectionTreeNode): number {
    if (node.children.length === 0) return 0;

    let maxDepth = 0;
    for (const child of node.children) {
        const childDepth = 1 + getMaxDescendantDepth(child);
        maxDepth = Math.max(maxDepth, childDepth);
    }
    return maxDepth;
}

/**
 * Sorts collections to maintain tree order (parents before children).
 *
 * @param collections - Collections to sort
 * @returns Sorted collections
 */
export function sortCollectionsTreeOrder(
    collections: Collection[],
): Collection[] {
    const tree = buildCollectionTree(collections);
    const sorted: Collection[] = [];

    function traverse(node: CollectionTreeNode): void {
        sorted.push(node.collection);
        for (const child of node.children) {
            traverse(child);
        }
    }

    for (const root of tree.roots) {
        traverse(root);
    }

    return sorted;
}
