import Foundation

class ShareFormatter {
    static func formatSettlements(
        settlements: [PaymentLink],
        paymentMethods: [PaymentMethod]
    ) -> String {
        var text = "💰 Split Settlement\n\n"
        
        // Add settlements
        text += "Payments:\n"
        for settlement in settlements {
            text += "• \(settlement.from.name) pays \(settlement.to.name): \(settlement.formattedAmount)\n"
        }
        
        // Add payment methods
        let enabledMethods = paymentMethods.filter { $0.includeWhenSharing && !$0.value.isEmpty }
        
        if !enabledMethods.isEmpty {
            text += "\nPayment Methods:\n"
            
            for method in enabledMethods {
                switch method.type {
                case .zelle:
                    text += "• Zelle: \(method.value)\n"
                case .venmo:
                    let username = method.value.replacingOccurrences(of: "@", with: "")
                    text += "• Venmo: @\(username) (venmo.com/\(username))\n"
                }
            }
        }
        
        return text
    }
    
    static func formatAmount(_ amount: Double) -> String {
        return String(format: "$%.2f", amount)
    }
    
    static func formatSummary(
        transactionCount: Int,
        peopleCount: Int,
        totalAmount: Double
    ) -> String {
        return "\(transactionCount) transactions • \(peopleCount) people • Total: \(formatAmount(totalAmount))"
    }
}
