import Foundation
import SwiftUI
import Combine
import UIKit

// MARK: - Uploaded Receipt

struct UploadedReceipt: Identifiable {
    let id: UUID
    let image: UIImage
    let imageData: Data
    var merchant: String
    var total: Double
    var lineItems: [ReceiptLineItem]
    var receiptDate: String?
    var taxAmount: Double?
    var backgroundResultToken: String?   // UUID string linking to OCRService background cache
    var subtotal: Double?
    var totalSavings: Double?
    var processingMethod: OCRService.ProcessingMethod
    var currency: String
    /// Non-nil when the image was poor quality and GPT was used to extract details.
    /// Shown as a warning badge on the thumbnail and in the full-screen viewer.
    var imageQualityWarning: String?

    init(image: UIImage, ocrResult: OCRService.ReceiptData) {
        self.id                   = UUID()
        self.image                = image
        self.imageData            = image.jpegData(compressionQuality: 0.8) ?? Data()
        self.merchant             = ocrResult.merchant.isEmpty ? "Unknown Merchant" : ocrResult.merchant
        self.total                = ocrResult.likelyTotal ?? ocrResult.amounts.first ?? 0.0
        self.lineItems            = ocrResult.lineItems
        self.receiptDate          = ocrResult.receiptDate
        self.taxAmount            = ocrResult.taxAmount
        self.subtotal             = ocrResult.subtotal
        self.totalSavings         = ocrResult.totalSavings
        self.processingMethod     = ocrResult.processingMethod
        self.currency             = ocrResult.currency ?? "USD"
        self.imageQualityWarning  = ocrResult.imageQualityWarning
        // Thread the token through so ReviewView can look up the background result
        self.backgroundResultToken = ocrResult.backgroundResultToken

        print("UploadedReceipt created:")
        print("  Merchant: \(self.merchant)")
        print("  Total: \(formatCurrency(self.total, currency: self.currency))")
        print("  Currency: \(self.currency)")
        print("  Line items: \(self.lineItems.count)")
        print("  Processing method: \(self.processingMethod)")
        print("  Background token: \(self.backgroundResultToken?.prefix(8) ?? "none")…")
        if let warn = self.imageQualityWarning {
            print("  Quality warning: \(warn)")
        }
        if let savings = self.totalSavings, savings > 0 {
            print("  Total savings: \(formatCurrency(savings, currency: self.currency))")
        }
        print("  Image size: \(image.size)")
        print("  Data size: \(imageData.count) bytes")
    }

    /// Call this when the background OCR result arrives — updates all fields except the token.
    mutating func updateWithFullData(_ fullData: OCRService.ReceiptData) {
        self.merchant         = fullData.merchant.isEmpty ? self.merchant : fullData.merchant
        if let newTotal = fullData.likelyTotal { self.total = newTotal }
        self.lineItems        = fullData.lineItems
        self.receiptDate      = fullData.receiptDate
        self.taxAmount        = fullData.taxAmount
        self.subtotal         = fullData.subtotal
        self.totalSavings     = fullData.totalSavings
        self.processingMethod = fullData.processingMethod
        self.currency         = fullData.currency ?? self.currency
        // Preserve quality warning if already set; background result won't set a new one
        if let w = fullData.imageQualityWarning { self.imageQualityWarning = w }

        print("UploadedReceipt updated with full data:")
        print("  Line items: \(self.lineItems.count)")
        print("  Processing method: \(self.processingMethod)")
    }

