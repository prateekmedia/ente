package collections

import (
	"context"
	"fmt"
	"github.com/ente-io/museum/pkg/controller"
	"github.com/ente-io/museum/pkg/controller/access"
	"github.com/ente-io/museum/pkg/controller/email"
	"github.com/ente-io/museum/pkg/controller/public"
	"github.com/ente-io/museum/pkg/repo/cast"
	"github.com/ente-io/museum/pkg/utils/array"
	"github.com/ente-io/museum/pkg/utils/auth"
	"github.com/gin-gonic/gin"

	"github.com/ente-io/museum/ente"
	"github.com/ente-io/museum/pkg/repo"
	"github.com/ente-io/museum/pkg/utils/time"
	"github.com/ente-io/stacktrace"
	log "github.com/sirupsen/logrus"
)

const (
	CollectionDiffLimit = 2500
)

// CollectionController encapsulates logic that deals with collections
type CollectionController struct {
	CollectionLinkCtrl *public.CollectionLinkController
	EmailCtrl          *email.EmailNotificationController
	AccessCtrl         access.Controller
	BillingCtrl        *controller.BillingController
	CollectionRepo     *repo.CollectionRepository
	UserRepo           *repo.UserRepository
	FileRepo           *repo.FileRepository
	QueueRepo          *repo.QueueRepository
	CastRepo           *cast.Repository
	TaskRepo           *repo.TaskLockRepository
}

// Create creates a collection
func (c *CollectionController) Create(collection ente.Collection, ownerID int64) (ente.Collection, error) {
	// The key attribute check is to ensure that user does not end up uploading any files before actually setting the key attributes.
	if _, keyErr := c.UserRepo.GetKeyAttributes(ownerID); keyErr != nil {
		return ente.Collection{}, stacktrace.Propagate(keyErr, "Unable to get keyAttributes")
	}
	collectionType := collection.Type
	collection.Owner.ID = ownerID
	collection.UpdationTime = time.Microseconds()
	// [20th Dec 2022] Patch on server side untill majority of the existing mobile clients upgrade to a version higher > 0.7.0
	// https://github.com/ente-io/photos-app/pull/725
	if collection.Type == "CollectionType.album" {
		collection.Type = "album"
	}
	if !array.StringInList(collection.Type, ente.ValidCollectionTypes) {
		return ente.Collection{}, stacktrace.Propagate(fmt.Errorf("unexpected collection type %s", collection.Type), "")
	}
	collection, err := c.CollectionRepo.Create(collection)
	if err != nil {
		if err == ente.ErrUncategorizeCollectionAlreadyExists || err == ente.ErrFavoriteCollectionAlreadyExist {
			dbCollection, err := c.CollectionRepo.GetCollectionByType(ownerID, collectionType)
			if err != nil {
				return ente.Collection{}, stacktrace.Propagate(err, "")
			}
			if dbCollection.IsDeleted {
				return ente.Collection{}, stacktrace.Propagate(fmt.Errorf("special collection of type : %s is deleted", collectionType), "")
			}
			return dbCollection, nil
		}
		return ente.Collection{}, stacktrace.Propagate(err, "")
	}
	return collection, nil
}

// GetCollection returns the collection for given collectionID
func (c *CollectionController) GetCollection(ctx *gin.Context, userID int64, cID int64) (ente.Collection, error) {
	resp, err := c.AccessCtrl.GetCollection(ctx, &access.GetCollectionParams{
		CollectionID:   cID,
		ActorUserID:    userID,
		IncludeDeleted: true,
	})
	if err != nil {
		return ente.Collection{}, stacktrace.Propagate(err, "")
	}
	return resp.Collection, nil
}

