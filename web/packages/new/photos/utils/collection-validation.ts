/**
 * Validation utilities for nested collection operations.
 *
 * This module provides validation logic to ensure collection operations
 * maintain tree integrity and respect constraints.
 */

import type { Collection } from "ente-media/collection";
import type { CollectionTree } from "./collection-tree";
import {
    getCollectionDepth,
    getDescendants,
    getMaxDescendantDepth,
    wouldCreateCycle,
} from "./collection-tree";

/** Maximum allowed nesting depth */
export const MAX_COLLECTION_DEPTH = 10;

/**
 * Result of a validation operation.
 */
export interface ValidationResult {
    /** Whether the operation is valid */
    isValid: boolean;
    /** Error message if invalid */
    errorMessage?: string;
    /** Warning message (operation is valid but user should be notified) */
    warningMessage?: string;
}

/**
 * Creates a successful validation result.
 */
export function validResult(): ValidationResult {
    return { isValid: true };
}

/**
 * Creates a validation result with an error.
 */
export function invalidResult(errorMessage: string): ValidationResult {
    return { isValid: false, errorMessage };
}

/**
 * Creates a validation result with a warning.
 */
export function warningResult(warningMessage: string): ValidationResult {
    return { isValid: true, warningMessage };
}

/**
 * Validates if a collection can be set as a child of another collection.
 *
 * @param child - The collection being moved
 * @param newParent - The new parent (undefined/null for root)
 * @param currentUserID - The current user's ID
 * @param tree - The current collection tree
 * @returns Validation result
 */
export function validateSetParent(
    child: Collection,
    newParent: Collection | undefined | null,
    currentUserID: number,
    tree: CollectionTree,
): ValidationResult {
    // Allow moving to root
    if (!newParent) {
        return validResult();
    }

    // Check if child and parent are the same
    if (child.id === newParent.id) {
        return invalidResult("Cannot set a collection as its own parent");
    }

    // Check ownership - only owner can reparent
    if (child.owner.id !== currentUserID) {
        return invalidResult("Only the owner can move this album");
    }

    if (newParent.owner.id !== currentUserID) {
        return invalidResult(
            "You can only move albums into albums you own",
        );
    }

    // Check collection type constraints
    const typeValidation = validateCollectionTypes(child, newParent);
    if (!typeValidation.isValid) {
        return typeValidation;
    }

    // Check for cycles
    if (wouldCreateCycle(tree, child.id, newParent.id)) {
        return invalidResult(
            "Cannot move album: this would create a circular hierarchy",
        );
    }

    // Check depth limit at target
    const newDepth = getCollectionDepth(tree, newParent.id) + 1;
    if (newDepth > MAX_COLLECTION_DEPTH) {
        return invalidResult(
            `Cannot move album: maximum nesting depth (${MAX_COLLECTION_DEPTH} levels) exceeded`,
        );
    }

    // Check if child subtree would exceed max depth
    const childNode = tree.nodeMap.get(child.id);
    if (childNode) {
        const maxChildDepth = getMaxDescendantDepth(childNode);
        if (newDepth + maxChildDepth > MAX_COLLECTION_DEPTH) {
            return invalidResult(
                `Cannot move album: the nested structure would exceed maximum depth (${MAX_COLLECTION_DEPTH} levels)`,
            );
        }
    }

    // Check for share visibility mismatches (warning only)
    const shareValidation = checkShareVisibility(child, newParent);
    if (shareValidation.warningMessage) {
        return shareValidation;
    }

    return validResult();
}

/**
 * Validates collection type constraints.
 */
function validateCollectionTypes(
    child: Collection,
    parent: Collection,
): ValidationResult {
    // Favorites and uncategorized cannot be nested or have children
    if (child.type === "favorites") {
        return invalidResult(
            "Favorites album cannot be nested under another album",
        );
    }

    if (child.type === "uncategorized") {
        return invalidResult(
            "Uncategorized album cannot be nested under another album",
        );
    }

    if (parent.type === "favorites") {
        return invalidResult("Cannot nest albums under Favorites");
    }

    if (parent.type === "uncategorized") {
        return invalidResult("Cannot nest albums under Uncategorized");
    }

    return validResult();
}

/**
 * Checks for share visibility mismatches between child and parent.
 */
