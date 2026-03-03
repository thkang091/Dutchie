import Foundation
import SwiftUI

struct Profile: Codable {
    var name: String
    var zelleContactInfo: String?  // Zelle phone number or email for sending requests
    var avatarImage: Data?
    var venmoQRCode: Data?  // Venmo QR code image
    var zelleQRCode: Data?  // Zelle QR code image
    @available(*, deprecated, message: "Use venmoQRCode and zelleQRCode instead")
    var paymentQRCode: Data? // DEPRECATED: Keep for backward compatibility
    var venmoUsername: String?  // Venmo username for deep linking (manual entry)
    var zelleEmail: String?  // Zelle email/phone for deep linking (manual entry)
    var venmoPaymentLink: String?  // Extracted Venmo link from QR code
    var zellePaymentLink: String?  // Extracted Zelle link from QR code
    var venmoShared: Bool?  // Whether Venmo info is shared with others (nil = default true)
    var zelleQRShared: Bool?  // Whether Zelle QR code is shared with others (nil = default true)
    var paymentMethods: [PaymentMethod]
    var splitHistory: [SplitRecord]

    // MARK: - Computed convenience accessors

    /// True if Venmo info should be shown/shared (defaults to true)
    var isVenmoShared: Bool {
        get { venmoShared ?? true }
        set { venmoShared = newValue }
    }

    /// True if Zelle QR code should be shown/shared (defaults to true)
    var isZelleQRShared: Bool {
        get { zelleQRShared ?? true }
        set { zelleQRShared = newValue }
    }

    init(
        name: String = "",
        zelleContactInfo: String? = nil,
        avatarImage: Data? = nil,
        venmoQRCode: Data? = nil,
        zelleQRCode: Data? = nil,
        paymentQRCode: Data? = nil,
        venmoUsername: String? = nil,
        zelleEmail: String? = nil,
        venmoPaymentLink: String? = nil,
        zellePaymentLink: String? = nil,
        venmoShared: Bool? = nil,
        zelleQRShared: Bool? = nil,
        paymentMethods: [PaymentMethod] = PaymentMethod.defaultMethods(),
        splitHistory: [SplitRecord] = []
    ) {
        self.name = name
        self.zelleContactInfo = zelleContactInfo
        self.avatarImage = avatarImage
        self.venmoQRCode = venmoQRCode
        self.zelleQRCode = zelleQRCode
        self.paymentQRCode = paymentQRCode
        self.venmoUsername = venmoUsername
        self.zelleEmail = zelleEmail
        self.venmoPaymentLink = venmoPaymentLink
        self.zellePaymentLink = zellePaymentLink
        self.venmoShared = venmoShared
        self.zelleQRShared = zelleQRShared
        self.paymentMethods = paymentMethods
        self.splitHistory = splitHistory

        // Migration: If old paymentQRCode exists but new ones don't, copy it to venmoQRCode
        if let oldQRCode = paymentQRCode, venmoQRCode == nil {
            self.venmoQRCode = oldQRCode
        }
    }

    // MARK: - Codable with migration support

    enum CodingKeys: String, CodingKey {
        case name
        case phoneNumber  // Legacy key — decoded only for migration
        case zelleContactInfo
        case avatarImage
        case venmoQRCode
        case zelleQRCode
        case paymentQRCode
        case venmoUsername
        case zelleEmail
        case venmoPaymentLink
        case zellePaymentLink
        case venmoShared
        case zelleQRShared
        case paymentMethods
        case splitHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""

        // Migration: map old phoneNumber → zelleContactInfo if new key is absent
        if let existing = try container.decodeIfPresent(String.self, forKey: .zelleContactInfo) {
            zelleContactInfo = existing.isEmpty ? nil : existing
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .phoneNumber), !legacy.isEmpty {
            zelleContactInfo = legacy
        } else {
            zelleContactInfo = nil
        }

        avatarImage = try container.decodeIfPresent(Data.self, forKey: .avatarImage)
        venmoQRCode = try container.decodeIfPresent(Data.self, forKey: .venmoQRCode)
        zelleQRCode = try container.decodeIfPresent(Data.self, forKey: .zelleQRCode)
        paymentQRCode = try container.decodeIfPresent(Data.self, forKey: .paymentQRCode)
        venmoUsername = try container.decodeIfPresent(String.self, forKey: .venmoUsername)
        zelleEmail = try container.decodeIfPresent(String.self, forKey: .zelleEmail)
        venmoPaymentLink = try container.decodeIfPresent(String.self, forKey: .venmoPaymentLink)
        zellePaymentLink = try container.decodeIfPresent(String.self, forKey: .zellePaymentLink)
        venmoShared = try container.decodeIfPresent(Bool.self, forKey: .venmoShared)
        zelleQRShared = try container.decodeIfPresent(Bool.self, forKey: .zelleQRShared)
        paymentMethods = try container.decodeIfPresent([PaymentMethod].self, forKey: .paymentMethods) ?? PaymentMethod.defaultMethods()
        splitHistory = try container.decodeIfPresent([SplitRecord].self, forKey: .splitHistory) ?? []

