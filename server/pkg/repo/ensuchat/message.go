package ensuchat

import (
	"context"
	"database/sql"
	"errors"

	"github.com/ente-io/museum/ente"
	model "github.com/ente-io/museum/ente/ensuchat"
	"github.com/ente-io/stacktrace"
	"github.com/sirupsen/logrus"
)

func (r *Repository) UpsertMessage(ctx context.Context, userID int64, req model.UpsertMessageRequest) (model.Message, error) {
	row := r.DB.QueryRowContext(ctx, `INSERT INTO ensu_chat_messages(
		message_uuid,
		user_id,
		session_uuid,
		parent_message_uuid,
		encrypted_data,
		header,
		is_deleted
	) VALUES ($1, $2, $3, $4, $5, $6, FALSE)
	ON CONFLICT (message_uuid) DO UPDATE
		SET session_uuid = EXCLUDED.session_uuid,
			parent_message_uuid = EXCLUDED.parent_message_uuid,
			encrypted_data = EXCLUDED.encrypted_data,
			header = EXCLUDED.header,
			is_deleted = FALSE
		WHERE ensu_chat_messages.user_id = EXCLUDED.user_id
	RETURNING message_uuid, user_id, session_uuid, parent_message_uuid, encrypted_data, header, is_deleted, created_at, updated_at`,
		req.MessageUUID,
		userID,
		req.SessionUUID,
		req.ParentMessageUUID,
		req.EncryptedData,
		req.Header,
	)

	var result model.Message
	var parentMessageUUID sql.NullString
	var encryptedData sql.NullString
	var header sql.NullString
	if err := row.Scan(
		&result.MessageUUID,
		&result.UserID,
		&result.SessionUUID,
		&parentMessageUUID,
		&encryptedData,
		&header,
		&result.IsDeleted,
		&result.CreatedAt,
		&result.UpdatedAt,
	); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return result, stacktrace.Propagate(&ente.ErrNotFoundError, "ensu chat message not found")
		}
		return result, stacktrace.Propagate(err, "failed to upsert ensu chat message")
	}
	if parentMessageUUID.Valid {
		result.ParentMessageUUID = &parentMessageUUID.String
	}
	if encryptedData.Valid {
		result.EncryptedData = &encryptedData.String
	}
	if header.Valid {
		result.Header = &header.String
	}
	return result, nil
}

func (r *Repository) DeleteMessage(ctx context.Context, userID int64, messageUUID string) (model.MessageTombstone, error) {
	row := r.DB.QueryRowContext(ctx, `UPDATE ensu_chat_messages
		SET is_deleted = TRUE,
			encrypted_data = NULL,
			header = NULL
		WHERE message_uuid = $1 AND user_id = $2 AND is_deleted = FALSE
		RETURNING message_uuid, updated_at`,
		messageUUID,
		userID,
	)

	var result model.MessageTombstone
	err := row.Scan(&result.MessageUUID, &result.DeletedAt)
	if err == nil {
		return result, nil
	}
	if errors.Is(err, sql.ErrNoRows) {
		row = r.DB.QueryRowContext(ctx, `SELECT message_uuid, updated_at
			FROM ensu_chat_messages
			WHERE message_uuid = $1 AND user_id = $2 AND is_deleted = TRUE`,
			messageUUID,
			userID,
		)
		err = row.Scan(&result.MessageUUID, &result.DeletedAt)
		if err == nil {
			return result, nil
		}
		if errors.Is(err, sql.ErrNoRows) {
			return result, stacktrace.Propagate(&ente.ErrNotFoundError, "ensu chat message not found")
		}
		return result, stacktrace.Propagate(err, "failed to fetch deleted ensu chat message")
	}
	return result, stacktrace.Propagate(err, "failed to delete ensu chat message")
}

func (r *Repository) GetMessageDiff(ctx context.Context, userID int64, sinceTime int64, limit int16) ([]model.MessageDiffEntry, error) {
	rows, err := r.DB.QueryContext(ctx, `SELECT message_uuid, session_uuid, parent_message_uuid, encrypted_data, header, created_at, updated_at
		FROM ensu_chat_messages
		WHERE user_id = $1 AND is_deleted = FALSE AND updated_at > $2
		ORDER BY updated_at, message_uuid
		LIMIT $3`,
		userID,
		sinceTime,
		limit,
	)
	if err != nil {
		return nil, stacktrace.Propagate(err, "failed to query ensu chat message diff")
	}
	return convertRowsToMessageDiffEntries(rows)
}

func (r *Repository) GetMessageTombstones(ctx context.Context, userID int64, sinceTime int64, limit int16) ([]model.MessageTombstone, error) {
	rows, err := r.DB.QueryContext(ctx, `SELECT message_uuid, updated_at
		FROM ensu_chat_messages
		WHERE user_id = $1 AND is_deleted = TRUE AND updated_at > $2
		ORDER BY updated_at, message_uuid
		LIMIT $3`,
		userID,
		sinceTime,
		limit,
	)
	if err != nil {
		return nil, stacktrace.Propagate(err, "failed to query ensu chat message tombstones")
	}
	return convertRowsToMessageTombstones(rows)
}

func convertRowsToMessageDiffEntries(rows *sql.Rows) ([]model.MessageDiffEntry, error) {
	defer func() {
		if err := rows.Close(); err != nil {
			logrus.Error(err)
		}
	}()

	entries := make([]model.MessageDiffEntry, 0)
	for rows.Next() {
		var entry model.MessageDiffEntry
		var parentMessageUUID sql.NullString
		if err := rows.Scan(
			&entry.MessageUUID,
			&entry.SessionUUID,
			&parentMessageUUID,
			&entry.EncryptedData,
			&entry.Header,
			&entry.CreatedAt,
			&entry.UpdatedAt,
		); err != nil {
			return nil, stacktrace.Propagate(err, "failed to scan ensu chat message diff")
		}
		if parentMessageUUID.Valid {
			entry.ParentMessageUUID = &parentMessageUUID.String
		}
		entries = append(entries, entry)
	}
	if err := rows.Err(); err != nil {
		return nil, stacktrace.Propagate(err, "failed to iterate ensu chat message diff")
	}
	return entries, nil
}

func convertRowsToMessageTombstones(rows *sql.Rows) ([]model.MessageTombstone, error) {
	defer func() {
		if err := rows.Close(); err != nil {
			logrus.Error(err)
		}
	}()

	tombstones := make([]model.MessageTombstone, 0)
	for rows.Next() {
		var entry model.MessageTombstone
		if err := rows.Scan(&entry.MessageUUID, &entry.DeletedAt); err != nil {
			return nil, stacktrace.Propagate(err, "failed to scan ensu chat message tombstone")
		}
		tombstones = append(tombstones, entry)
	}
	if err := rows.Err(); err != nil {
		return nil, stacktrace.Propagate(err, "failed to iterate ensu chat message tombstones")
	}
	return tombstones, nil
}
