import Foundation

class SettlementService {
    /// Calculates the minimum number of payments needed to settle all debts
    /// Uses a greedy algorithm to match largest creditor with largest debtor
    static func calculateSettlements(
        transactions: [Transaction],
        people: [Person]
    ) -> [PaymentLink] {
        var balances: [UUID: Double] = [:]
        
        // Initialize balances for all people
        for person in people {
            balances[person.id] = 0
        }
        
        // Calculate net balances
        for transaction in transactions where transaction.includeInSplit {
            guard !transaction.splitWith.isEmpty else { continue }
            
            let perPersonAmount = transaction.amount / Double(transaction.splitWith.count)
            
            // Credit the payer
            balances[transaction.paidBy.id, default: 0] += transaction.amount
            
            // Debit each person in the split
            for person in transaction.splitWith {
                balances[person.id, default: 0] -= perPersonAmount
            }
        }
        
        // Separate creditors and debtors
        var creditors = balances.filter { $0.value > 0.01 }.map { ($0.key, $0.value) }
            .sorted { $0.1 > $1.1 }
        var debtors = balances.filter { $0.value < -0.01 }.map { ($0.key, abs($0.value)) }
            .sorted { $0.1 > $1.1 }
        
        var settlements: [PaymentLink] = []
        var creditorIndex = 0
        var debtorIndex = 0
        
        // Match creditors with debtors
        while creditorIndex < creditors.count && debtorIndex < debtors.count {
            let creditorId = creditors[creditorIndex].0
            let debtorId = debtors[debtorIndex].0
            
            guard let creditor = people.first(where: { $0.id == creditorId }),
                  let debtor = people.first(where: { $0.id == debtorId }) else {
                break
            }
            
            let creditorAmount = creditors[creditorIndex].1
            let debtorAmount = debtors[debtorIndex].1
            let paymentAmount = min(creditorAmount, debtorAmount)
            
            // Create settlement
            settlements.append(PaymentLink(
                from: debtor,
                to: creditor,
                amount: paymentAmount
            ))
            
            // Update remaining amounts
            creditors[creditorIndex].1 -= paymentAmount
            debtors[debtorIndex].1 -= paymentAmount
            
            // Move to next if settled
            if creditors[creditorIndex].1 < 0.01 {
                creditorIndex += 1
            }
            if debtors[debtorIndex].1 < 0.01 {
                debtorIndex += 1
            }
        }
        
        return settlements
    }
    
    /// Calculates the balance for a specific person
    static func calculateBalance(
        for person: Person,
        in settlements: [PaymentLink]
    ) -> Double {
        var balance: Double = 0
        
        for settlement in settlements {
            if settlement.from.id == person.id {
                balance -= settlement.amount
            } else if settlement.to.id == person.id {
                balance += settlement.amount
            }
        }
        
        return balance
    }
}
