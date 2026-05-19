// Purpose: Defines the persisted clipboard history record for text and disk-backed image entries.

import Foundation

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var imageData: Data?
    var imageFileName: String?
    var imageFingerprint: String?
    var sourceApplicationName: String?
    var createdAt: Date
    var updatedAt: Date

    var isImage: Bool {
        imageData != nil || imageFileName != nil
    }

    init(
        id: UUID = UUID(),
        text: String,
        imageData: Data? = nil,
        imageFileName: String? = nil,
        imageFingerprint: String? = nil,
        sourceApplicationName: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.imageData = imageData
        self.imageFileName = imageFileName
        self.imageFingerprint = imageFingerprint
        self.sourceApplicationName = sourceApplicationName
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}