func (c *CollectionController) GetFile(ctx *gin.Context, collectionID int64, fileID int64) (*ente.File, error) {
	userID := auth.GetUserID(ctx.Request.Header)
	files, err := c.CollectionRepo.GetFile(collectionID, fileID)
	if err != nil {
		return nil, stacktrace.Propagate(err, "")
	}
	if len(files) == 0 {
		return nil, stacktrace.Propagate(&ente.ErrFileNotFoundInAlbum, "")
	}

	file := files[0]
	if file.OwnerID != userID {
		cIDs, err := c.CollectionRepo.GetCollectionIDsSharedWithUser(userID)
		if err != nil {
			return nil, stacktrace.Propagate(err, "")
		}
		if !array.Int64InList(collectionID, cIDs) {
			return nil, stacktrace.Propagate(ente.ErrPermissionDenied, "")
		}
	}
	if file.IsDeleted {
		return nil, stacktrace.Propagate(&ente.ErrFileNotFoundInAlbum, "")
	}
	return &file, nil
}

// TrashV3 deletes a given collection and based on user input (TrashCollectionV3Request.KeepFiles as FALSE) , it will move all files present in the underlying collection
// to trash.
func (c *CollectionController) TrashV3(ctx *gin.Context, req ente.TrashCollectionV3Request) error {
	if req.KeepFiles == nil {
		return ente.ErrBadRequest
	}
	userID := auth.GetUserID(ctx.Request.Header)
	cID := req.CollectionID
	resp, err := c.AccessCtrl.GetCollection(ctx, &access.GetCollectionParams{
		CollectionID:   cID,
		ActorUserID:    userID,
		IncludeDeleted: true,
		VerifyOwner:    true,
	})
	if err != nil {
		return stacktrace.Propagate(err, "")
	}
	if !resp.Collection.AllowDelete() {
		return stacktrace.Propagate(ente.ErrBadRequest, fmt.Sprintf("deleting albums of type %s is not allowed", resp.Collection.Type))
	}
	if resp.Collection.IsDeleted {
		log.WithFields(log.Fields{
			"c_id":    cID,
			"user_id": userID,
		}).Warning("Collection is already deleted")
		return nil
	}

	if *req.KeepFiles {
		// Verify that all files from this particular collections have been removed.
		count, err := c.CollectionRepo.GetCollectionsFilesCount(cID)
		if err != nil {
			return stacktrace.Propagate(err, "")
		}
		if count != 0 {
			return stacktrace.Propagate(&ente.ErrCollectionNotEmpty, fmt.Sprintf("Collection file count %d", count))
		}

	}
	err = c.CollectionLinkCtrl.Disable(ctx, cID)
	if err != nil {
		return stacktrace.Propagate(err, "failed to disabled public share url")
	}
	err = c.CastRepo.RevokeTokenForCollection(ctx, cID)
	if err != nil {
		return stacktrace.Propagate(err, "failed to revoke cast token")
	}
	// Continue with current delete flow till. This disables sharing for this collection and then queue it up for deletion
	err = c.CollectionRepo.ScheduleDelete(cID)
	if err != nil {
		return stacktrace.Propagate(err, "")
	}
	return nil
}

// Rename updates the collection's name
func (c *CollectionController) Rename(userID int64, cID int64, encryptedName string, nameDecryptionNonce string) error {
	if err := c.verifyOwnership(cID, userID); err != nil {
		return stacktrace.Propagate(err, "")
	}
	err := c.CollectionRepo.Rename(cID, encryptedName, nameDecryptionNonce)
	if err != nil {
		return stacktrace.Propagate(err, "")
	}
	return nil
}

// UpdateMagicMetadata updates the magic metadata for given collection
func (c *CollectionController) UpdateMagicMetadata(ctx *gin.Context, request ente.UpdateCollectionMagicMetadata, isPublicMetadata bool) error {
	userID := auth.GetUserID(ctx.Request.Header)
	if err := c.verifyOwnership(request.ID, userID); err != nil {
		return stacktrace.Propagate(err, "")
	}
	// todo: verify version mismatch later. We are not planning to resync collection on clients,
	// so ignore that check until then. Ideally, after file size info sync, we should enable
	err := c.CollectionRepo.UpdateMagicMetadata(ctx, request.ID, request.MagicMetadata, isPublicMetadata)
	if err != nil {
		return stacktrace.Propagate(err, "")
	}
	return nil
}

