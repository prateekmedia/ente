import {
    Button,
    Dialog,
    DialogActions,
    DialogContent,
    DialogTitle,
    TextField,
} from "@mui/material";
import { LoadingButton } from "ente-base/components/mui/LoadingButton";
import React, { useState } from "react";
import type { Collection } from "ente-media/collection";
import { createSubAlbum } from "../../services/nested-collections";

export interface CreateSubAlbumDialogProps {
    open: boolean;
    onClose: () => void;
    parentAlbum: Collection;
    allCollections: Collection[];
    onAlbumCreated: (album: Collection) => void;
}

/**
 * Dialog for creating a new sub-album within a parent album.
 */
export const CreateSubAlbumDialog: React.FC<CreateSubAlbumDialogProps> = ({
    open,
    onClose,
    parentAlbum,
    allCollections,
    onAlbumCreated,
}) => {
    const [albumName, setAlbumName] = useState("");
    const [isLoading, setIsLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);

    const handleCreateSubAlbum = async () => {
        if (!albumName.trim()) {
            setError("Album name is required");
            return;
        }

        setIsLoading(true);
        setError(null);

        try {
            const newAlbum = await createSubAlbum(parentAlbum, albumName.trim(), allCollections);
            onAlbumCreated(newAlbum);
            setAlbumName("");
            onClose();
        } catch (err) {
            console.error("Failed to create sub-album:", err);
            setError(err instanceof Error ? err.message : "Failed to create sub-album");
        } finally {
            setIsLoading(false);
        }
    };

    const handleClose = () => {
        if (!isLoading) {
            setAlbumName("");
            setError(null);
            onClose();
        }
    };

    const handleKeyPress = (e: React.KeyboardEvent) => {
        if (e.key === "Enter" && albumName.trim() && !isLoading) {
            handleCreateSubAlbum();
        }
    };

    return (
        <Dialog 
            open={open} 
            onClose={handleClose} 
            maxWidth="sm" 
            fullWidth
            disableEscapeKeyDown={isLoading}
        >
            <DialogTitle>
                Create Sub-Album in "{parentAlbum.name}"
            </DialogTitle>
            
            <DialogContent>
                <TextField
                    autoFocus
                    margin="dense"
                    label="Album Name"
                    fullWidth
                    variant="outlined"
                    value={albumName}
                    onChange={(e) => {
                        setAlbumName(e.target.value);
                        if (error) setError(null);
                    }}
                    onKeyPress={handleKeyPress}
                    error={!!error}
                    helperText={error}
                    disabled={isLoading}
                    placeholder="Enter album name..."
                />
            </DialogContent>
            
            <DialogActions sx={{ px: 3, pb: 2 }}>
                <Button 
                    onClick={handleClose} 
                    disabled={isLoading}
                    color="secondary"
                >
                    Cancel
                </Button>
                <LoadingButton
                    onClick={handleCreateSubAlbum}
                    loading={isLoading}
                    disabled={!albumName.trim()}
                    variant="contained"
                >
                    Create
                </LoadingButton>
            </DialogActions>
        </Dialog>
    );
};