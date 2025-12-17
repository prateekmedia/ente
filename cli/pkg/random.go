package pkg

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/ente-io/cli/pkg/mapper"
	"github.com/ente-io/cli/pkg/model"
	"github.com/ente-io/cli/utils"
	"github.com/ente-io/cli/utils/encoding"
)

// isFileOutputPath checks if the path looks like a file (has an extension)
func isFileOutputPath(path string) bool {
	ext := filepath.Ext(path)
	return ext != "" && len(ext) <= 5 // reasonable extension length
}

func (c *ClICtrl) DownloadRandomFromAlbum(albumName, outputPath, fileType string) error {
	trimmedAlbum := strings.TrimSpace(albumName)
	if trimmedAlbum == "" {
		return fmt.Errorf("album name is required")
	}

	if outputPath == "" {
		outputPath = "."
	}
	if strings.Contains(outputPath, "..") {
		return fmt.Errorf("output path cannot contain '..'")
	}
	outputPath = filepath.Clean(outputPath)

	// Check if output is a file path or directory
	outputIsFile := isFileOutputPath(outputPath)
	if outputIsFile {
		// Create parent directory for file
		if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
			return fmt.Errorf("failed to prepare output directory: %w", err)
		}
	} else {
		// Create the directory
		if err := os.MkdirAll(outputPath, 0o755); err != nil {
			return fmt.Errorf("failed to prepare output directory %s: %w", outputPath, err)
		}
	}

	typeFilter, err := parseFileType(fileType)
	if err != nil {
		return err
	}

	accounts, err := c.GetAccounts(context.Background())
	if err != nil {
		return err
	}
	if len(accounts) == 0 {
		return fmt.Errorf("no accounts configured, use 'ente account add'")
	}
	account := accounts[0]

	secretInfo, err := c.KeyHolder.LoadSecrets(account)
	if err != nil {
		return err
	}

	ctx := c.buildRequestContext(context.Background(), account, model.Filter{})
	c.Client.AddToken(account.AccountKey(), base64.URLEncoding.EncodeToString(secretInfo.Token))

	if err := createDataBuckets(c.DB, account); err != nil {
		return err
	}

	if err := c.fetchRemoteCollections(ctx); err != nil {
		return err
	}

	albums, err := c.getRemoteAlbums(ctx)
	if err != nil {
		return err
	}

	matchingAlbums := make([]model.RemoteAlbum, 0)
	for _, album := range albums {
		if strings.EqualFold(album.AlbumName, albumName) || strings.EqualFold(album.AlbumName, trimmedAlbum) {
			matchingAlbums = append(matchingAlbums, album)
		}
	}

	switch len(matchingAlbums) {
	case 0:
		available := make([]string, 0, len(albums))
		for _, album := range albums {
			if album.IsDeleted {
				continue
			}
			available = append(available, album.AlbumName)
		}
		return fmt.Errorf("album %q not found. available albums: %s", albumName, strings.Join(available, ", "))
	case 1:
		// continue
	default:
		details := make([]string, 0, len(matchingAlbums))
		for _, album := range matchingAlbums {
			details = append(details, fmt.Sprintf("%s (id:%d)", album.AlbumName, album.ID))
		}
		return fmt.Errorf("multiple albums named %q found (not yet supported): %s", albumName, strings.Join(details, "; "))
	}

	album := matchingAlbums[0]
	if album.IsDeleted {
		return fmt.Errorf("album %q is deleted", album.AlbumName)
	}
	if album.IsShared {
		log.Printf("Selected shared album %s", album.AlbumName)
	}

	if err := c.syncAlbumFilesMetadata(ctx, album); err != nil {
		return err
	}

	candidates, err := c.getAlbumCandidates(ctx, album.ID, typeFilter)
	if err != nil {
		return err
	}
	if len(candidates) == 0 {
		return fmt.Errorf("no files found in album %q with the specified criteria", album.AlbumName)
	}

	index, err := randomIndex(len(candidates))
	if err != nil {
		return err
	}
	chosen := candidates[index]

	if chosen.Info.FileSize > 100*1024*1024 {
		log.Printf("Warning: selected file is large (%s)", formatSize(chosen.Info.FileSize))
	}

	decryptedPath, err := c.downloadAndDecrypt(ctx, chosen, c.KeyHolder.DeviceKey)
	if err != nil {
		return err
	}
	defer func() {
		_ = os.Remove(*decryptedPath)
	}()

	fileName := filepath.Base(strings.TrimSpace(chosen.GetTitle()))
	if fileName == "" {
		fileName = fmt.Sprintf("%d", chosen.ID)
	}

	if chosen.IsLivePhoto() {
		imagePath, videoPath, err := UnpackLive(*decryptedPath)
		if err != nil {
			return err
		}
		if outputIsFile {
			// For live photos with file output, save the image part to the specified path
			if imagePath != "" {
				if err := safeMove(imagePath, outputPath); err != nil {
					return err
				}
			}
			// Save video with same name but video extension
			if videoPath != "" {
				videoExt := filepath.Ext(videoPath)
				videoDest := strings.TrimSuffix(outputPath, filepath.Ext(outputPath)) + videoExt
				if err := safeMove(videoPath, videoDest); err != nil {
					return err
				}
			}
		} else {
			baseName := strings.TrimSuffix(fileName, filepath.Ext(fileName))
			if imagePath != "" {
				dest := filepath.Join(outputPath, fmt.Sprintf("%s%s", baseName, filepath.Ext(imagePath)))
				if err := safeMove(imagePath, dest); err != nil {
					return err
				}
			}
			if videoPath != "" {
				dest := filepath.Join(outputPath, fmt.Sprintf("%s%s", baseName, filepath.Ext(videoPath)))
				if err := safeMove(videoPath, dest); err != nil {
					return err
				}
			}
		}
		log.Printf("Downloaded live photo from album %s to %s", album.AlbumName, outputPath)
		return nil
	}

	var dest string
	if outputIsFile {
		dest = outputPath
	} else {
		dest = filepath.Join(outputPath, fileName)
	}
	if err := safeMove(*decryptedPath, dest); err != nil {
		return err
	}

	log.Printf("Downloaded %s from album %s to %s", fileName, album.AlbumName, dest)
	return nil
}