function checkShareVisibility(
    child: Collection,
    parent: Collection,
): ValidationResult {
    const childHasSharees = child.sharees && child.sharees.length > 0;
    const parentHasSharees = parent.sharees && parent.sharees.length > 0;

    if (childHasSharees !== parentHasSharees) {
        return warningResult(
            "The album you're moving has different sharing settings than the destination. " +
                "You may want to update sharing settings for consistency.",
        );
    }

    // Check if child is shared with people not on parent's list
    if (childHasSharees && parentHasSharees) {
        const childShareeIds = new Set(child.sharees.map((s) => s.id));
        const parentShareeIds = new Set(parent.sharees.map((s) => s.id));

        // Check if sets are different
        for (const id of childShareeIds) {
            if (!parentShareeIds.has(id)) {
                return warningResult(
                    "The album is shared with different people than the destination album. " +
                        "Consider updating sharing settings for consistency.",
                );
            }
        }
        for (const id of parentShareeIds) {
            if (!childShareeIds.has(id)) {
                return warningResult(
                    "The album is shared with different people than the destination album. " +
                        "Consider updating sharing settings for consistency.",
                );
            }
        }
    }

    return validResult();
}

/**
 * Validates if a collection can be deleted.
 *
 * @param collection - The collection to delete
 * @param currentUserID - The current user's ID
 * @param tree - The current collection tree
 * @param deleteDescendants - Whether to delete descendants
 * @returns Validation result
 */
export function validateDelete(
    collection: Collection,
    currentUserID: number,
    tree: CollectionTree,
    deleteDescendants: boolean,
): ValidationResult {
    // Check ownership
    if (collection.owner.id !== currentUserID) {
        return invalidResult("Only the owner can delete this album");
    }

    // Check type constraints
    if (!canDelete(collection.type)) {
        return invalidResult("This album cannot be deleted");
    }

    // Check if has children and warn
    const node = tree.nodeMap.get(collection.id);
    if (node && node.children.length > 0 && !deleteDescendants) {
        return warningResult(
            `This album contains ${node.children.length} nested album${node.children.length === 1 ? "" : "s"}. ` +
                "They will be moved to the root level.",
        );
    }

    return validResult();
}

/**
 * Checks if a collection type can be deleted.
 */
function canDelete(type: string): boolean {
    // Favorites and uncategorized can't be deleted
    return type !== "favorites" && type !== "uncategorized";
}

/**
 * Validates if collections can be shared as a subtree.
 *
 * @param parent - The parent collection
 * @param currentUserID - The current user's ID
 * @param tree - The current collection tree
 * @returns Validation result
 */
export function validateSubtreeShare(
    parent: Collection,
    currentUserID: number,
    tree: CollectionTree,
): ValidationResult {
    // Check ownership
    if (parent.owner.id !== currentUserID) {
        return invalidResult("Only the owner can share this album");
    }

    // Get all descendants
    const descendants = getDescendants(tree, parent.id);

    // Check if all descendants are owned by current user
    for (const descendant of descendants) {
        if (descendant.owner.id !== currentUserID) {
            return invalidResult(
                `Cannot share subtree: descendant album "${descendant.name}" is not owned by you`,
            );
        }
    }

    // Warn about large subtrees
    if (descendants.length > 100) {
        return warningResult(
            `You're about to share ${descendants.length + 1} albums. This may take some time.`,
        );
    }

    return validResult();
}

/**
 * Checks if a collection can have children.
 *
 * @param collection - The collection to check
 * @returns Validation result
 */
export function canHaveChildren(collection: Collection): ValidationResult {
    if (collection.type === "favorites") {
        return invalidResult("Favorites album cannot have nested albums");
    }

    if (collection.type === "uncategorized") {
        return invalidResult("Uncategorized album cannot have nested albums");
    }

    return validResult();
}

/**
 * Validates batch operations on multiple collections.
 *
 * @param collections - Collections to operate on
 * @param limit - Maximum allowed in batch
 * @returns Validation result
 */
export function validateBatchOperation(
    collections: Collection[],
    limit: number,
): ValidationResult {
    if (collections.length === 0) {
        return invalidResult("No albums selected");
    }

    if (collections.length > limit) {
        return invalidResult(
            `Too many albums selected. Maximum is ${limit} per operation.`,
        );
    }

    return validResult();
}
