package ensuchat

import (
	"errors"
	"net/http"
	"time"

	"github.com/ente-io/museum/ente"
	model "github.com/ente-io/museum/ente/ensuchat"
	"github.com/ente-io/museum/pkg/repo/ensuchat"
	"github.com/ente-io/museum/pkg/utils/auth"
	"github.com/ente-io/stacktrace"
	"github.com/gin-gonic/gin"
)

// Controller exposes business logic for ensu chat.
type Controller struct {
	Repo *ensuchat.Repository
}

func (c *Controller) UpsertKey(ctx *gin.Context, req model.UpsertKeyRequest) (*model.Key, error) {
	userID := auth.GetUserID(ctx.Request.Header)
	res, err := c.Repo.UpsertKey(ctx, userID, req)
	if err != nil {
		return nil, stacktrace.Propagate(err, "failed to upsert ensu chat key")
	}
	return &res, nil
}

func (c *Controller) GetKey(ctx *gin.Context) (*model.Key, error) {
	userID := auth.GetUserID(ctx.Request.Header)
	res, err := c.Repo.GetKey(ctx, userID)
	if err != nil {
		return nil, stacktrace.Propagate(err, "failed to fetch ensu chat key")
	}
	return &res, nil
}

func (c *Controller) UpsertSession(ctx *gin.Context, req model.UpsertSessionRequest) (*model.Session, error) {
	if err := c.validateKey(ctx); err != nil {
		return nil, stacktrace.Propagate(err, "failed to validateKey")
	}
	userID := auth.GetUserID(ctx.Request.Header)
	res, err := c.Repo.UpsertSession(ctx, userID, req)
	if err != nil {
		return nil, stacktrace.Propagate(err, "failed to upsert ensu chat session")
	}
	return &res, nil
}

func (c *Controller) UpsertMessage(ctx *gin.Context, req model.UpsertMessageRequest) (*model.Message, error) {
	if err := c.validateKey(ctx); err != nil {
		return nil, stacktrace.Propagate(err, "failed to validateKey")
	}
	userID := auth.GetUserID(ctx.Request.Header)
	res, err := c.Repo.UpsertMessage(ctx, userID, req)
	if err != nil {
		return nil, stacktrace.Propagate(err, "failed to upsert ensu chat message")
	}
	return &res, nil
}

func (c *Controller) DeleteSession(ctx *gin.Context, sessionUUID string) (*model.SessionTombstone, error) {
	if err := c.validateKey(ctx); err != nil {
		return nil, stacktrace.Propagate(err, "failed to validateKey")
	}
	userID := auth.GetUserID(ctx.Request.Header)
	res, err := c.Repo.DeleteSession(ctx, userID, sessionUUID)
	if err != nil {
		return nil, stacktrace.Propagate(err, "failed to delete ensu chat session")
	}
	return &res, nil
}

func (c *Controller) DeleteMessage(ctx *gin.Context, messageUUID string) (*model.MessageTombstone, error) {
	if err := c.validateKey(ctx); err != nil {
		return nil, stacktrace.Propagate(err, "failed to validateKey")
	}
	userID := auth.GetUserID(ctx.Request.Header)
	res, err := c.Repo.DeleteMessage(ctx, userID, messageUUID)
	if err != nil {
		return nil, stacktrace.Propagate(err, "failed to delete ensu chat message")
	}
	return &res, nil
}

func (c *Controller) GetDiff(ctx *gin.Context, req model.GetDiffRequest) (*model.GetDiffResponse, error) {
	if err := c.validateKey(ctx); err != nil {
		return nil, stacktrace.Propagate(err, "failed to validateKey")
	}
	userID := auth.GetUserID(ctx.Request.Header)
	remaining := int(req.Limit)

	sessions := []model.SessionDiffEntry{}
	messages := []model.MessageDiffEntry{}
	sessionTombstones := []model.SessionTombstone{}
	messageTombstones := []model.MessageTombstone{}

	if remaining > 0 {
		entries, err := c.Repo.GetSessionDiff(ctx, userID, *req.SinceTime, int16(remaining))
		if err != nil {
			return nil, stacktrace.Propagate(err, "failed to fetch ensu chat session diff")
		}
		sessions = entries
		remaining -= len(entries)
	}

	if remaining > 0 {
		entries, err := c.Repo.GetMessageDiff(ctx, userID, *req.SinceTime, int16(remaining))
		if err != nil {
			return nil, stacktrace.Propagate(err, "failed to fetch ensu chat message diff")
		}
		messages = entries
		remaining -= len(entries)
	}

	if remaining > 0 {
		entries, err := c.Repo.GetSessionTombstones(ctx, userID, *req.SinceTime, int16(remaining))
		if err != nil {
			return nil, stacktrace.Propagate(err, "failed to fetch ensu chat session tombstones")
		}
		sessionTombstones = entries
		remaining -= len(entries)
	}

	if remaining > 0 {
		entries, err := c.Repo.GetMessageTombstones(ctx, userID, *req.SinceTime, int16(remaining))
		if err != nil {
			return nil, stacktrace.Propagate(err, "failed to fetch ensu chat message tombstones")
		}
		messageTombstones = entries
	}

	timestamp := maxDiffTimestamp(sessions, messages, sessionTombstones, messageTombstones)
	if timestamp == 0 {
		timestamp = time.Now().UnixMicro()
	}

	response := model.GetDiffResponse{
		Sessions: sessions,
		Messages: messages,
		Tombstones: model.DiffTombstones{
			Sessions: sessionTombstones,
			Messages: messageTombstones,
		},
		Timestamp: timestamp,
	}
	return &response, nil
}

func (c *Controller) validateKey(ctx *gin.Context) error {
	userID := auth.GetUserID(ctx.Request.Header)
	_, err := c.Repo.GetKey(ctx, userID)
	if err != nil && errors.Is(err, &ente.ErrNotFoundError) {
		return stacktrace.Propagate(&ente.ApiError{
			Code:           ente.AuthKeyNotCreated,
			Message:        "Chat key is not created",
			HttpStatusCode: http.StatusBadRequest,
		}, "")
	}
	return err
}

func maxDiffTimestamp(
	sessions []model.SessionDiffEntry,
	messages []model.MessageDiffEntry,
	sessionTombstones []model.SessionTombstone,
	messageTombstones []model.MessageTombstone,
) int64 {
	var max int64
	for _, entry := range sessions {
		if entry.UpdatedAt > max {
			max = entry.UpdatedAt
		}
	}
	for _, entry := range messages {
		if entry.UpdatedAt > max {
			max = entry.UpdatedAt
		}
	}
	for _, entry := range sessionTombstones {
		if entry.DeletedAt > max {
			max = entry.DeletedAt
		}
	}
	for _, entry := range messageTombstones {
		if entry.DeletedAt > max {
			max = entry.DeletedAt
		}
	}
	return max
}
