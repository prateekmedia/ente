import React, { useState, useMemo, useCallback } from "react";
import {
    Box,
    Dialog,
    DialogTitle,
    DialogContent,
    DialogActions,
    Button,
    TextField,
    List,
    ListItem,
    ListItemButton,
    ListItemIcon,
    ListItemText,
    Checkbox,
    IconButton,
    Typography,
    Breadcrumbs,
    Link,
    Chip,
    InputAdornment,
    Paper,
    Divider,
} from "@mui/material";
import {
    Folder as FolderIcon,
    FolderOpen as FolderOpenIcon,
    ChevronRight as ChevronRightIcon,
    Add as AddIcon,
    Search as SearchIcon,
    Clear as ClearIcon,
    CreateNewFolder as CreateNewFolderIcon,
} from "@mui/icons-material";
import type { Collection } from "ente-media/collection";
import { getCollectionParentID } from "ente-media/collection";
import {
    buildCollectionHierarchy,
    hasHierarchicalStructure,
    getDescendantCollections,
    type CollectionNode,
} from "../../services/collection-hierarchy";
import { createSubAlbum, createAlbum } from "../../services/collection";
import { isNestedAlbumsEnabled, isNestedAlbumsServerEnabled } from "../../services/feature-flags";

export interface HierarchicalAlbumSelectorProps {
    /** All collections to display */
    collections: Collection[];
    /** Whether to allow multiple selection */
    allowMultipleSelection?: boolean;
    /** Whether to show create album option */
    showCreateAlbumOption?: boolean;
    /** Collections to exclude from selection */
    excludedCollections?: Collection[];
    /** Callback when single album is selected */
    onSelectAlbum?: (album: Collection) => void;
    /** Callback when multiple albums are selected */
    onSelectMultipleAlbums?: (albums: Collection[]) => void;
    /** Title for the dialog */
    title?: string;
    /** Action button text */
    actionButtonText?: string;
    /** Whether dialog is open */
    open: boolean;
    /** Callback to close dialog */
    onClose: () => void;
}

/**
 * Hierarchical album selector with breadcrumb navigation and search.
 * Automatically shows hierarchical view when albums have nested structure.
 */
