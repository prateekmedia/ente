CREATE TABLE IF NOT EXISTS llmchat_key (
    user_id       BIGINT  PRIMARY KEY  NOT NULL,
    encrypted_key TEXT NOT NULL,
    header        TEXT NOT NULL,
    created_at    BIGINT NOT NULL DEFAULT now_utc_micro_seconds(),
    updated_at    BIGINT NOT NULL DEFAULT now_utc_micro_seconds(),
    CONSTRAINT fk_llmchat_key_user_id FOREIGN KEY (user_id) REFERENCES users (
        user_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS llmchat_sessions (
    session_uuid   uuid PRIMARY KEY NOT NULL,
    user_id        BIGINT NOT NULL,
    encrypted_data TEXT,
    header         TEXT,
    is_deleted     BOOLEAN DEFAULT FALSE,
    created_at     BIGINT NOT NULL DEFAULT now_utc_micro_seconds(),
    updated_at     BIGINT NOT NULL DEFAULT now_utc_micro_seconds(),
    CONSTRAINT fk_llmchat_key_user_id FOREIGN KEY (user_id) REFERENCES llmchat_key (
        user_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS llmchat_messages (
    message_uuid        uuid PRIMARY KEY NOT NULL,
    user_id             BIGINT NOT NULL,
    session_uuid        uuid NOT NULL,
    parent_message_uuid uuid NULL,
    encrypted_data      TEXT,
    header              TEXT,
    is_deleted          BOOLEAN DEFAULT FALSE,
    created_at          BIGINT NOT NULL DEFAULT now_utc_micro_seconds(),
    updated_at          BIGINT NOT NULL DEFAULT now_utc_micro_seconds(),
    CONSTRAINT fk_llmchat_key_user_id FOREIGN KEY (user_id) REFERENCES llmchat_key (
        user_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS llmchat_sessions_updated_at_time_index ON llmchat_sessions (user_id, updated_at);
CREATE INDEX IF NOT EXISTS llmchat_messages_updated_at_time_index ON llmchat_messages (user_id, updated_at);

ALTER TABLE llmchat_sessions
    ADD CONSTRAINT llmchat_sessions_state_constraint CHECK ((is_deleted is TRUE AND encrypted_data IS NULL) or
                                                              (is_deleted is FALSE AND encrypted_data IS NOT NULL));

ALTER TABLE llmchat_messages
    ADD CONSTRAINT llmchat_messages_state_constraint CHECK ((is_deleted is TRUE AND encrypted_data IS NULL) or
                                                              (is_deleted is FALSE AND encrypted_data IS NOT NULL));

CREATE TRIGGER update_llmchat_sessions_updated_at
    BEFORE UPDATE
    ON llmchat_sessions
    FOR EACH ROW
EXECUTE PROCEDURE
    trigger_updated_at_microseconds_column();

CREATE TRIGGER update_llmchat_messages_updated_at
    BEFORE UPDATE
    ON llmchat_messages
    FOR EACH ROW
EXECUTE PROCEDURE
    trigger_updated_at_microseconds_column();

-- This function updates the llmchat_key updated_at if relevant chat entries are changed
CREATE OR REPLACE FUNCTION fn_update_llmchat_key_updated_at_via_updated_at() RETURNS TRIGGER AS
$$
BEGIN
    --
    IF (TG_OP = 'UPDATE' OR TG_OP = 'INSERT') THEN
        UPDATE llmchat_key
        SET updated_at = NEW.updated_at
        where user_id = new.user_id
          and updated_at < New.updated_at;
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_llmchat_key_on_sessions_updation
    AFTER INSERT OR UPDATE
    ON llmchat_sessions
    FOR EACH ROW
EXECUTE PROCEDURE
    fn_update_llmchat_key_updated_at_via_updated_at();

CREATE TRIGGER trigger_llmchat_key_on_messages_updation
    AFTER INSERT OR UPDATE
    ON llmchat_messages
    FOR EACH ROW
EXECUTE PROCEDURE
    fn_update_llmchat_key_updated_at_via_updated_at();