func (c *ClICtrl) syncAlbumFilesMetadata(ctx context.Context, album model.RemoteAlbum) error {
	lastSyncTime, err := c.GetInt64ConfigValue(ctx, fmt.Sprintf(model.CollectionsFileSyncKeyFmt, album.ID))
	if err != nil {
		return err
	}

	isFirstSync := lastSyncTime == 0
	for {
		if lastSyncTime == album.LastUpdatedAt {
			break
		}

		if isFirstSync {
			log.Printf("Sync files metadata for album %s", album.AlbumName)
		} else {
			log.Printf("Sync files metadata for album %s from %s", album.AlbumName, time.UnixMicro(lastSyncTime))
		}

		files, hasMore, err := c.Client.GetFiles(ctx, album.ID, lastSyncTime)
		if err != nil {
			return err
		}

		maxUpdated := lastSyncTime
		for _, file := range files {
			if file.UpdationTime > maxUpdated {
				maxUpdated = file.UpdationTime
			}
			if isFirstSync && file.IsRemovedFromAlbum() {
				continue
			}
			albumEntry := model.AlbumFileEntry{AlbumID: album.ID, FileID: file.ID, IsDeleted: file.IsRemovedFromAlbum(), SyncedLocally: false}
			if err := c.UpsertAlbumEntry(ctx, &albumEntry); err != nil {
				return err
			}
			if file.IsRemovedFromAlbum() {
				continue
			}
			photoFile, err := mapper.MapApiFileToPhotoFile(ctx, album, file, c.KeyHolder)
			if err != nil {
				return err
			}
			fileJSON := encoding.MustMarshalJSON(photoFile)
			if err := c.PutValue(ctx, model.RemoteFiles, []byte(strconv.FormatInt(file.ID, 10)), fileJSON); err != nil {
				return err
			}
		}

		if !hasMore {
			maxUpdated = album.LastUpdatedAt
		}
		if maxUpdated > lastSyncTime || !hasMore {
			if err := c.PutConfigValue(ctx, fmt.Sprintf(model.CollectionsFileSyncKeyFmt, album.ID), []byte(strconv.FormatInt(maxUpdated, 10))); err != nil {
				return fmt.Errorf("failed to update last sync time: %w", err)
			}
			lastSyncTime = maxUpdated
		}
	}

	return nil
}

func (c *ClICtrl) getAlbumCandidates(ctx context.Context, albumID int64, typeFilter *model.FileType) ([]model.RemoteFile, error) {
	entries, err := c.getRemoteAlbumEntries(ctx)
	if err != nil {
		return nil, err
	}

	files := make([]model.RemoteFile, 0)
	for _, entry := range entries {
		if entry.AlbumID != albumID || entry.IsDeleted {
			continue
		}

		fileBytes, err := c.GetValue(ctx, model.RemoteFiles, []byte(strconv.FormatInt(entry.FileID, 10)))
		if err != nil {
			return nil, err
		}
		if fileBytes == nil {
			continue
		}

		var file model.RemoteFile
		if err := json.Unmarshal(fileBytes, &file); err != nil {
			return nil, err
		}

		if typeFilter != nil && file.GetFileType() != *typeFilter {
			continue
		}
		files = append(files, file)
	}

	return files, nil
}

func parseFileType(value string) (*model.FileType, error) {
	value = strings.TrimSpace(strings.ToLower(value))
	if value == "" {
		return nil, nil
	}

	switch value {
	case "image", "photo":
		t := model.Image
		return &t, nil
	case "video":
		t := model.Video
		return &t, nil
	case "live":
		t := model.LivePhoto
		return &t, nil
	default:
		return nil, fmt.Errorf("invalid type %q. allowed values: image, video, live", value)
	}
}

func formatSize(bytes int64) string {
	return utils.ByteCountDecimal(bytes)
}

func randomIndex(max int) (int, error) {
	if max <= 0 {
		return 0, fmt.Errorf("max must be positive")
	}
	n, err := rand.Int(rand.Reader, big.NewInt(int64(max)))
	if err != nil {
		return 0, err
	}
	return int(n.Int64()), nil
}
