package pkg

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/ente-io/cli/internal/api"
	eCrypto "github.com/ente-io/cli/internal/crypto"
	"github.com/ente-io/cli/pkg/model"
	"github.com/ente-io/cli/utils"
	"github.com/ente-io/cli/utils/encoding"
)

// safeMove moves a file atomically to prevent corruption.
// It first copies to a temp file in the destination directory, syncs, then renames.
// The destination file is either complete or doesn't exist - never partial.
func safeMove(source, destination string) error {
	// Try atomic rename first (works on same filesystem)
	if err := os.Rename(source, destination); err == nil {
		return nil
	}

	// Cross-device: copy to temp file in destination dir, then atomic rename
	destDir := filepath.Dir(destination)
	tempFile, err := os.CreateTemp(destDir, ".ente-tmp-*")
	if err != nil {
		return fmt.Errorf("failed to create temp file: %w", err)
	}
	tempPath := tempFile.Name()

	// Clean up temp file on any error
	success := false
	defer func() {
		if !success {
			os.Remove(tempPath)
		}
	}()

	src, err := os.Open(source)
	if err != nil {
		tempFile.Close()
		return fmt.Errorf("failed to open source: %w", err)
	}

	if _, err = io.Copy(tempFile, src); err != nil {
		src.Close()
		tempFile.Close()
		return fmt.Errorf("failed to copy: %w", err)
	}
	src.Close()

	// Sync to ensure all data is on disk before rename
	if err = tempFile.Sync(); err != nil {
		tempFile.Close()
		return fmt.Errorf("failed to sync: %w", err)
	}

	if err = tempFile.Close(); err != nil {
		return fmt.Errorf("failed to close temp file: %w", err)
	}

	// Atomic rename - this is the critical step that ensures no corruption
	if err = os.Rename(tempPath, destination); err != nil {
		return fmt.Errorf("failed to rename temp file: %w", err)
	}

	success = true
	os.Remove(source)
	return nil
}

// Base58 alphabet used by Ente (same as Bitcoin)
const base58Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

// base58Decode decodes a base58 string to bytes
func base58Decode(input string) ([]byte, error) {
	result := big.NewInt(0)
	for _, c := range input {
		charIndex := strings.IndexRune(base58Alphabet, c)
		if charIndex == -1 {
			return nil, fmt.Errorf("invalid base58 character: %c", c)
		}
		result.Mul(result, big.NewInt(58))
		result.Add(result, big.NewInt(int64(charIndex)))
	}

	decoded := result.Bytes()

	// Add leading zeros for each leading '1' in input
	for i := 0; i < len(input) && input[i] == '1'; i++ {
		decoded = append([]byte{0}, decoded...)
	}

	return decoded, nil
}

// ParsePublicAlbumURL extracts accessToken and collectionKey from a public album URL
// URL format: https://albums.ente.io/?t=ACCESS_TOKEN#COLLECTION_KEY_BASE58
func ParsePublicAlbumURL(albumURL string) (accessToken string, collectionKey []byte, err error) {
	parsed, err := url.Parse(albumURL)
	if err != nil {
		return "", nil, fmt.Errorf("invalid URL: %w", err)
	}

	// Get access token from query parameter 't'
	accessToken = parsed.Query().Get("t")
	if accessToken == "" {
		return "", nil, fmt.Errorf("missing access token (t parameter) in URL")
	}

	// Get collection key from URL fragment (after #)
	fragment := parsed.Fragment
	if fragment == "" {
		return "", nil, fmt.Errorf("missing collection key (URL fragment) in URL")
	}

	// Remove any suffix after hyphen (e.g., #KEY-suffix)
	if idx := strings.Index(fragment, "-"); idx != -1 {
		fragment = fragment[:idx]
	}

	// Decode collection key - could be base58 (short) or hex (long)
	if len(fragment) < 50 {
		// Base58 encoded
		collectionKey, err = base58Decode(fragment)
		if err != nil {
			return "", nil, fmt.Errorf("failed to decode base58 collection key: %w", err)
		}
	} else {
		// Hex encoded (legacy)
		collectionKey, err = hexDecode(fragment)
		if err != nil {
			return "", nil, fmt.Errorf("failed to decode hex collection key: %w", err)
		}
	}

	return accessToken, collectionKey, nil
}

// hexDecode decodes a hex string to bytes
func hexDecode(s string) ([]byte, error) {
	if len(s)%2 != 0 {
		return nil, fmt.Errorf("hex string has odd length")
	}
	result := make([]byte, len(s)/2)
	for i := 0; i < len(s); i += 2 {
		var b byte
		_, err := fmt.Sscanf(s[i:i+2], "%02x", &b)
		if err != nil {
			return nil, err
		}
		result[i/2] = b
	}
	return result, nil
}

// isFilePath checks if the path looks like a file (has an extension)
func isFilePath(path string) bool {
	ext := filepath.Ext(path)
	return ext != "" && len(ext) <= 5 // reasonable extension length
}