func (c *CollectionController) HandleAccountDeletion(ctx context.Context, userID int64, logger *log.Entry) error {
	logger.Info("disabling shared collections with or by the user")
	sharedCollections, err := c.CollectionRepo.GetAllSharedCollections(ctx, userID)
	if err != nil {
		return stacktrace.Propagate(err, "")
	}
	logger.Info(fmt.Sprintf("shared collections count: %d", len(sharedCollections)))
	for _, shareCollection := range sharedCollections {
		logger.WithField("shared_collection", shareCollection).Info("disable shared collection")
		err = c.CollectionRepo.UnShare(shareCollection.CollectionID, shareCollection.ToUserID)
		if err != nil {
			return stacktrace.Propagate(err, "")
		}
	}
	err = c.CastRepo.RevokeTokenForUser(ctx, userID)
	if err != nil {
		return stacktrace.Propagate(err, "failed to revoke cast token for user")
	}
	err = c.CollectionLinkCtrl.HandleAccountDeletion(ctx, userID, logger)
	return stacktrace.Propagate(err, "")
}

// Verify that user owns the collection
func (c *CollectionController) verifyOwnership(cID int64, userID int64) error {
	collection, err := c.CollectionRepo.Get(cID)
	if err != nil {
		return stacktrace.Propagate(err, "")
	}
	if userID != collection.Owner.ID {
		return stacktrace.Propagate(ente.ErrPermissionDenied, "")
	}
	return nil
}

// SetParent sets the parent collection for nested collections
func (c *CollectionController) SetParent(ctx context.Context, userID int64, collectionID int64, newParentID *int64) error {
	// Verify ownership of the collection being moved
	if err := c.verifyOwnership(collectionID, userID); err != nil {
		return stacktrace.Propagate(err, "User does not own collection")
	}
	
	// If setting a parent, verify ownership of parent and prevent circular references
	if newParentID != nil {
		if err := c.verifyOwnership(*newParentID, userID); err != nil {
			return stacktrace.Propagate(err, "User does not own parent collection")
		}
		
		// Check for circular reference
		if err := c.checkCircularReference(collectionID, *newParentID); err != nil {
			return stacktrace.Propagate(err, "Would create circular reference")
		}
	}
	
	// Update the parent collection
	if err := c.CollectionRepo.SetParent(ctx, collectionID, newParentID); err != nil {
		return stacktrace.Propagate(err, "Failed to set parent collection")
	}
	
	// Update hierarchy paths
	if err := c.updateHierarchyPaths(ctx, collectionID); err != nil {
		return stacktrace.Propagate(err, "Failed to update hierarchy paths")
	}
	
	return nil
}

// ShareWithScope shares a collection with specific scope
func (c *CollectionController) ShareWithScope(ctx context.Context, userID int64, collectionID int64, request ente.ShareScopeRequest) (map[string]interface{}, error) {
	// Verify ownership
	if err := c.verifyOwnership(collectionID, userID); err != nil {
		return nil, stacktrace.Propagate(err, "User does not own collection")
	}
	
	// Validate scope
	if request.Scope != "direct_only" && request.Scope != "include_sub_collections" {
		return nil, stacktrace.Propagate(ente.ErrBadRequest, "Invalid scope value")
	}
	
	sharedCount := 0
	subCollectionsCount := 0
	
	// Share with each recipient
	for _, recipientID := range request.Recipients {
		if err := c.CollectionRepo.ShareWithScope(ctx, collectionID, userID, recipientID, request.EncryptedKey, request.Scope); err != nil {
			return nil, stacktrace.Propagate(err, "Failed to share collection")
		}
		sharedCount++
	}
	
	// If hierarchical sharing, count sub-collections
	if request.Scope == "include_sub_collections" {
		if count, err := c.CollectionRepo.GetSubCollectionCount(ctx, collectionID); err == nil {
			subCollectionsCount = count
		}
	}
	
	return map[string]interface{}{
		"success":               true,
		"shared_count":          sharedCount,
		"sub_collections_count": subCollectionsCount,
	}, nil
}

