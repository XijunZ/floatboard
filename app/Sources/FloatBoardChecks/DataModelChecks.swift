import Foundation
import FloatBoardCore

/// docs/data-model.md must name every table of the board database (as `name`), so the documented data model can
/// never fall behind the schema. The engine has the same check for its D1 tables (connectors/email/test/data-model.test.ts).
@MainActor func dataModelChecks() {
    let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = app.appendingPathComponent("Tests/Fixtures/schema-v8.json")
    let doc = app.deletingLastPathComponent().appendingPathComponent("docs/data-model.md")
    let text: String, rows: [[Any]]
    do {
        text = try String(contentsOf: doc, encoding: .utf8)
        rows = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [[Any]] ?? []
    } catch { check(false, "data_model_doc_readable: \(error)"); return }
    let tables = rows.filter { $0.first as? String == "table" }.compactMap { $0.count > 1 ? $0[1] as? String : nil }
    let missing = tables.filter { !text.contains("`\($0)`") }
    check(!tables.isEmpty && missing.isEmpty, "data_model_doc_names_every_board_table" + (missing.isEmpty ? "" : ": missing \(missing)"))
}
