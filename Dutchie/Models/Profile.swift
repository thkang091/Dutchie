import Foundation
import SwiftUI

struct Profile: Codable, Identifiable {
    let id: UUID
    var name: String
    var phoneNumber: String
    var paymentMethods: [PaymentMethod]
    var avatarImage: Data?
    
    init(id: UUID = UUID(), name: String = "", phoneNumber: String = "", paymentMethods: [PaymentMethod] = [], avatarImage: Data? = nil) {
        self.id = id
        self.name = name
        self.phoneNumber = phoneNumber
        self.paymentMethods = paymentMethods
        self.avatarImage = avatarImage
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

struct PaymentMethod: Codable, Identifiable {
    let id: UUID
    var type: PaymentType
    var value: String
    var includeWhenSharing: Bool
    
    init(id: UUID = UUID(), type: PaymentType, value: String = "", includeWhenSharing: Bool = true) {
        self.id = id
        self.type = type
        self.value = value
        self.includeWhenSharing = includeWhenSharing
    }
}

enum PaymentType: String, Codable, CaseIterable {
    case zelle = "Zelle"
    case venmo = "Venmo"
    
    var placeholder: String {
        switch self {
        case .zelle:
            return "Phone number or email"
        case .venmo:
            return "@username"
        }
    }
    
    var helper: String {
        switch self {
        case .zelle:
            return "Used when friends send via Zelle"
        case .venmo:
            return "venmo.com/"
        }
    }
}