// DownloadRandomFromPublicAlbum downloads a random file from a public album link
func (c *ClICtrl) DownloadRandomFromPublicAlbum(albumURL, outputPath, fileType, password string) error {
	if outputPath == "" {
		outputPath = "."
	}
	if strings.Contains(outputPath, "..") {
		return fmt.Errorf("output path cannot contain '..'")
	}
	outputPath = filepath.Clean(outputPath)

	// Check if output is a file path or directory
	outputIsFile := isFilePath(outputPath)
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

	// Parse the public album URL
	accessToken, collectionKeyBytes, err := ParsePublicAlbumURL(albumURL)
	if err != nil {
		return err
	}

	// Set up context with app=photos for API calls
	ctx := context.WithValue(context.Background(), "app", "photos")
	creds := api.PublicAlbumCredentials{
		AccessToken: accessToken,
	}

	// Fetch collection info
	log.Printf("Fetching public album info...")
	collectionInfo, err := c.Client.GetPublicCollectionInfo(ctx, creds)
	if err != nil {
		return fmt.Errorf("failed to fetch public album info: %w", err)
	}

	// Check if password protected
	collection := collectionInfo.Collection
	if len(collection.PublicURLs) > 0 {
		publicURL := collection.PublicURLs[0]
		if publicURL.PasswordEnabled {
			if password == "" {
				return fmt.Errorf("this album is password protected, use --password flag")
			}
			// Verify password and get JWT
			jwt, err := c.verifyPublicAlbumPassword(ctx, accessToken, password, publicURL)
			if err != nil {
				return fmt.Errorf("password verification failed: %w", err)
			}
			creds.AccessTokenJWT = jwt
		}
	}

	// Decrypt collection name
	albumName, err := decryptCollectionName(collection, collectionKeyBytes)
	if err != nil {
		albumName = fmt.Sprintf("Album-%d", collection.ID)
		log.Printf("Warning: could not decrypt album name: %v", err)
	}
	log.Printf("Album: %s", albumName)

	// Fetch files
	log.Printf("Fetching files...")
	files, err := c.fetchPublicAlbumFiles(ctx, creds, collectionKeyBytes)
	if err != nil {
		return fmt.Errorf("failed to fetch files: %w", err)
	}

	if len(files) == 0 {
		return fmt.Errorf("no files found in this public album")
	}

	// Filter by type if specified
	var candidates []model.RemoteFile
	for _, f := range files {
		if typeFilter != nil && f.GetFileType() != *typeFilter {
			continue
		}
		candidates = append(candidates, f)
	}

	if len(candidates) == 0 {
		return fmt.Errorf("no files found matching the specified criteria")
	}

	log.Printf("Found %d files, selecting random...", len(candidates))

	// Pick random file
	index, err := publicRandomIndex(len(candidates))
	if err != nil {
		return err
	}
	chosen := candidates[index]

	if chosen.Info.FileSize > 100*1024*1024 {
		log.Printf("Warning: selected file is large (%s)", utils.ByteCountDecimal(chosen.Info.FileSize))
	}

	// Download and decrypt the file
	log.Printf("Downloading %s...", chosen.GetTitle())
	decryptedPath, err := c.downloadAndDecryptPublicFile(ctx, creds, chosen, collectionKeyBytes)
	if err != nil {
		return err
	}
	defer func() {
		_ = os.Remove(decryptedPath)
	}()

	fileName := filepath.Base(strings.TrimSpace(chosen.GetTitle()))
	if fileName == "" {
		fileName = fmt.Sprintf("%d", chosen.ID)
	}

	if chosen.IsLivePhoto() {
		imagePath, videoPath, err := UnpackLive(decryptedPath)
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
		log.Printf("Downloaded live photo from public album to %s", outputPath)
		return nil
	}

	var dest string
	if outputIsFile {
		dest = outputPath
	} else {
		dest = filepath.Join(outputPath, fileName)
	}
	if err := safeMove(decryptedPath, dest); err != nil {
		return err
	}

	log.Printf("Downloaded %s from public album to %s", fileName, dest)
	return nil
}

func (c *ClICtrl) verifyPublicAlbumPassword(ctx context.Context, accessToken, password string, publicURL api.PublicURL) (string, error) {
	if publicURL.Nonce == nil || publicURL.MemLimit == nil || publicURL.OpsLimit == nil {
		return "", fmt.Errorf("missing password parameters in public URL")
	}

	// Derive password hash using Argon2
	passHash, err := eCrypto.DeriveArgonKey(password, *publicURL.Nonce, int(*publicURL.MemLimit), int(*publicURL.OpsLimit))
	if err != nil {
		return "", fmt.Errorf("failed to derive password hash: %w", err)
	}

	resp, err := c.Client.VerifyPublicAlbumPassword(ctx, accessToken, base64.StdEncoding.EncodeToString(passHash))
	if err != nil {
		return "", err
	}
	return resp.JWTToken, nil
}

