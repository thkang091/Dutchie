import Foundation

struct ReceiptLineItem: Identifiable, Codable {
    let id = UUID()
    var name: String
    var originalPrice: Double
    var discount: Double
    var amount: Double
    var taxPortion: Double
    var isSelected: Bool
    
    // Computed property for the price with tax included
    var totalWithTax: Double {
        return amount + taxPortion
    }
    
    // Convenience initializers
    init(name: String, originalPrice: Double, discount: Double, amount: Double, taxPortion: Double = 0.0, isSelected: Bool) {
        self.name = name
        self.originalPrice = originalPrice
        self.discount = discount
        self.amount = amount
        self.taxPortion = taxPortion
        self.isSelected = isSelected
    }
    
    init(name: String, amount: Double, isSelected: Bool) {
        self.name = name
        self.originalPrice = amount
        self.discount = 0.0
        self.amount = amount
        self.taxPortion = 0.0
        self.isSelected = isSelected
    }
    
    enum CodingKeys: String, CodingKey {
        case name
        case originalPrice
        case discount
        case amount
        case taxPortion
        case isSelected
    }
}