    private func formatCurrency(_ amount: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle  = .currency
        f.currencyCode = currency
        return f.string(from: NSNumber(value: amount)) ?? "$\(String(format: "%.2f", amount))"
    }
}

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    @Published var profile: Profile {
        didSet { saveProfile() }
    }

    @Published var uploadedImages:      [UIImage]         = []
    @Published var uploadedReceipts:    [UploadedReceipt] = []
    @Published var manualTransactions:  [(name: String, amount: Double)] = []
    @Published var people:              [Person]          = []
    @Published var transactions:        [Transaction]     = []
    @Published var savedGroups:         [Group]           = []
    @Published var currentStep:         Int               = 0

    private let profileKey      = "savedProfile"
    private let splitHistoryKey = "splitHistory"

    init() {
        if let savedProfile = Self.loadProfile() {
            self.profile = savedProfile
            print("Loaded saved profile: \(savedProfile.name)")
            if let history = Self.loadSplitHistory() {
                self.profile.splitHistory = history
                print("Loaded \(history.count) split history records")
            }
        } else {
            self.profile = Profile(
                name: UIDevice.current.name,
                paymentMethods: PaymentMethod.defaultMethods()
            )
            print("Created new profile")
        }
        self.people = [Person(name: profile.name, isCurrentUser: true)]
    }

    // MARK: - Persistence

    private func saveProfile() {
        var profileToSave = profile
        let history = profileToSave.splitHistory
        profileToSave.splitHistory = []
        do {
            let data = try JSONEncoder().encode(profileToSave)
            UserDefaults.standard.set(data, forKey: profileKey)
            print("Profile saved successfully")
        } catch {
            print("Failed to save profile: \(error.localizedDescription)")
        }
        saveSplitHistory(history)
    }

    private func saveSplitHistory(_ history: [SplitRecord]) {
        do {
            let data = try JSONEncoder().encode(history)
            UserDefaults.standard.set(data, forKey: splitHistoryKey)
            print("Split history saved (\(history.count) records)")
        } catch {
            print("Failed to save split history: \(error.localizedDescription)")
        }
    }

    private static func loadProfile() -> Profile? {
        guard let data = UserDefaults.standard.data(forKey: "savedProfile") else {
            print("No saved profile found"); return nil
        }
        do {
            return try JSONDecoder().decode(Profile.self, from: data)
        } catch {
            print("Failed to load profile: \(error.localizedDescription)"); return nil
        }
    }

    private static func loadSplitHistory() -> [SplitRecord]? {
        guard let data = UserDefaults.standard.data(forKey: "splitHistory") else {
            print("No split history found"); return nil
        }
        do {
            return try JSONDecoder().decode([SplitRecord].self, from: data)
        } catch {
            print("Failed to load split history: \(error.localizedDescription)"); return nil
        }
    }

    // MARK: - Receipt → Transaction helpers

    /// Build a Transaction from an UploadedReceipt and the current people list.
    /// Threads backgroundResultToken so ReviewView can fetch line items from the cache.
    func makeTransaction(from receipt: UploadedReceipt) -> Transaction {
        let payer = people.first(where: { $0.isCurrentUser }) ?? people.first ?? Person(name: profile.name, isCurrentUser: true)
        var t = Transaction(
            amount:      receipt.total,
            merchant:    receipt.merchant,
            paidBy:      payer,
            splitWith:   people,
            receiptImage: receipt.imageData,
            includeInSplit: true,
            isManual:    false,
            backgroundResultToken: receipt.backgroundResultToken,
            lineItems:   receipt.lineItems,
            receiptDate: receipt.receiptDate,
            currency:    receipt.currency,
            splitQuantities: [:]
        )
        return t
    }

    // MARK: - Public Methods

    func addPerson(_ person: Person) { people.append(person) }

    func removePerson(_ person: Person) { people.removeAll { $0.id == person.id } }

    var needsCurrentUser: Bool { !people.contains(where: { $0.isCurrentUser }) }

    func ensureCurrentUser() {
        if needsCurrentUser {
            people.insert(Person(name: profile.name, isCurrentUser: true), at: 0)
        }
    }

    func saveGroup(name: String) {
        savedGroups.append(Group(name: name, members: people))
    }

    func loadGroup(_ group: Group) {
        people = group.members
    }

    func updateReceipt(at index: Int, with fullData: OCRService.ReceiptData) {
        guard index < uploadedReceipts.count else {
            print("Receipt index \(index) out of bounds"); return
        }
        uploadedReceipts[index].updateWithFullData(fullData)
        // Also update the matching transaction's line items in place
        let token = uploadedReceipts[index].backgroundResultToken
        if let token, let idx = transactions.firstIndex(where: { $0.backgroundResultToken == token }) {
            transactions[idx].lineItems   = fullData.lineItems
            transactions[idx].merchant    = fullData.merchant.isEmpty
                ? transactions[idx].merchant : fullData.merchant
            if let t = fullData.likelyTotal { transactions[idx].amount = t }
        }
    }

    // MARK: - Settlement Calculation

    func calculateSettlements() -> [PaymentLink] {
        var balances: [UUID: Double] = [:]
        for person in people { balances[person.id] = 0 }

        for transaction in transactions where transaction.includeInSplit {
            let paidById  = transaction.paidBy.id
            let hasCustom = !transaction.splitQuantities.isEmpty
            let totalUnits: Double = hasCustom
                ? Double(transaction.splitWith.reduce(0) { $0 + (transaction.splitQuantities[$1.id] ?? 1) })
                : Double(transaction.splitWith.count)

            guard totalUnits > 0 else { continue }

            for person in transaction.splitWith {
                guard person.id != paidById else { continue }
                let units: Double = hasCustom ? Double(transaction.splitQuantities[person.id] ?? 1) : 1.0
                let share = transaction.amount * (units / totalUnits)
                balances[person.id, default: 0]  -= share
                balances[paidById, default: 0]   += share
            }
        }

        var payments: [PaymentLink] = []
        var creditors = balances.filter { $0.value >  0.01 }.sorted { $0.value > $1.value }
        var debtors   = balances.filter { $0.value < -0.01 }.sorted { $0.value < $1.value }
        var ci = 0; var di = 0

        while ci < creditors.count && di < debtors.count {
            guard let creditor = people.first(where: { $0.id == creditors[ci].key }),
                  let debtor   = people.first(where: { $0.id == debtors[di].key })
            else { break }

            let paymentAmount = min(creditors[ci].value, abs(debtors[di].value))
            payments.append(PaymentLink(from: debtor, to: creditor, amount: paymentAmount))

            creditors[ci].value -= paymentAmount
            debtors[di].value   += paymentAmount
            if creditors[ci].value  < 0.01  { ci += 1 }
            if abs(debtors[di].value) < 0.01 { di += 1 }
        }
        return payments
    }

    // MARK: - Reset

    func reset() {
        uploadedImages       = []
        uploadedReceipts     = []
        manualTransactions   = []
        transactions         = []
        people               = []
        currentStep          = 0
    }
}
