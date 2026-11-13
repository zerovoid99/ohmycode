import Foundation

/// What a dragged tab carries: plain text, so no custom pasteboard type needs declaring.
/// Drops of any other text are ignored.
struct TabDragPayload: Equatable {
    static let prefix = "omc-tab:"
    let documentID: UUID
    let groupID: UUID

    var string: String { "\(Self.prefix)\(documentID.uuidString):\(groupID.uuidString)" }

    init(documentID: UUID, groupID: UUID) {
        self.documentID = documentID
        self.groupID = groupID
    }

    init?(_ string: String) {
        guard string.hasPrefix(Self.prefix) else { return nil }
        let parts = string.dropFirst(Self.prefix.count).split(separator: ":")
        guard parts.count == 2, let document = UUID(uuidString: String(parts[0])),
              let group = UUID(uuidString: String(parts[1])) else { return nil }
        self.init(documentID: document, groupID: group)
    }
}
