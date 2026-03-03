import Foundation

struct PaymentLink: Identifiable {
    let id: UUID
    var from: Person
    var to: Person
    var amount: Double
    var isPaid: Bool
    
    init(id: UUID = UUID(), from: Person, to: Person, amount: Double, isPaid: Bool = false) {
        self.id = id
        self.from = from
        self.to = to
        self.amount = amount
        self.isPaid = isPaid
    }
    
    var formattedAmount: String {
        return String(format: "$%.2f", amount)
    }
}
