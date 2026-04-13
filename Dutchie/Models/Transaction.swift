import Foundation
import SwiftUI

struct Transaction: Identifiable, Codable {
    let id: UUID
    var amount: Double
    var merchant: String
    var paidBy: Person
    var splitWith: [Person]
    var receiptImage: Data?
    var includeInSplit: Bool
    var isManual: Bool
    
    init(
        id: UUID = UUID(),
        amount: Double,
        merchant: String,
        paidBy: Person,
        splitWith: [Person] = [],
        receiptImage: Data? = nil,
        includeInSplit: Bool = true,
        isManual: Bool = false
    ) {
        self.id = id
        self.amount = amount
        self.merchant = merchant
        self.paidBy = paidBy
        self.splitWith = splitWith
        self.receiptImage = receiptImage
        self.includeInSplit = includeInSplit
        self.isManual = isManual
    }
    
    var formattedAmount: String {
        return String(format: "$%.2f", amount)
    }
    
    var perPersonAmount: Double {
        guard !splitWith.isEmpty else { return amount }
        return amount / Double(splitWith.count)
    }
}
