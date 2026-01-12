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

func (r *Repository) UpsertSession(ctx context.Context, userID int64, req model.UpsertSessionRequest) (model.Session, error) {
	row := r.DB.QueryRowContext(ctx, `INSERT INTO ensu_chat_sessions(
		session_uuid,
		user_id,
		encrypted_data,
		header,
		is_deleted
	) VALUES ($1, $2, $3, $4, FALSE)
	ON CONFLICT (session_uuid) DO UPDATE
		SET encrypted_data = EXCLUDED.encrypted_data,
			header = EXCLUDED.header,
			is_deleted = FALSE
		WHERE ensu_chat_sessions.user_id = EXCLUDED.user_id
	RETURNING session_uuid, user_id, encrypted_data, header, is_deleted, created_at, updated_at`,
		req.SessionUUID,
		userID,
		req.EncryptedData,
		req.Header,
	)

	var result model.Session
	var encryptedData sql.NullString
	var header sql.NullString
	if err := row.Scan(
		&result.SessionUUID,
		&result.UserID,
		&encryptedData,
		&header,
		&result.IsDeleted,
		&result.CreatedAt,
		&result.UpdatedAt,
	); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return result, stacktrace.Propagate(&ente.ErrNotFoundError, "ensu chat session not found")
		}
		return result, stacktrace.Propagate(err, "failed to upsert ensu chat session")
	}
	if encryptedData.Valid {
		result.EncryptedData = &encryptedData.String
	}
	if header.Valid {
		result.Header = &header.String
	}
	return result, nil
}

func (r *Repository) DeleteSession(ctx context.Context, userID int64, sessionUUID string) (model.SessionTombstone, error) {
	row := r.DB.QueryRowContext(ctx, `UPDATE ensu_chat_sessions
		SET is_deleted = TRUE,
			encrypted_data = NULL,
			header = NULL
		WHERE session_uuid = $1 AND user_id = $2 AND is_deleted = FALSE
		RETURNING session_uuid, updated_at`,
		sessionUUID,
		userID,
	)

	var result model.SessionTombstone
	err := row.Scan(&result.SessionUUID, &result.DeletedAt)
	if err == nil {
		return result, nil
	}
	if errors.Is(err, sql.ErrNoRows) {
		row = r.DB.QueryRowContext(ctx, `SELECT session_uuid, updated_at
			FROM ensu_chat_sessions
			WHERE session_uuid = $1 AND user_id = $2 AND is_deleted = TRUE`,
			sessionUUID,
			userID,
		)
		err = row.Scan(&result.SessionUUID, &result.DeletedAt)
		if err == nil {
			return result, nil
		}
		if errors.Is(err, sql.ErrNoRows) {
			return result, stacktrace.Propagate(&ente.ErrNotFoundError, "ensu chat session not found")
		}
		return result, stacktrace.Propagate(err, "failed to fetch deleted ensu chat session")
	}
	return result, stacktrace.Propagate(err, "failed to delete ensu chat session")
}

func (r *Repository) GetSessionDiff(ctx context.Context, userID int64, sinceTime int64, limit int16) ([]model.SessionDiffEntry, error) {
	rows, err := r.DB.QueryContext(ctx, `SELECT session_uuid, encrypted_data, header, created_at, updated_at
		FROM ensu_chat_sessions
		WHERE user_id = $1 AND is_deleted = FALSE AND updated_at > $2
		ORDER BY updated_at, session_uuid
		LIMIT $3`,
		userID,
		sinceTime,
		limit,
	)
	if err != nil {
		return nil, stacktrace.Propagate(err, "failed to query ensu chat session diff")
	}
	return convertRowsToSessionDiffEntries(rows)
}

func (r *Repository) GetSessionTombstones(ctx context.Context, userID int64, sinceTime int64, limit int16) ([]model.SessionTombstone, error) {
	rows, err := r.DB.QueryContext(ctx, `SELECT session_uuid, updated_at
		FROM ensu_chat_sessions
		WHERE user_id = $1 AND is_deleted = TRUE AND updated_at > $2
		ORDER BY updated_at, session_uuid
		LIMIT $3`,
		userID,
		sinceTime,
		limit,
	)
	if err != nil {
		return nil, stacktrace.Propagate(err, "failed to query ensu chat session tombstones")
	}
	return convertRowsToSessionTombstones(rows)
}

func convertRowsToSessionDiffEntries(rows *sql.Rows) ([]model.SessionDiffEntry, error) {
	defer func() {
		if err := rows.Close(); err != nil {
			logrus.Error(err)
		}
	}()

	entries := make([]model.SessionDiffEntry, 0)
	for rows.Next() {
		var entry model.SessionDiffEntry
		if err := rows.Scan(
			&entry.SessionUUID,
			&entry.EncryptedData,
			&entry.Header,
			&entry.CreatedAt,
			&entry.UpdatedAt,
		); err != nil {
			return nil, stacktrace.Propagate(err, "failed to scan ensu chat session diff")
		}
		entries = append(entries, entry)
	}
	if err := rows.Err(); err != nil {
		return nil, stacktrace.Propagate(err, "failed to iterate ensu chat session diff")
	}
	return entries, nil
}

func convertRowsToSessionTombstones(rows *sql.Rows) ([]model.SessionTombstone, error) {
	defer func() {
		if err := rows.Close(); err != nil {
			logrus.Error(err)
		}
	}()

	tombstones := make([]model.SessionTombstone, 0)
	for rows.Next() {
		var entry model.SessionTombstone
		if err := rows.Scan(&entry.SessionUUID, &entry.DeletedAt); err != nil {
			return nil, stacktrace.Propagate(err, "failed to scan ensu chat session tombstone")
		}
		tombstones = append(tombstones, entry)
	}
	if err := rows.Err(); err != nil {
		return nil, stacktrace.Propagate(err, "failed to iterate ensu chat session tombstones")
	}
	return tombstones, nil
}
