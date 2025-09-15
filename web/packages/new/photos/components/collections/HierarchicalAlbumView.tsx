import ExpandLessIcon from "@mui/icons-material/ExpandLess";
import ExpandMoreIcon from "@mui/icons-material/ExpandMore";
import FolderIcon from "@mui/icons-material/Folder";
import FolderOpenIcon from "@mui/icons-material/FolderOpen";
import {
    Box,
    IconButton,
    List,
    ListItem,
    ListItemButton,
    ListItemIcon,
    ListItemText,
    Typography,
} from "@mui/material";
import React, { useMemo, useState } from "react";
import type { Collection } from "ente-media/collection";
import { buildCollectionHierarchy, type CollectionNode } from "../../services/collection-hierarchy";
import { AlbumContextMenu } from "./AlbumContextMenu";

export interface HierarchicalAlbumViewProps {
    /** Collections to display in hierarchy */
    collections: Collection[];
    /** Callback when a collection is selected */
    onSelectCollection: (collection: Collection) => void;
    /** Callback to create a sub-album */
    onCreateSubAlbum?: (parentCollection: Collection) => void;
    /** Callback to move an album */
    onMoveAlbum?: (album: Collection, newParent?: Collection) => void;
    /** Callback to rename an album */
    onRenameAlbum?: (album: Collection) => void;
    /** Callback to delete an album */
    onDeleteAlbum?: (album: Collection) => void;
    /** Function to get file count for a collection */
    getFileCount?: (collection: Collection) => number;
    /** Currently selected collection ID */
    selectedCollectionID?: number;
}

/**
 * Hierarchical album view component that displays collections in a tree structure.
 */
export const HierarchicalAlbumView: React.FC<HierarchicalAlbumViewProps> = ({
    collections,
    onSelectCollection,
    onCreateSubAlbum,
    onMoveAlbum,
    onRenameAlbum,
    onDeleteAlbum,
    getFileCount,
    selectedCollectionID,
}) => {
    const [expandedNodes, setExpandedNodes] = useState<Set<number>>(new Set());

    const hierarchyTree = useMemo(() => {
        return buildCollectionHierarchy(collections);
    }, [collections]);

    const toggleNodeExpansion = (nodeId: number) => {
        setExpandedNodes(prev => {
            const newSet = new Set(prev);
            if (newSet.has(nodeId)) {
                newSet.delete(nodeId);
            } else {
                newSet.add(nodeId);
            }
            return newSet;
        });
    };

    const handleSelectCollection = (collection: Collection) => {
        onSelectCollection(collection);
    };

    const handleCreateSubAlbum = (collection: Collection) => {
        if (onCreateSubAlbum) {
            onCreateSubAlbum(collection);
        }
    };

    const handleMoveAlbum = (album: Collection, newParent?: Collection) => {
        if (onMoveAlbum) {
            onMoveAlbum(album, newParent);
        }
    };

    if (hierarchyTree.length === 0) {
        return (
            <Box sx={{ p: 3, textAlign: "center" }}>
                <Typography variant="body2" color="text.secondary">
                    No albums found
                </Typography>
            </Box>
        );
    }

    return (
        <List dense disablePadding>
            {hierarchyTree.map(node => (
                <AlbumTreeNode
                    key={node.collection.id}
                    node={node}
                    expandedNodes={expandedNodes}
                    onToggleExpand={toggleNodeExpansion}
                    onSelectCollection={handleSelectCollection}
                    onCreateSubAlbum={onCreateSubAlbum ? handleCreateSubAlbum : undefined}
                    onMoveAlbum={onMoveAlbum ? handleMoveAlbum : undefined}
                    onRenameAlbum={onRenameAlbum}
                    onDeleteAlbum={onDeleteAlbum}
                    getFileCount={getFileCount}
                    selectedCollectionID={selectedCollectionID}
                />
            ))}
        </List>
    );
};

interface AlbumTreeNodeProps {
    node: CollectionNode;
    expandedNodes: Set<number>;
    onToggleExpand: (nodeId: number) => void;
    onSelectCollection: (collection: Collection) => void;
    onCreateSubAlbum?: (collection: Collection) => void;
    onMoveAlbum?: (album: Collection, newParent?: Collection) => void;
    onRenameAlbum?: (album: Collection) => void;
    onDeleteAlbum?: (album: Collection) => void;
    getFileCount?: (collection: Collection) => number;
    selectedCollectionID?: number;
}

