DO $migration$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_name = 'ensu_chat_key'
    ) THEN
        ALTER TABLE ensu_chat_key
            RENAME TO llmchat_key;

        ALTER TABLE ensu_chat_sessions
            RENAME TO llmchat_sessions;

        ALTER TABLE ensu_chat_messages
            RENAME TO llmchat_messages;

        ALTER INDEX ensu_chat_sessions_updated_at_time_index
            RENAME TO llmchat_sessions_updated_at_time_index;

        ALTER INDEX ensu_chat_messages_updated_at_time_index
            RENAME TO llmchat_messages_updated_at_time_index;

        ALTER TABLE llmchat_key
            RENAME CONSTRAINT fk_ensu_chat_key_user_id TO fk_llmchat_key_user_id;

        ALTER TABLE llmchat_sessions
            RENAME CONSTRAINT fk_ensu_chat_key_user_id TO fk_llmchat_key_user_id;

        ALTER TABLE llmchat_messages
            RENAME CONSTRAINT fk_ensu_chat_key_user_id TO fk_llmchat_key_user_id;

        ALTER TABLE llmchat_sessions
            RENAME CONSTRAINT ensu_chat_sessions_state_constraint TO llmchat_sessions_state_constraint;

        ALTER TABLE llmchat_messages
            RENAME CONSTRAINT ensu_chat_messages_state_constraint TO llmchat_messages_state_constraint;

        ALTER TRIGGER update_ensu_chat_sessions_updated_at ON llmchat_sessions
            RENAME TO update_llmchat_sessions_updated_at;

        ALTER TRIGGER update_ensu_chat_messages_updated_at ON llmchat_messages
            RENAME TO update_llmchat_messages_updated_at;

        ALTER TRIGGER trigger_ensu_chat_key_on_sessions_updation ON llmchat_sessions
            RENAME TO trigger_llmchat_key_on_sessions_updation;

        ALTER TRIGGER trigger_ensu_chat_key_on_messages_updation ON llmchat_messages
            RENAME TO trigger_llmchat_key_on_messages_updation;

        ALTER FUNCTION fn_update_ensu_chat_key_updated_at_via_updated_at()
            RENAME TO fn_update_llmchat_key_updated_at_via_updated_at;

        CREATE OR REPLACE FUNCTION fn_update_llmchat_key_updated_at_via_updated_at() RETURNS TRIGGER AS
        $func$
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
        $func$ LANGUAGE plpgsql;
    END IF;
END;
$migration$;