        // Migration: if old paymentQRCode exists but venmoQRCode doesn't, promote it
        if let oldQRCode = paymentQRCode, venmoQRCode == nil {
            venmoQRCode = oldQRCode
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(zelleContactInfo, forKey: .zelleContactInfo)
        try container.encodeIfPresent(avatarImage, forKey: .avatarImage)
        try container.encodeIfPresent(venmoQRCode, forKey: .venmoQRCode)
        try container.encodeIfPresent(zelleQRCode, forKey: .zelleQRCode)
        try container.encodeIfPresent(paymentQRCode, forKey: .paymentQRCode)
        try container.encodeIfPresent(venmoUsername, forKey: .venmoUsername)
        try container.encodeIfPresent(zelleEmail, forKey: .zelleEmail)
        try container.encodeIfPresent(venmoPaymentLink, forKey: .venmoPaymentLink)
        try container.encodeIfPresent(zellePaymentLink, forKey: .zellePaymentLink)
        try container.encodeIfPresent(venmoShared, forKey: .venmoShared)
        try container.encodeIfPresent(zelleQRShared, forKey: .zelleQRShared)
        try container.encode(paymentMethods, forKey: .paymentMethods)
        try container.encode(splitHistory, forKey: .splitHistory)
        // Note: phoneNumber is intentionally NOT encoded so the legacy key is dropped on next save
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

struct PaymentMethod: Identifiable, Codable {
    let id: UUID
    var type: PaymentType
    var value: String
    var includeWhenSharing: Bool

    init(
        id: UUID = UUID(),
        type: PaymentType,
        value: String = "",
        includeWhenSharing: Bool = true
    ) {
        self.id = id
        self.type = type
        self.value = value
        self.includeWhenSharing = includeWhenSharing
    }

    static func defaultMethods() -> [PaymentMethod] {
        [
            PaymentMethod(type: .venmo),
            PaymentMethod(type: .zelle),
            PaymentMethod(type: .cashApp),
            PaymentMethod(type: .paypal)
        ]
    }
}

enum PaymentType: String, Codable, CaseIterable {
    case venmo = "Venmo"
    case zelle = "Zelle"
    case cashApp = "Cash App"
    case paypal = "PayPal"

    var iconSystemName: String {
        switch self {
        case .venmo: return "v.circle.fill"
        case .zelle: return "z.circle.fill"
        case .cashApp: return "dollarsign.circle.fill"
        case .paypal: return "p.circle.fill"
        }
    }

    var brandColor: Color {
        switch self {
        case .venmo: return Color(red: 0.2, green: 0.53, blue: 0.96)
        case .zelle: return Color(red: 0.42, green: 0.22, blue: 0.69)
        case .cashApp: return Color(red: 0.0, green: 0.82, blue: 0.31)
        case .paypal: return Color(red: 0.0, green: 0.27, blue: 0.68)
        }
    }

    var placeholder: String {
        switch self {
        case .venmo: return "@username"
        case .zelle: return "email@example.com or phone"
        case .cashApp: return "$cashtag"
        case .paypal: return "email@example.com"
        }
    }

    var helper: String {
        switch self {
        case .venmo: return "Enter your Venmo username (e.g., @john-doe)"
        case .zelle: return "Enter your email or phone number"
        case .cashApp: return "Enter your $Cashtag (e.g., $johndoe)"
        case .paypal: return "Enter your PayPal email address"
        }
    }
}

// MARK: - Split History Models
struct SplitRecord: Identifiable, Codable {
    let id: UUID
    let date: Date
    let totalAmount: Double
    let participantCount: Int
    let transactionCount: Int
    let settlements: [SettlementSnapshot]
    let yourBalance: Double

    init(
        id: UUID = UUID(),
        date: Date,
        totalAmount: Double,
        participantCount: Int,
        transactionCount: Int,
        settlements: [SettlementSnapshot],
        yourBalance: Double
    ) {
        self.id = id
        self.date = date
        self.totalAmount = totalAmount
        self.participantCount = participantCount
        self.transactionCount = transactionCount
        self.settlements = settlements
        self.yourBalance = yourBalance
    }

    var formattedTotal: String {
        String(format: "$%.2f", totalAmount)
    }

    var formattedBalance: String {
        String(format: "$%.2f", abs(yourBalance))
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    // Create a hash for duplicate detection
    var contentHash: String {
        let settlementHash = settlements
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.fromName)-\($0.toName)-\($0.amount)" }
            .joined(separator: "|")
        return "\(totalAmount)-\(participantCount)-\(transactionCount)-\(settlementHash)"
    }
}

struct SettlementSnapshot: Identifiable, Codable {
    let id: UUID
    let fromName: String
    let toName: String
    let amount: Double

    var formattedAmount: String {
        String(format: "$%.2f", amount)
    }
}
