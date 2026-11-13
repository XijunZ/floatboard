-- Muted chats are screened too, under a stricter rule (src/skills/chat-triage.md, "Muted chats").
ALTER TABLE chat_rows ADD COLUMN muted INTEGER NOT NULL DEFAULT 0;
