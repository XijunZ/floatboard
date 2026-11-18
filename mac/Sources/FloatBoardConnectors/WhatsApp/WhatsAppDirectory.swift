import FloatBoardCore
import Foundation

/// For Bulk add: WhatsApp Desktop's one-to-one chats (who, how many messages, the last one's date; never any text) and its
/// own contact list (names, numbers, linked ids), read from copies like every WhatsApp read. Safe off the main thread.
public enum WhatsAppDirectory {
    public struct Listing: Sendable { public let sessions: [WASession]; public let contacts: [WAContact] }

    public static func read(folder: URL = WhatsAppLocal.folder) throws -> Listing {
        let sessions = try WhatsAppLocal.withCopy(folder) { db in
            try WhatsAppLocal.rows(db, """
                SELECT s.ZCONTACTJID, COALESCE(s.ZPARTNERNAME,''), count(m.Z_PK), max(m.ZMESSAGEDATE)
                FROM ZWACHATSESSION s LEFT JOIN ZWAMESSAGE m ON m.ZCHATSESSION = s.Z_PK AND COALESCE(m.ZMESSAGETYPE, 0) NOT IN (6, 10, 14)
                WHERE s.ZSESSIONTYPE = 0 AND s.ZCONTACTJID IS NOT NULL AND s.ZCONTACTJID NOT LIKE '%status' AND s.ZCONTACTJID NOT LIKE '%@broadcast'
                  AND s.ZCONTACTJID NOT LIKE '%@newsletter' AND s.ZCONTACTJID NOT LIKE '%@g.us' AND COALESCE(s.ZREMOVED,0)=0
                GROUP BY s.Z_PK
                """, [])
        }.compactMap { r -> WASession? in
            guard let jid = r[0].text else { return nil }
            let last = r[3].double.map { Date(timeIntervalSince1970: $0 + WhatsAppLocal.appleEpoch) }
            return WASession(jid: jid, name: r[1].text ?? "", messages: Int(r[2].double ?? 0), last: last)
        }
        let contacts = ((try? WhatsAppLocal.withCopy(folder, file: WhatsAppContacts.contactsFile) { db in // try?-ok: no contact list = chats only; quiet by design
            try WhatsAppLocal.rows(db, """
                SELECT COALESCE(ZLID,''), COALESCE(ZPHONENUMBER,''), COALESCE(ZFULLNAME,''), COALESCE(ZGIVENNAME,''), COALESCE(ZWHATSAPPID,'')
                FROM ZWAADDRESSBOOKCONTACT
                """, [])
        }) ?? []).compactMap { r -> WAContact? in
            let lid = (r[0].text ?? "").lowercased()
            let phone = Handles.normalize(.phone, r[1].text ?? "") ?? Handles.fromWhatsApp(r[4].text ?? "").flatMap { $0.kind == .phone ? $0.value : nil }
            let name = [r[2].text, r[3].text].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            guard phone != nil || lid.hasSuffix("@lid") else { return nil }
            return WAContact(lid: lid.hasSuffix("@lid") ? lid : nil, phone: phone, name: name)
        }
        return Listing(sessions: sessions, contacts: contacts)
    }
}
