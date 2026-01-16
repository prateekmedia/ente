CREATE INDEX IF NOT EXISTS llmchat_sessions_state_updated_at_index
    ON llmchat_sessions (user_id, is_deleted, updated_at);

CREATE INDEX IF NOT EXISTS llmchat_messages_state_updated_at_index
    ON llmchat_messages (user_id, is_deleted, updated_at);