/**
 * Individual tree node component for displaying a collection in the hierarchy.
 */
const AlbumTreeNode: React.FC<AlbumTreeNodeProps> = ({
    node,
    expandedNodes,
    onToggleExpand,
    onSelectCollection,
    onCreateSubAlbum,
    onMoveAlbum,
    onRenameAlbum,
    onDeleteAlbum,
    getFileCount,
    selectedCollectionID,
}) => {
    const { collection, children, depth } = node;
    const isExpanded = expandedNodes.has(collection.id);
    const hasChildren = children.length > 0;
    const isSelected = selectedCollectionID === collection.id;
    const fileCount = getFileCount ? getFileCount(collection) : 0;

    const indentLevel = depth * 3; // 3 spacing units per level

    return (
        <>
            <ListItem
                disablePadding
                sx={{ 
                    ml: indentLevel,
                    borderRadius: 1,
                    mb: 0.5,
                    backgroundColor: isSelected ? "action.selected" : "transparent",
                    "&:hover": { 
                        backgroundColor: isSelected ? "action.selected" : "action.hover" 
                    },
                }}
            >
                <ListItemButton
                    onClick={() => onSelectCollection(collection)}
                    sx={{ 
                        flex: 1,
                        py: 1,
                        px: 1.5,
                        borderRadius: 1,
                    }}
                >
                    <ListItemIcon sx={{ minWidth: 40 }}>
                        {hasChildren ? (
                            isExpanded ? (
                                <FolderOpenIcon color="primary" />
                            ) : (
                                <FolderIcon color="primary" />
                            )
                        ) : (
                            <FolderIcon color="secondary" />
                        )}
                    </ListItemIcon>
                    
                    <ListItemText
                        primary={collection.name}
                        secondary={
                            fileCount > 0 || hasChildren > 0 ? (
                                <>
                                    {hasChildren > 0 && `${children.length} sub-album${children.length !== 1 ? 's' : ''}`}
                                    {hasChildren > 0 && fileCount > 0 && " • "}
                                    {fileCount > 0 && `${fileCount} photo${fileCount !== 1 ? 's' : ''}`}
                                </>
                            ) : undefined
                        }
                        primaryTypographyProps={{
                            fontSize: "0.875rem",
                            fontWeight: isSelected ? 600 : 400,
                        }}
                        secondaryTypographyProps={{
                            fontSize: "0.75rem",
                        }}
                    />

                    {hasChildren && (
                        <IconButton
                            onClick={(e) => {
                                e.stopPropagation();
                                onToggleExpand(collection.id);
                            }}
                            size="small"
                            sx={{ ml: 1 }}
                        >
                            {isExpanded ? (
                                <ExpandLessIcon fontSize="small" />
                            ) : (
                                <ExpandMoreIcon fontSize="small" />
                            )}
                        </IconButton>
                    )}

                    <AlbumContextMenu
                        collection={collection}
                        onCreateSubAlbum={onCreateSubAlbum}
                        onMoveAlbum={onMoveAlbum}
                        onRenameAlbum={onRenameAlbum}
                        onDeleteAlbum={onDeleteAlbum}
                    />
                </ListItemButton>
            </ListItem>

            {hasChildren && isExpanded && (
                <Box>
                    {children.map(childNode => (
                        <AlbumTreeNode
                            key={childNode.collection.id}
                            node={childNode}
                            expandedNodes={expandedNodes}
                            onToggleExpand={onToggleExpand}
                            onSelectCollection={onSelectCollection}
                            onCreateSubAlbum={onCreateSubAlbum}
                            onMoveAlbum={onMoveAlbum}
                            onRenameAlbum={onRenameAlbum}
                            onDeleteAlbum={onDeleteAlbum}
                            getFileCount={getFileCount}
                            selectedCollectionID={selectedCollectionID}
                        />
                    ))}
                </Box>
            )}
        </>
    );
};