import Foundation

struct Group: Identifiable, Codable {
    let id: UUID
    var name: String
    var members: [Person]
    var lastUsed: Date
    
    init(id: UUID = UUID(), name: String, members: [Person], lastUsed: Date = Date()) {
        self.id = id
        self.name = name
        self.members = members
        self.lastUsed = lastUsed
    }
}