func decryptCollectionName(collection api.Collection, collectionKey []byte) (string, error) {
	if collection.EncryptedName != "" && collection.NameDecryptionNonce != "" {
		decrypted, err := eCrypto.SecretBoxOpenBase64(collection.EncryptedName, collection.NameDecryptionNonce, collectionKey)
		if err != nil {
			return "", err
		}
		return string(decrypted), nil
	}
	if collection.Name != "" {
		return collection.Name, nil
	}
	return "", fmt.Errorf("no name available")
}

func (c *ClICtrl) fetchPublicAlbumFiles(ctx context.Context, creds api.PublicAlbumCredentials, collectionKey []byte) ([]model.RemoteFile, error) {
	var allFiles []model.RemoteFile
	var sinceTime int64 = 0

	for {
		diff, err := c.Client.GetPublicCollectionDiff(ctx, creds, sinceTime)
		if err != nil {
			return nil, err
		}

		for _, file := range diff.Diff {
			if file.IsRemovedFromAlbum() {
				continue
			}
			if file.UpdationTime > sinceTime {
				sinceTime = file.UpdationTime
			}

			remoteFile, err := decryptPublicFile(file, collectionKey)
			if err != nil {
				log.Printf("Warning: failed to decrypt file %d: %v", file.ID, err)
				continue
			}
			allFiles = append(allFiles, *remoteFile)
		}

		if !diff.HasMore {
			break
		}
	}

	return allFiles, nil
}

func decryptPublicFile(file api.File, collectionKey []byte) (*model.RemoteFile, error) {
	// Decrypt file key using collection key
	fileKey, err := eCrypto.SecretBoxOpen(
		encoding.DecodeBase64(file.EncryptedKey),
		encoding.DecodeBase64(file.KeyDecryptionNonce),
		collectionKey)
	if err != nil {
		return nil, fmt.Errorf("failed to decrypt file key: %w", err)
	}

	var remoteFile model.RemoteFile
	remoteFile.ID = file.ID
	remoteFile.OwnerID = file.OwnerID
	remoteFile.LastUpdateTime = file.UpdationTime
	remoteFile.Key = *model.MakeEncString(fileKey, collectionKey) // Store with collection key as device key equivalent
	remoteFile.FileNonce = file.File.DecryptionHeader
	remoteFile.ThumbnailNonce = file.Thumbnail.DecryptionHeader

	if file.Info != nil {
		remoteFile.Info = model.Info{
			FileSize:      file.Info.FileSize,
			ThumbnailSize: file.Info.ThumbnailSize,
		}
	}

	// Decrypt metadata
	if file.Metadata.DecryptionHeader != "" {
		_, metadataBytes, err := eCrypto.DecryptChaChaBase64(file.Metadata.EncryptedData, fileKey, file.Metadata.DecryptionHeader)
		if err != nil {
			return nil, fmt.Errorf("failed to decrypt metadata: %w", err)
		}
		if err := json.Unmarshal(metadataBytes, &remoteFile.Metadata); err != nil {
			return nil, fmt.Errorf("failed to unmarshal metadata: %w", err)
		}
	}

	// Decrypt public magic metadata if present
	if file.PubicMagicMetadata != nil {
		_, pubMetaBytes, err := eCrypto.DecryptChaChaBase64(file.PubicMagicMetadata.Data, fileKey, file.PubicMagicMetadata.Header)
		if err == nil {
			_ = json.Unmarshal(pubMetaBytes, &remoteFile.PublicMetadata)
		}
	}

	return &remoteFile, nil
}

func (c *ClICtrl) downloadAndDecryptPublicFile(ctx context.Context, creds api.PublicAlbumCredentials, file model.RemoteFile, collectionKey []byte) (string, error) {
	// Create temp file for download
	downloadPath := fmt.Sprintf("%s/%d.encrypted", c.tempFolder, file.ID)
	decryptedPath := fmt.Sprintf("%s/%d.decrypted", c.tempFolder, file.ID)

	// Download the encrypted file
	err := c.Client.DownloadPublicFile(ctx, creds, file.ID, downloadPath)
	if err != nil {
		return "", fmt.Errorf("failed to download file: %w", err)
	}

	// Decrypt the file - need to get the actual file key
	fileKey := file.Key.MustDecrypt(collectionKey)

	err = eCrypto.DecryptFile(downloadPath, decryptedPath, fileKey, encoding.DecodeBase64(file.FileNonce))
	if err != nil {
		os.Remove(downloadPath)
		return "", fmt.Errorf("failed to decrypt file: %w", err)
	}

	os.Remove(downloadPath)
	return decryptedPath, nil
}

func publicRandomIndex(max int) (int, error) {
	if max <= 0 {
		return 0, fmt.Errorf("max must be positive")
	}
	n, err := rand.Int(rand.Reader, big.NewInt(int64(max)))
	if err != nil {
		return 0, err
	}
	return int(n.Int64()), nil
}
