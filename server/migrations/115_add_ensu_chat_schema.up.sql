CREATE TABLE IF NOT EXISTS ensu_chat_key (
    user_id       BIGINT  PRIMARY KEY  NOT NULL,
    encrypted_key TEXT NOT NULL,
    header        TEXT NOT NULL,
    created_at    BIGINT NOT NULL DEFAULT now_utc_micro_seconds(),
    updated_at    BIGINT NOT NULL DEFAULT now_utc_micro_seconds(),
    CONSTRAINT fk_ensu_chat_key_user_id FOREIGN KEY (user_id) REFERENCES users (
        user_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS ensu_chat_sessions (
    session_uuid   uuid PRIMARY KEY NOT NULL,
    user_id        BIGINT NOT NULL,
    encrypted_data TEXT,
    header         TEXT,
    is_deleted     BOOLEAN DEFAULT FALSE,
    created_at     BIGINT NOT NULL DEFAULT now_utc_micro_seconds(),
    updated_at     BIGINT NOT NULL DEFAULT now_utc_micro_seconds(),
    CONSTRAINT fk_ensu_chat_key_user_id FOREIGN KEY (user_id) REFERENCES ensu_chat_key (
        user_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS ensu_chat_messages (
    message_uuid        uuid PRIMARY KEY NOT NULL,
    user_id             BIGINT NOT NULL,
    session_uuid        uuid NOT NULL,
    parent_message_uuid uuid NULL,
    encrypted_data      TEXT,
    header              TEXT,
    is_deleted          BOOLEAN DEFAULT FALSE,
    created_at          BIGINT NOT NULL DEFAULT now_utc_micro_seconds(),
    updated_at          BIGINT NOT NULL DEFAULT now_utc_micro_seconds(),
    CONSTRAINT fk_ensu_chat_key_user_id FOREIGN KEY (user_id) REFERENCES ensu_chat_key (
        user_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ensu_chat_sessions_updated_at_time_index ON ensu_chat_sessions (user_id, updated_at);
CREATE INDEX IF NOT EXISTS ensu_chat_messages_updated_at_time_index ON ensu_chat_messages (user_id, updated_at);

ALTER TABLE ensu_chat_sessions
    ADD CONSTRAINT ensu_chat_sessions_state_constraint CHECK ((is_deleted is TRUE AND encrypted_data IS NULL) or
                                                              (is_deleted is FALSE AND encrypted_data IS NOT NULL));

ALTER TABLE ensu_chat_messages
    ADD CONSTRAINT ensu_chat_messages_state_constraint CHECK ((is_deleted is TRUE AND encrypted_data IS NULL) or
                                                              (is_deleted is FALSE AND encrypted_data IS NOT NULL));

CREATE TRIGGER update_ensu_chat_sessions_updated_at
    BEFORE UPDATE
    ON ensu_chat_sessions
    FOR EACH ROW
EXECUTE PROCEDURE
    trigger_updated_at_microseconds_column();

CREATE TRIGGER update_ensu_chat_messages_updated_at
    BEFORE UPDATE
    ON ensu_chat_messages
    FOR EACH ROW
EXECUTE PROCEDURE
    trigger_updated_at_microseconds_column();

-- This function updates the ensu_chat_key updated_at if relevant chat entries are changed
CREATE OR REPLACE FUNCTION fn_update_ensu_chat_key_updated_at_via_updated_at() RETURNS TRIGGER AS
$$
BEGIN
    --
    IF (TG_OP = 'UPDATE' OR TG_OP = 'INSERT') THEN
        UPDATE ensu_chat_key
        SET updated_at = NEW.updated_at
        where user_id = new.user_id
          and updated_at < New.updated_at;
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_ensu_chat_key_on_sessions_updation
    AFTER INSERT OR UPDATE
    ON ensu_chat_sessions
    FOR EACH ROW
EXECUTE PROCEDURE
    fn_update_ensu_chat_key_updated_at_via_updated_at();

CREATE TRIGGER trigger_ensu_chat_key_on_messages_updation
    AFTER INSERT OR UPDATE
    ON ensu_chat_messages
    FOR EACH ROW
EXECUTE PROCEDURE
    fn_update_ensu_chat_key_updated_at_via_updated_at();
