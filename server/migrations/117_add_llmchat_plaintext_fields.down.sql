ALTER TABLE llmchat_messages
    DROP COLUMN IF EXISTS attachments,
    DROP COLUMN IF EXISTS sender;

ALTER TABLE llmchat_sessions
    DROP COLUMN IF EXISTS branch_from_message_uuid,
    DROP COLUMN IF EXISTS root_session_uuid;
