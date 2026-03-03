import Foundation
import SwiftUI

// MARK: - Transaction Model

struct Transaction: Identifiable, Codable {
    let id: UUID
    var amount: Double
    var merchant: String
    var paidBy: Person
    var splitWith: [Person]
    var receiptImage: Data?
    var includeInSplit: Bool
    var isManual: Bool
    var backgroundResultToken: String?
    var lineItems: [ReceiptLineItem]
    var receiptDate: String?
    var currency: String
    var splitQuantities: [UUID: Int]

    init(
        amount: Double,
        merchant: String,
        paidBy: Person,
        splitWith: [Person],
        receiptImage: Data? = nil,
        includeInSplit: Bool = true,
        isManual: Bool = false,
        backgroundResultToken: String? = nil,
        lineItems: [ReceiptLineItem] = [],
        receiptDate: String? = nil,
        currency: String = "USD",
        splitQuantities: [UUID: Int] = [:]
    ) {
        self.id = UUID()
        self.amount = amount
        self.merchant = merchant
        self.paidBy = paidBy
        self.splitWith = splitWith
        self.receiptImage = receiptImage
        self.includeInSplit = includeInSplit
        self.isManual = isManual
        self.backgroundResultToken = backgroundResultToken
        self.lineItems = lineItems
        self.receiptDate = receiptDate
        self.currency = currency
        self.splitQuantities = splitQuantities
    }

    var formattedAmount: String {
        String(format: "$%.2f", amount)
    }

    var splitAmount: Double {
        guard !splitWith.isEmpty else { return amount }
        return amount / Double(splitWith.count)
    }

    /// Equal per-person share — used when no custom split is active
    var perPersonAmount: Double {
        guard !splitWith.isEmpty else { return amount }
        return amount / Double(splitWith.count)
    }

    /// Returns the weighted share owed by a specific person.
    /// Falls back to equal split if no splitQuantities are set.
    func weightedAmount(for person: Person) -> Double {
        guard !splitQuantities.isEmpty else { return perPersonAmount }
        let totalUnits = splitWith.reduce(0) { $0 + (splitQuantities[$1.id] ?? 1) }
        guard totalUnits > 0 else { return perPersonAmount }
        let myUnits = splitQuantities[person.id] ?? 1
        return amount * (Double(myUnits) / Double(totalUnits))
    }

    /// True when any person has a multiplier greater than 1
    var hasCustomSplit: Bool {
        !splitQuantities.isEmpty && splitQuantities.values.contains(where: { $0 > 1 })
    }
}
