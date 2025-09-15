import CreateNewFolderIcon from "@mui/icons-material/CreateNewFolder";
import DeleteIcon from "@mui/icons-material/Delete";
import DriveFileMoveIcon from "@mui/icons-material/DriveFileMove";
import EditIcon from "@mui/icons-material/Edit";
import MoreVertIcon from "@mui/icons-material/MoreVert";
import { IconButton } from "@mui/material";
import { OverflowMenu, OverflowMenuOption } from "ente-base/components/OverflowMenu";
import React from "react";
import type { Collection } from "ente-media/collection";
import { canCreateSubAlbums } from "../../services/nested-collections";

export interface AlbumContextMenuProps {
    collection: Collection;
    onCreateSubAlbum?: (collection: Collection) => void;
    onMoveAlbum?: (album: Collection, newParent?: Collection) => void;
    onRenameAlbum?: (album: Collection) => void;
    onDeleteAlbum?: (album: Collection) => void;
}

/**
 * Context menu component for album actions (create sub-album, move, rename, delete).
 */
export const AlbumContextMenu: React.FC<AlbumContextMenuProps> = ({
    collection,
    onCreateSubAlbum,
    onMoveAlbum,
    onRenameAlbum,
    onDeleteAlbum,
}) => {
    const canCreateSub = canCreateSubAlbums(collection);

    const handleCreateSubAlbum = (e: React.MouseEvent) => {
        e.stopPropagation();
        if (onCreateSubAlbum) {
            onCreateSubAlbum(collection);
        }
    };

    const handleMoveAlbum = (e: React.MouseEvent) => {
        e.stopPropagation();
        if (onMoveAlbum) {
            onMoveAlbum(collection);
        }
    };

    const handleRenameAlbum = (e: React.MouseEvent) => {
        e.stopPropagation();
        if (onRenameAlbum) {
            onRenameAlbum(collection);
        }
    };

    const handleDeleteAlbum = (e: React.MouseEvent) => {
        e.stopPropagation();
        if (onDeleteAlbum) {
            onDeleteAlbum(collection);
        }
    };

    // Don't render if no actions are available
    if (!onCreateSubAlbum && !onMoveAlbum && !onRenameAlbum && !onDeleteAlbum) {
        return null;
    }

    return (
        <OverflowMenu
            ariaID={`album-${collection.id}-menu`}
            triggerButtonIcon={<MoreVertIcon />}
            triggerButtonProps={{
                size: "small",
                sx: { 
                    ml: 0.5,
                    opacity: 0.7,
                    "&:hover": { opacity: 1 },
                },
                onClick: (e: React.MouseEvent) => e.stopPropagation(),
            }}
        >
            {canCreateSub && onCreateSubAlbum && (
                <OverflowMenuOption
                    startIcon={<CreateNewFolderIcon />}
                    onClick={handleCreateSubAlbum}
                >
                    Create Sub-Album
                </OverflowMenuOption>
            )}
            
            {onMoveAlbum && (
                <OverflowMenuOption
                    startIcon={<DriveFileMoveIcon />}
                    onClick={handleMoveAlbum}
                >
                    Move Album
                </OverflowMenuOption>
            )}
            
            {onRenameAlbum && (
                <OverflowMenuOption
                    startIcon={<EditIcon />}
                    onClick={handleRenameAlbum}
                >
                    Rename
                </OverflowMenuOption>
            )}
            
            {onDeleteAlbum && (
                <OverflowMenuOption
                    startIcon={<DeleteIcon />}
                    onClick={handleDeleteAlbum}
                    color="critical.main"
                >
                    Delete Album
                </OverflowMenuOption>
            )}
        </OverflowMenu>
    );
};