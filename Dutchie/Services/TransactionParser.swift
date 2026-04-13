import Foundation

class TransactionParser {
    static func parseReceipt(text: String) -> [(merchant: String, amount: Double)]? {
        var transactions: [(merchant: String, amount: Double)] = []
        
        // Simple regex to find amounts
        let pattern = #"\$?(\d+\.?\d{0,2})"#
        let regex = try? NSRegularExpression(pattern: pattern)
        
        let matches = regex?.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        
        var amounts: [Double] = []
        for match in matches ?? [] {
            if let range = Range(match.range(at: 1), in: text) {
                let amountString = String(text[range])
                if let amount = Double(amountString), amount > 0 {
                    amounts.append(amount)
                }
            }
        }
        
        // Find merchant name (usually in first few lines)
        let lines = text.components(separatedBy: .newlines)
        var merchant = "Unknown Merchant"
        
        for line in lines.prefix(5) {
            let cleaned = line.trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty && !cleaned.contains("$") && cleaned.count > 3 {
                merchant = cleaned
                break
            }
        }
        
        // Use the largest amount as total
        if let maxAmount = amounts.max() {
            transactions.append((merchant: merchant, amount: maxAmount))
        }
        
        return transactions.isEmpty ? nil : transactions
    }
    
    static func extractMerchantAndAmount(from text: String) -> (merchant: String, amount: Double)? {
        guard let parsed = parseReceipt(text: text), let first = parsed.first else {
            return nil
        }
        return first
    }
}
