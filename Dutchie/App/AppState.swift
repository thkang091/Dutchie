import Foundation
import SwiftUI
import Combine
import UIKit

@MainActor
class AppState: ObservableObject {
    @Published var profile: Profile
    @Published var uploadedImages: [UIImage] = []
    @Published var manualTransactions: [(name: String, amount: Double)] = []
    @Published var people: [Person] = []
    @Published var transactions: [Transaction] = []
    @Published var savedGroups: [Group] = []
    @Published var currentStep: Int = 0
    
    init() {
        // Initialize with default profile
        self.profile = Profile(
            name: UIDevice.current.name,
            phoneNumber: "",
            paymentMethods: [
                PaymentMethod(type: .zelle),
                PaymentMethod(type: .venmo)
            ]
        )
        
        // Add current user to people
        self.people = [Person(name: profile.name, isCurrentUser: true)]
    }
    
    func addPerson(_ person: Person) {
        people.append(person)
    }
    
    func removePerson(_ person: Person) {
        people.removeAll { $0.id == person.id }
    }
    
    func saveGroup(name: String) {
        let group = Group(name: name, members: people)
        savedGroups.append(group)
    }
    
    func loadGroup(_ group: Group) {
        people = group.members
    }
    
    func calculateSettlements() -> [PaymentLink] {
        var balances: [UUID: Double] = [:]
        
        // Initialize balances
        for person in people {
            balances[person.id] = 0
        }
        
        // Calculate balances
        for transaction in transactions where transaction.includeInSplit {
            let perPerson = transaction.amount / Double(transaction.splitWith.count)
            
            for person in transaction.splitWith {
                if person.id != transaction.paidBy.id {
                    balances[person.id, default: 0] -= perPerson
                    balances[transaction.paidBy.id, default: 0] += perPerson
                }
            }
        }
        
        // Settle debts
        var payments: [PaymentLink] = []
        var creditors = balances.filter { $0.value > 0.01 }.sorted { $0.value > $1.value }
        var debtors = balances.filter { $0.value < -0.01 }.sorted { $0.value < $1.value }
        
        var creditorIndex = 0
        var debtorIndex = 0
        
        while creditorIndex < creditors.count && debtorIndex < debtors.count {
            let creditorId = creditors[creditorIndex].key
            let debtorId = debtors[debtorIndex].key
            
            guard let creditor = people.first(where: { $0.id == creditorId }),
                  let debtor = people.first(where: { $0.id == debtorId }) else {
                break
            }
            
            let creditorAmount = creditors[creditorIndex].value
            let debtorAmount = abs(debtors[debtorIndex].value)
            let paymentAmount = min(creditorAmount, debtorAmount)
            
            payments.append(PaymentLink(from: debtor, to: creditor, amount: paymentAmount))
            
            creditors[creditorIndex].value -= paymentAmount
            debtors[debtorIndex].value += paymentAmount
            
            if creditors[creditorIndex].value < 0.01 {
                creditorIndex += 1
            }
            if abs(debtors[debtorIndex].value) < 0.01 {
                debtorIndex += 1
            }
        }
        
        return payments
    }
    
    func reset() {
        uploadedImages = []
        manualTransactions = []
        transactions = []
        currentStep = 0
    }
}
