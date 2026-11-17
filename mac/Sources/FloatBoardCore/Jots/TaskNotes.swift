import Foundation

/// J10 and §9: a task's notes are a jot. From 10 characters the notes are saved as a task-note jot (the task's tags, a
/// `notes-of` link made by FloatBoard); later edits from the task editor update that same jot (its history). Edits,
/// deletes and restores of the note jot reach `cards.notes` through database triggers (`v13Jots`), so the task editor and
/// the Jots tab always show one text.
public enum TaskNotes {
    /// Notes shorter than this make no jot.
    public static let threshold = 10
}

extension Store {
    /// Called by `update` (the task editor) inside its transaction with the notes before and after.
    func saveTaskNoteRow(cardID: Int64, old: String, new: String, now: Date) throws {
        guard old != new else { return }
        let jots = JotStore(store: self)
        if let note = try db.query("SELECT id, text FROM jots WHERE task_id=? AND kind='task_note' AND deleted=0 ORDER BY id DESC LIMIT 1",
                                   [cardID], { (DB.int($0, 0), DB.text($0, 1)) }).first {
            guard note.1 != new else { return }
            try db.run("INSERT INTO jot_history(jot_id, text, at) VALUES(?,?,?)", [note.0, note.1, now])
            try db.run("UPDATE jots SET text=?, updated=? WHERE id=?", [new, now, note.0])
            try linkMentionsRow(in: new, previous: note.1, from: ShortID(kind: .jot, number: note.0), now: now)
            return
        }
        guard new.trimmingCharacters(in: .whitespacesAndNewlines).count >= TaskNotes.threshold else { return }
        let task = ShortID(kind: .task, number: cardID)
        let n = try jots.addRow(new, kind: .taskNote, source: .typed, origin: "", taskID: cardID, tags: itemTags(task).all, now: now)
        try linkRow(ShortID(kind: .jot, number: n), task, kind: .notesOf, madeBy: .auto, actor: .user, now: now)
    }
}
