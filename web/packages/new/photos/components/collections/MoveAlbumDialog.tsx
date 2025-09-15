import {
    Button,
    Dialog,
    DialogActions,
    DialogContent,
    DialogTitle,
    FormControl,
    FormControlLabel,
    Radio,
    RadioGroup,
    Typography,
} from "@mui/material";
import { LoadingButton } from "ente-base/components/mui/LoadingButton";
import React, { useState } from "react";
import type { Collection } from "ente-media/collection";
import { getValidParentCollections, moveAlbumToParent } from "../../services/nested-collections";

export interface MoveAlbumDialogProps {
    open: boolean;
    onClose: () => void;
    album: Collection;
    allCollections: Collection[];
    onAlbumMoved: (album: Collection, newParent?: Collection) => void;
}

/**
 * Dialog for moving an album to a different parent or to root level.
 */
export const MoveAlbumDialog: React.FC<MoveAlbumDialogProps> = ({
    open,
    onClose,
    album,
    allCollections,
    onAlbumMoved,
}) => {
    const [selectedParentId, setSelectedParentId] = useState<string>("root");
    const [isLoading, setIsLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);

    // Get valid parent options (excluding the album itself and its descendants)
    const validParents = getValidParentCollections(album, allCollections);

    const handleMove = async () => {
        setIsLoading(true);
        setError(null);

        try {
            const newParentId = selectedParentId === "root" ? undefined : parseInt(selectedParentId, 10);
            await moveAlbumToParent(album.id, newParentId, allCollections);
            
            const newParent = newParentId ? allCollections.find(c => c.id === newParentId) : undefined;
            onAlbumMoved(album, newParent);
            onClose();
        } catch (err) {
            console.error("Failed to move album:", err);
            setError(err instanceof Error ? err.message : "Failed to move album");
        } finally {
            setIsLoading(false);
        }
    };

    const handleClose = () => {
        if (!isLoading) {
            setSelectedParentId("root");
            setError(null);
            onClose();
        }
    };

    const handleParentChange = (event: React.ChangeEvent<HTMLInputElement>) => {
        setSelectedParentId(event.target.value);
        if (error) setError(null);
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
                Move "{album.name}"
            </DialogTitle>
            
            <DialogContent>
                <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
                    Choose a new location for this album:
                </Typography>

                <FormControl component="fieldset" fullWidth>
                    <RadioGroup
                        value={selectedParentId}
                        onChange={handleParentChange}
                    >
                        <FormControlLabel
                            value="root"
                            control={<Radio />}
                            label={
                                <div>
                                    <Typography variant="body2" fontWeight={500}>
                                        Root Level
                                    </Typography>
                                    <Typography variant="caption" color="text.secondary">
                                        Move to the top level (no parent album)
                                    </Typography>
                                </div>
                            }
                            disabled={isLoading}
                        />
                        
                        {validParents.map((parent) => (
                            <FormControlLabel
                                key={parent.id}
                                value={parent.id.toString()}
                                control={<Radio />}
                                label={
                                    <div>
                                        <Typography variant="body2" fontWeight={500}>
                                            {parent.name}
                                        </Typography>
                                        {parent.parentID && (
                                            <Typography variant="caption" color="text.secondary">
                                                Sub-album
                                            </Typography>
                                        )}
                                    </div>
                                }
                                disabled={isLoading}
                            />
                        ))}
                    </RadioGroup>
                </FormControl>

                {validParents.length === 0 && (
                    <Typography variant="body2" color="text.secondary" sx={{ mt: 2, fontStyle: "italic" }}>
                        No valid parent albums available. You can only move to root level.
                    </Typography>
                )}

                {error && (
                    <Typography variant="body2" color="error" sx={{ mt: 2 }}>
                        {error}
                    </Typography>
                )}
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
                    onClick={handleMove}
                    loading={isLoading}
                    variant="contained"
                >
                    Move
                </LoadingButton>
            </DialogActions>
        </Dialog>
    );
};