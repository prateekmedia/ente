ALTER TABLE llmchat_sessions
    ADD COLUMN IF NOT EXISTS root_session_uuid uuid,
    ADD COLUMN IF NOT EXISTS branch_from_message_uuid uuid;

UPDATE llmchat_sessions
SET root_session_uuid = session_uuid
WHERE root_session_uuid IS NULL;

ALTER TABLE llmchat_sessions
    ALTER COLUMN root_session_uuid SET NOT NULL;

ALTER TABLE llmchat_messages
    ADD COLUMN IF NOT EXISTS sender TEXT NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS attachments JSONB NOT NULL DEFAULT '[]'::jsonb;

UPDATE llmchat_messages
SET sender = ''
WHERE sender IS NULL;
