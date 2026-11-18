import FloatBoardCore
import Foundation
import SQLite3

/// WhatsApp Desktop's own contact list on this Mac, read only (copied first, like ChatStorage): which phone number and names
/// belong to a linked id (<digits>@lid). ContactsV2.sqlite (ZWAADDRESSBOOKCONTACT) first, then LID.sqlite
/// (ZWAPHONENUMBERLIDPAIR). Missing files, tables or columns give nothing, quietly (no Activity). Nothing is sent anywhere.
public enum WhatsAppContacts {
    public static let contactsFile = "ContactsV2.sqlite", lidFile = "LID.sqlite"

    public static func resolve(_ lids: [String], folder: URL = WhatsAppLocal.folder) -> [String: ResolvedContact] {
        let wanted = Array(Set(lids.map { $0.lowercased() }.filter { $0.hasSuffix("@lid") }))
        guard !wanted.isEmpty else { return [:] }
        var out: [String: ResolvedContact] = [:]
        let marks = wanted.map { _ in "?" }.joined(separator: ",")
        if let rows = try? WhatsAppLocal.withCopy(folder, file: contactsFile, { db in // try?-ok: no contact list (or another layout) = nothing known; quiet by design
            try WhatsAppLocal.rows(db, """
                SELECT lower(ZLID), COALESCE(ZPHONENUMBER,''), COALESCE(ZFULLNAME,''), COALESCE(ZGIVENNAME,''), COALESCE(ZBUSINESSNAME,''),
                       COALESCE(ZWHATSAPPID,'') FROM ZWAADDRESSBOOKCONTACT WHERE lower(ZLID) IN (\(marks))
                """, wanted.map { .text($0) })
        }) {
            for r in rows {
                guard let lid = r[0].text else { continue }
                let phone = Handles.normalize(.phone, r[1].text ?? "")
                    ?? Handles.fromWhatsApp(r[5].text ?? "").flatMap { $0.kind == .phone ? $0.value : nil }
                let name = [r[2].text, r[3].text].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                let business = r[4].text ?? ""
                guard phone != nil || !name.isEmpty || !business.isEmpty else { continue }
                out[lid] = ResolvedContact(phone: phone, name: name, business: business)
            }
        }
        let missing = wanted.filter { out[$0]?.phone == nil }
        if !missing.isEmpty, let rows = try? WhatsAppLocal.withCopy(folder, file: lidFile, { db in // try?-ok: the fallback list may not exist; quiet by design
            try WhatsAppLocal.rows(db, "SELECT lower(ZLID), COALESCE(ZPHONENUMBER,'') FROM ZWAPHONENUMBERLIDPAIR WHERE lower(ZLID) IN (\(missing.map { _ in "?" }.joined(separator: ",")))",
                                   missing.map { .text($0) })
        }) {
            for r in rows {
                guard let lid = r[0].text, let phone = Handles.normalize(.phone, r[1].text ?? "") else { continue }
                out[lid] = ResolvedContact(phone: phone, name: out[lid]?.name ?? "", business: out[lid]?.business ?? "")
            }
        }
        return out
    }
}
