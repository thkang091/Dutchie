import Foundation
import SwiftUI

struct Person: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var contactImage: Data?
    var isCurrentUser: Bool
    
    init(id: UUID = UUID(), name: String, contactImage: Data? = nil, isCurrentUser: Bool = false) {
        self.id = id
        self.name = name
        self.contactImage = contactImage
        self.isCurrentUser = isCurrentUser
    }
    
    var initials: String {
        let components = name.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        } else if let first = components.first {
            return String(first.prefix(1)).uppercased()
        }
        return "?"
    }
}
