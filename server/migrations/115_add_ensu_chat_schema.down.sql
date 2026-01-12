DROP TRIGGER IF EXISTS trigger_ensu_chat_key_on_messages_updation ON ensu_chat_messages;
DROP TRIGGER IF EXISTS trigger_ensu_chat_key_on_sessions_updation ON ensu_chat_sessions;
DROP TRIGGER IF EXISTS update_ensu_chat_messages_updated_at ON ensu_chat_messages;
DROP TRIGGER IF EXISTS update_ensu_chat_sessions_updated_at ON ensu_chat_sessions;

DROP INDEX IF EXISTS ensu_chat_messages_updated_at_time_index;
DROP INDEX IF EXISTS ensu_chat_sessions_updated_at_time_index;
DROP INDEX IF EXISTS ensu_chat_messages_state_constraint;
DROP INDEX IF EXISTS ensu_chat_sessions_state_constraint;

DROP TABLE IF EXISTS ensu_chat_messages;
DROP TABLE IF EXISTS ensu_chat_sessions;
DROP TABLE IF EXISTS ensu_chat_key;

DROP FUNCTION IF EXISTS fn_update_ensu_chat_key_updated_at_via_updated_at();