export const HierarchicalAlbumSelector: React.FC<HierarchicalAlbumSelectorProps> = ({
    collections,
    allowMultipleSelection = false,
    showCreateAlbumOption = true,
    excludedCollections = [],
    onSelectAlbum,
    onSelectMultipleAlbums,
    title = "Select Album",
    actionButtonText = "Select",
    open,
    onClose,
}) => {
    const [searchQuery, setSearchQuery] = useState("");
    const [selectedAlbums, setSelectedAlbums] = useState<Set<number>>(new Set());
    const [currentLocation, setCurrentLocation] = useState<Collection | null>(null);
    const [navigationStack, setNavigationStack] = useState<(Collection | null)[]>([null]);
    const [createAlbumDialogOpen, setCreateAlbumDialogOpen] = useState(false);
    const [newAlbumName, setNewAlbumName] = useState("");

    // Check if we should show hierarchical view
    const shouldShowHierarchical = useMemo(() => {
        return hasHierarchicalStructure(collections) || isNestedAlbumsEnabled();
    }, [collections]);

    // Filter collections
    const filteredCollections = useMemo(() => {
        return collections.filter(c => 
            !excludedCollections.some(ex => ex.id === c.id)
        );
    }, [collections, excludedCollections]);

    // Build hierarchy if needed
    const hierarchyTree = useMemo(() => {
        if (!shouldShowHierarchical) return null;
        return buildCollectionHierarchy(filteredCollections);
    }, [filteredCollections, shouldShowHierarchical]);

    // Get collections at current level
    const currentLevelCollections = useMemo(() => {
        if (searchQuery) {
            // Show flat filtered list when searching
            return filteredCollections.filter(c =>
                c.name.toLowerCase().includes(searchQuery.toLowerCase())
            );
        }

        if (!shouldShowHierarchical) {
            return filteredCollections;
        }

        // Show collections at current level
        const currentParentId = currentLocation?.id ?? null;
        return filteredCollections.filter(c => 
            getCollectionParentID(c) === currentParentId
        );
    }, [filteredCollections, searchQuery, shouldShowHierarchical, currentLocation]);

    const navigateTo = useCallback((collection: Collection | null) => {
        setCurrentLocation(collection);
        if (collection === null) {
            setNavigationStack([null]);
        } else {
            const index = navigationStack.findIndex(item => item?.id === collection.id);
            if (index !== -1) {
                // Going back in stack
                setNavigationStack(navigationStack.slice(0, index + 1));
            } else {
                // Going forward
                setNavigationStack([...navigationStack, collection]);
            }
        }
    }, [navigationStack]);

    const handleSelectAlbum = useCallback((album: Collection) => {
        if (allowMultipleSelection) {
            setSelectedAlbums(prev => {
                const newSet = new Set(prev);
                if (newSet.has(album.id)) {
                    newSet.delete(album.id);
                } else {
                    newSet.add(album.id);
                }
                return newSet;
            });
        } else {
            onSelectAlbum?.(album);
            onClose();
        }
    }, [allowMultipleSelection, onSelectAlbum, onClose]);

    const handleConfirmSelection = useCallback(() => {
        const selected = collections.filter(c => selectedAlbums.has(c.id));
        onSelectMultipleAlbums?.(selected);
        onClose();
    }, [collections, selectedAlbums, onSelectMultipleAlbums, onClose]);

    const handleCreateAlbum = useCallback(async () => {
        if (!newAlbumName.trim()) return;

        try {
            let newAlbum: Collection;
            if (currentLocation) {
                // Create sub-album
                newAlbum = await createSubAlbum(
                    currentLocation,
                    newAlbumName.trim(),
                    collections
                );
            } else {
                // Create root album
                newAlbum = await createAlbum(newAlbumName.trim());
            }

            // Select the new album
            if (allowMultipleSelection) {
                setSelectedAlbums(prev => new Set([...prev, newAlbum.id]));
            } else {
                onSelectAlbum?.(newAlbum);
                onClose();
            }

            setCreateAlbumDialogOpen(false);
            setNewAlbumName("");
        } catch (error) {
            console.error("Failed to create album:", error);
        }
    }, [newAlbumName, currentLocation, collections, allowMultipleSelection, onSelectAlbum, onClose]);

    const getAlbumPath = useCallback((album: Collection): string => {
        const path: string[] = [];
        let current = album;
        
        while (current) {
            const parentId = getCollectionParentID(current);
            if (!parentId) break;
            
            const parent = collections.find(c => c.id === parentId);
            if (!parent) break;
            
            path.unshift(parent.name);
            current = parent;
        }
        
        return path.join(" › ");
    }, [collections]);

    const hasChildren = useCallback((album: Collection): boolean => {
        return filteredCollections.some(c => getCollectionParentID(c) === album.id);
    }, [filteredCollections]);

    return (
        <>
            <Dialog
                open={open}
                onClose={onClose}
                maxWidth="sm"
                fullWidth
                PaperProps={{
                    sx: { height: "80vh", display: "flex", flexDirection: "column" }
                }}
            >
                <DialogTitle>
                    <Box display="flex" alignItems="center" justifyContent="space-between">
                        <Typography variant="h6">{title}</Typography>
                        {allowMultipleSelection && selectedAlbums.size > 0 && (
                            <Chip
                                label={selectedAlbums.size}
                                size="small"
                                color="primary"
                            />
                        )}
                    </Box>
                </DialogTitle>

                <DialogContent sx={{ flex: 1, display: "flex", flexDirection: "column", p: 0 }}>
                    {/* Search Bar */}
                    <Box sx={{ p: 2, pb: 1 }}>
                        <TextField
                            fullWidth
                            size="small"
                            placeholder="Search albums..."
                            value={searchQuery}
                            onChange={(e) => setSearchQuery(e.target.value)}
                            InputProps={{
                                startAdornment: (
                                    <InputAdornment position="start">
                                        <SearchIcon />
                                    </InputAdornment>
                                ),
                                endAdornment: searchQuery && (
                                    <InputAdornment position="end">
                                        <IconButton
                                            size="small"
                                            onClick={() => setSearchQuery("")}
                                        >
                                            <ClearIcon />
                                        </IconButton>
                                    </InputAdornment>
                                ),
                            }}
                        />
                    </Box>

                    {/* Breadcrumbs */}
                    {shouldShowHierarchical && !searchQuery && (
                        <Box sx={{ px: 2, pb: 1 }}>
                            <Breadcrumbs separator={<ChevronRightIcon fontSize="small" />}>
                                {navigationStack.map((item, index) => {
                                    const isLast = index === navigationStack.length - 1;
                                    return (
                                        <Link
                                            key={item?.id ?? "root"}
                                            component="button"
                                            variant="body2"
                                            onClick={() => !isLast && navigateTo(item)}
                                            underline={isLast ? "none" : "hover"}
                                            color={isLast ? "text.primary" : "inherit"}
                                            sx={{ cursor: isLast ? "default" : "pointer" }}
                                        >
                                            {item?.name ?? "Albums"}
                                        </Link>
                                    );
                                })}
                            </Breadcrumbs>
                        </Box>
                    )}

                    <Divider />

                    {/* Album List */}
                    <Box sx={{ flex: 1, overflow: "auto" }}>
                        <List dense>
                            {/* Create Album Option */}
                            {showCreateAlbumOption && !searchQuery && isNestedAlbumsServerEnabled() && (
                                <ListItem disablePadding>
                                    <ListItemButton onClick={() => setCreateAlbumDialogOpen(true)}>
                                        <ListItemIcon>
                                            <CreateNewFolderIcon color="primary" />
                                        </ListItemIcon>
                                        <ListItemText 
                                            primary={
                                                currentLocation 
                                                    ? "Create sub-album" 
                                                    : "Create new album"
                                            }
                                            primaryTypographyProps={{ color: "primary" }}
                                        />
                                    </ListItemButton>
                                </ListItem>
                            )}

                            {/* Albums */}
                            {currentLevelCollections.map(album => {
                                const albumHasChildren = hasChildren(album);
                                const isSelected = selectedAlbums.has(album.id);
                                
                                return (
                                    <ListItem
                                        key={album.id}
                                        disablePadding
                                        secondaryAction={
                                            albumHasChildren && !searchQuery && (
                                                <IconButton 
                                                    edge="end" 
                                                    onClick={() => navigateTo(album)}
                                                >
                                                    <ChevronRightIcon />
                                                </IconButton>
                                            )
                                        }
                                    >
                                        <ListItemButton 
                                            onClick={() => {
                                                if (albumHasChildren && !searchQuery && !allowMultipleSelection) {
                                                    navigateTo(album);
                                                } else {
                                                    handleSelectAlbum(album);
                                                }
                                            }}
                                        >
                                            {allowMultipleSelection && (
                                                <ListItemIcon>
                                                    <Checkbox
                                                        edge="start"
                                                        checked={isSelected}
                                                        tabIndex={-1}
                                                        disableRipple
                                                    />
                                                </ListItemIcon>
                                            )}
                                            <ListItemIcon>
                                                {albumHasChildren ? <FolderIcon /> : <FolderOpenIcon />}
                                            </ListItemIcon>
                                            <ListItemText 
                                                primary={album.name}
                                                secondary={searchQuery ? getAlbumPath(album) : undefined}
                                            />
                                        </ListItemButton>
                                    </ListItem>
                                );
                            })}

                            {currentLevelCollections.length === 0 && (
                                <ListItem>
                                    <ListItemText 
                                        primary="No albums found"
                                        secondary={searchQuery ? "Try a different search" : "This location is empty"}
                                        sx={{ textAlign: "center", py: 4 }}
                                    />
                                </ListItem>
                            )}
                        </List>
                    </Box>
                </DialogContent>

                <DialogActions>
                    <Button onClick={onClose}>Cancel</Button>
                    {allowMultipleSelection && (
                        <Button
                            onClick={handleConfirmSelection}
                            variant="contained"
                            disabled={selectedAlbums.size === 0}
                        >
                            {actionButtonText} ({selectedAlbums.size})
                        </Button>
                    )}
                </DialogActions>
            </Dialog>

            {/* Create Album Dialog */}
            <Dialog
                open={createAlbumDialogOpen}
                onClose={() => setCreateAlbumDialogOpen(false)}
                maxWidth="xs"
                fullWidth
            >
                <DialogTitle>
                    {currentLocation ? "Create Sub-album" : "Create New Album"}
                </DialogTitle>
                <DialogContent>
                    <TextField
                        autoFocus
                        margin="dense"
                        label="Album name"
                        fullWidth
                        variant="outlined"
                        value={newAlbumName}
                        onChange={(e) => setNewAlbumName(e.target.value)}
                        onKeyPress={(e) => {
                            if (e.key === "Enter") {
                                handleCreateAlbum();
                            }
                        }}
                    />
                </DialogContent>
                <DialogActions>
                    <Button onClick={() => setCreateAlbumDialogOpen(false)}>
                        Cancel
                    </Button>
                    <Button
                        onClick={handleCreateAlbum}
                        variant="contained"
                        disabled={!newAlbumName.trim()}
                    >
                        Create
                    </Button>
                </DialogActions>
            </Dialog>
        </>
    );
};