// BackupWithScope initiates backup with hierarchical scope
func (c *CollectionController) BackupWithScope(ctx context.Context, userID int64, collectionID int64, request ente.BackupScopeRequest) (map[string]interface{}, error) {
	// Verify ownership
	if err := c.verifyOwnership(collectionID, userID); err != nil {
		return nil, stacktrace.Propagate(err, "User does not own collection")
	}
	
	// Validate scope
	if request.Scope != "direct_only" && request.Scope != "include_sub_collections" {
		return nil, stacktrace.Propagate(ente.ErrBadRequest, "Invalid scope value")
	}
	
	// Get file count based on scope
	var fileCount int
	var err error
	
	if request.Scope == "direct_only" {
		fileCount, err = c.CollectionRepo.GetFileCount(ctx, collectionID)
	} else {
		fileCount, err = c.CollectionRepo.GetHierarchicalFileCount(ctx, collectionID, request.ExcludedSubCollections)
	}
	
	if err != nil {
		return nil, stacktrace.Propagate(err, "Failed to get file count")
	}
	
	// Generate backup job ID
	backupJobID := fmt.Sprintf("backup_%d_%d", collectionID, time.Microseconds())
	
	return map[string]interface{}{
		"backup_job_id": backupJobID,
		"files_count":   fileCount,
	}, nil
}

// GetHierarchy returns the collection hierarchy for a user
func (c *CollectionController) GetHierarchy(ctx context.Context, userID int64) ([]ente.Collection, error) {
	collections, err := c.CollectionRepo.GetCollectionsOwnedByUserV2(userID, 0, ente.Photos, nil)
	if err != nil {
		return nil, stacktrace.Propagate(err, "Failed to get collections")
	}
	
	// Build hierarchy structure
	hierarchy := c.buildHierarchy(collections)
	return hierarchy, nil
}

// SearchCollections searches for collections with hierarchy scope
func (c *CollectionController) SearchCollections(ctx context.Context, userID int64, query string, scope string, collectionID *int64) ([]map[string]interface{}, error) {
	var results []map[string]interface{}
	
	// Get collections based on scope
	var collections []ente.Collection
	var err error
	
	if scope == "current_folder" && collectionID != nil {
		collections, err = c.CollectionRepo.SearchInCollection(ctx, userID, *collectionID, query)
	} else {
		collections, err = c.CollectionRepo.SearchCollections(ctx, userID, query)
	}
	
	if err != nil {
		return nil, stacktrace.Propagate(err, "Failed to search collections")
	}
	
	// Format results
	for _, collection := range collections {
		photoCount, _ := c.CollectionRepo.GetFileCount(ctx, collection.ID)
		path := ""
		if collection.HierarchyPath != nil {
			path = *collection.HierarchyPath
		}
		
		result := map[string]interface{}{
			"collection_id": collection.ID,
			"name":          collection.Name,
			"path":          path,
			"photo_count":   photoCount,
		}
		results = append(results, result)
	}
	
	return results, nil
}

// Helper methods
func (c *CollectionController) checkCircularReference(collectionID int64, parentID int64) error {
	// Check if parentID is a descendant of collectionID
	ancestors, err := c.CollectionRepo.GetAncestors(collectionID)
	if err != nil {
		return stacktrace.Propagate(err, "Failed to check ancestors")
	}
	
	for _, ancestor := range ancestors {
		if ancestor == parentID {
			return stacktrace.Propagate(ente.ErrBadRequest, "Circular reference detected")
		}
	}
	
	return nil
}

func (c *CollectionController) updateHierarchyPaths(ctx context.Context, collectionID int64) error {
	// Get all descendants and update their hierarchy paths
	descendants, err := c.CollectionRepo.GetDescendants(ctx, collectionID)
	if err != nil {
		return stacktrace.Propagate(err, "Failed to get descendants")
	}
	
	for _, descendant := range descendants {
		path, err := c.CollectionRepo.BuildHierarchyPath(ctx, descendant)
		if err != nil {
			continue // Skip on error but don't fail the whole operation
		}
		c.CollectionRepo.UpdateHierarchyPath(ctx, descendant, path)
	}
	
	return nil
}

func (c *CollectionController) buildHierarchy(collections []ente.Collection) []ente.Collection {
	// Simple hierarchy builder - can be enhanced later
	rootCollections := make([]ente.Collection, 0)
	
	for _, collection := range collections {
		if collection.ParentID == nil {
			rootCollections = append(rootCollections, collection)
		}
	}
	
	return rootCollections
}
