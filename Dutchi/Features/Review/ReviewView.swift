import SwiftUI
import UIKit

// MARK: - PersonQuantity Model

struct PersonQuantity: Identifiable {
    let id: UUID
    let person: Person
    var quantity: Int

    init(person: Person, quantity: Int = 1) {
        self.id       = person.id
        self.person   = person
        self.quantity = quantity
    }

    func share(in all: [PersonQuantity]) -> Double {
        let total = all.reduce(0) { $0 + $1.quantity }
        guard total > 0 else { return 0 }
        return Double(quantity) / Double(total)
    }

    func amount(for transactionTotal: Double, in all: [PersonQuantity]) -> Double {
        transactionTotal * share(in: all)
    }
}

// MARK: - ReviewView

struct ReviewView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    @EnvironmentObject var tutorialManager: TutorialManager
    @Environment(\.colorScheme) var colorScheme

    @State private var showManualAdd = false
    @State private var manualMerchant = ""
    @State private var manualAmount = ""
    @State private var showImageViewer = false
    @State private var selectedImage: UIImage?
    @State private var showEditAmount = false
    @State private var editingTransaction: Transaction?
    @State private var editAmount = ""
    @State private var showEditName = false
    @State private var editName = ""
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var undoAction: (() -> Void)?
    @State private var showBreakdownSheet = false
    @State private var breakdownTransaction: Transaction?
    @State private var detectedLineItems: [ReceiptLineItem] = []
    @State private var showBackConfirmation = false
    @State private var isProcessingBreakdown = false
    @State private var showValidationAlert = false
    @State private var validationMessage = ""
    @State private var advancedSplitTarget: Transaction? = nil

    @State private var breakdownQuickTotal: Double? = nil
    @State private var breakdownQuickMerchant: String = ""

    // MARK: - Tutorial spotlight helpers

    private var shouldHighlightTransaction: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .reviewTransaction
    }
    private var shouldHighlightBreakdownButton: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .breakdownButton
    }
    private var shouldHighlightItemCard: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .reviewItemCard
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            mainContent

            if showImageViewer, let image = selectedImage {
                fullScreenImageViewer(image: image)
                    .transition(.opacity)
                    .zIndex(100)
            }

            if showToast {
                VStack {
                    Spacer()
                    ToastView(
                        message: toastMessage,
                        action: undoAction,
                        actionLabel: undoAction != nil ? "Undo" : nil
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .zIndex(50)
            }

            if tutorialManager.isActive {
                TutorialOverlay(context: .review).zIndex(200)
            }
        }
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $showManualAdd) {
            ManualTransactionSheet(
                isPresented: $showManualAdd,
                merchant: $manualMerchant,
                amount: $manualAmount,
                onAdd: addManualTransaction
            )
        }
        .sheet(isPresented: $showEditAmount) {
            EditAmountSheet(
                isPresented: $showEditAmount,
                amount: $editAmount,
                onSave: saveEditedAmount
            )
        }
        .sheet(isPresented: $showEditName) {
            EditNameSheet(
                isPresented: $showEditName,
                name: $editName,
                onSave: saveEditedName
            )
        }
        .sheet(isPresented: $showBreakdownSheet, onDismiss: {
            breakdownQuickTotal = nil
            breakdownQuickMerchant = ""
        }) {
            ReceiptBreakdownSheet(
                isPresented: $showBreakdownSheet,
                transaction: breakdownTransaction,
                lineItems: $detectedLineItems,
                isLoading: $isProcessingBreakdown,
                quickTotal: $breakdownQuickTotal,
                quickMerchant: $breakdownQuickMerchant,
                onUseTotal: {
                    showBreakdownSheet = false
                    showSuccessToast("Using total amount")
                },
                onUseBreakdown: {
                    applyBreakdown()
                }
            )
            .environmentObject(tutorialManager)
        }
        .sheet(item: $advancedSplitTarget) { target in
            AdvancedSplitSheet(
                transaction: target,
                allPeople: appState.people,
                onApply: { quantities in applyAdvancedSplit(to: target, quantities: quantities) },
                onDismiss: { advancedSplitTarget = nil }
            )
        }
        .confirmationDialog("Save Transactions?", isPresented: $showBackConfirmation, titleVisibility: .visible) {
            Button("Save & Go Back") {
                saveTransactionsToUpload()
                router.navigateToUpload()
            }
            Button("Discard & Go Back", role: .destructive) {
                discardTransactions()
                router.navigateToUpload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do you want to save your current transactions?")
        }
        .alert("Selection Required", isPresented: $showValidationAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(validationMessage)
        }
        .onChange(of: tutorialManager.shouldOpenBreakdownSheet) { shouldOpen in
            guard shouldOpen, tutorialManager.isActive,
                  let firstTransaction = appState.transactions.first else { return }
            tutorialManager.shouldOpenBreakdownSheet = false
            handleBreakdown(transaction: firstTransaction)
        }
        .onChange(of: tutorialManager.shouldAutoApplyBreakdown) { shouldApply in
            guard shouldApply, tutorialManager.isActive else { return }
            tutorialManager.shouldAutoApplyBreakdown = false
            applyBreakdown()
        }
        .onAppear {
            print("=== Review View Loaded ===")
            print("Total transactions: \(appState.transactions.count)")
            for t in appState.transactions {
                print("  \(t.merchant) = $\(t.amount) | image: \(t.receiptImage != nil) | items: \(t.lineItems.count)")
            }
        }
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            headerSection
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    ForEach(Array($appState.transactions.enumerated()), id: \.element.id) { index, $transaction in
                        TransactionCardView(
                            transaction: $transaction,
                            allPeople: appState.people,
                            onDelete: { deleteTransaction(transaction) },
                            onEditAmount: {
                                editingTransaction = transaction
                                editAmount = String(format: "%.2f", transaction.amount)
                                showEditAmount = true
                            },
                            onEditName: {
                                editingTransaction = transaction
                                editName = transaction.merchant
                                showEditName = true
                            },
                            onImageTap: { handleImageTap(transaction: transaction) },
                            onBreakdown: transaction.receiptImage != nil && !transaction.isManual ? {
                                handleBreakdown(transaction: transaction)
                            } : nil,
                            onAdvancedSplit: { advancedSplitTarget = transaction }
                        )
                        .tutorialSpotlight(
                            isHighlighted: shouldHighlightTransaction && index == 0,
                            cornerRadius: 16
                        )
                        .tutorialSpotlight(
                            isHighlighted: shouldHighlightItemCard && index == 0,
                            cornerRadius: 16
                        )
                    }
                    addManuallyButton
                }
                .padding(20)
                .padding(.bottom, 100)
            }
            .background(Color(.systemBackground))
            bottomButton
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Button(action: { showBackConfirmation = true }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20))
                    .foregroundColor(.primary)
            }
            Spacer()
            Text("Review Transactions")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
            Spacer()
            Button(action: { router.showProfile = true }) {
                if let currentUser = appState.people.first(where: { $0.isCurrentUser }) {
                    AvatarView(imageData: currentUser.contactImage, initials: currentUser.initials, size: 40)
                } else {
                    AvatarView(imageData: nil, initials: "ME", size: 40)
                }
            }
        }
        .padding(20)
        .background(Color(.systemBackground))
    }

    private var addManuallyButton: some View {
        Button(action: { showManualAdd = true }) {
            HStack {
                Image(systemName: "plus.circle").font(.system(size: 16))
                Text("Add Manually").font(.system(size: 16, weight: .medium))
            }
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(.secondarySystemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary, lineWidth: 1.5)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            )
        }
    }

    private var bottomButton: some View {
        Button(action: {
            if validateTransactions() { router.navigateToSettle() }
        }) {
            Text("Continue to Payments")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.accentColor)
                .cornerRadius(12)
        }
        .padding(20)
        .background(Color(.systemBackground).shadow(color: Color.primary.opacity(0.05), radius: 20, y: -5))
    }

    // MARK: - Full-screen image viewer

    private func fullScreenImageViewer(image: UIImage) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                Spacer()
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).padding()
                Spacer()
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showImageViewer = false }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { selectedImage = nil }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .padding(20)
                }
                Spacer()
            }
        }
    }

    // MARK: - Validation

    private func validateTransactions() -> Bool {
        var itemsWithoutPeople: [String] = []
        for transaction in appState.transactions {
            if transaction.splitWith.isEmpty { itemsWithoutPeople.append(transaction.merchant) }
        }
        if !itemsWithoutPeople.isEmpty {
            let itemsList = itemsWithoutPeople.prefix(3).joined(separator: ", ")
            let additional = itemsWithoutPeople.count > 3 ? " and \(itemsWithoutPeople.count - 3) more" : ""
            validationMessage = "No one is selected for: \(itemsList)\(additional). Please select at least one person for each item."
            showValidationAlert = true
            return false
        }
        return true
    }

    // MARK: - Actions

    private func saveTransactionsToUpload() {
        for transaction in appState.transactions {
            if transaction.isManual {
                appState.manualTransactions.append((name: transaction.merchant, amount: transaction.amount))
            } else if let imageData = transaction.receiptImage, let image = UIImage(data: imageData) {
                let ocrData = OCRService.ReceiptData(
                    merchant: transaction.merchant,
                    amounts: [transaction.amount],
                    hasReceiptStructure: true,
                    confidence: 1.0,
                    likelyTotal: transaction.amount,
                    lineItems: transaction.lineItems,
                    processingMethod: .tabscanner,
                    receiptDate: nil,
                    taxAmount: nil,
                    subtotal: nil,
                    totalSavings: nil,
                    isQuickResult: false,
                    currency: "USD"
                )
                appState.uploadedReceipts.append(UploadedReceipt(image: image, ocrResult: ocrData))
            } else {
                appState.manualTransactions.append((name: transaction.merchant, amount: transaction.amount))
            }
        }
        appState.transactions.removeAll()
    }

    private func discardTransactions() {
        appState.transactions.removeAll()
    }

    private func handleImageTap(transaction: Transaction) {
        guard let imageData = transaction.receiptImage, let image = UIImage(data: imageData) else {
            showSuccessToast("No receipt image available")
            return
        }
        selectedImage = image
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showImageViewer = true }
        }
    }

    // MARK: - Breakdown

    // MARK: - Replace the entire handleBreakdown function in ReviewView with this:

    private func handleBreakdown(transaction: Transaction) {
            print("\n=== BREAKDOWN REQUESTED: \(transaction.merchant) ===")

            // Already have full line items on the transaction — show immediately
            if !transaction.lineItems.isEmpty {
                breakdownTransaction   = transaction
                detectedLineItems      = transaction.lineItems
                breakdownQuickTotal    = transaction.amount
                breakdownQuickMerchant = transaction.merchant
                isProcessingBreakdown  = false
                showBreakdownSheet     = true
                return
            }

            // No token means this is a manual transaction or very old data — nothing to fetch
            guard let token = transaction.backgroundResultToken else {
                print("  No background token — manual or legacy transaction")
                showSuccessToast("No receipt breakdown available for this transaction")
                return
            }

            // Show the sheet immediately in a loading state.
            // Background Tabscanner/GPT has been running since the image was uploaded,
            // so this spinner usually only shows for a second or two at most.
            breakdownTransaction   = transaction
            detectedLineItems      = []
            breakdownQuickTotal    = transaction.amount
            breakdownQuickMerchant = transaction.merchant
            isProcessingBreakdown  = true
            showBreakdownSheet     = true

            print("  Fetching background result for token \(token.prefix(8))…")

            OCRService.fetchBackgroundResult(for: token) { receiptData in
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        self.isProcessingBreakdown = false
                    }

                    guard let receiptData else {
                        // Background OCR timed out (>30 s) — run fresh OCR as safety net
                        print("  [Breakdown] Token timed out — running fresh OCR")
                        self.runFreshOCR(for: transaction)
                        return
                    }

                    print("  [Breakdown] Background result ready — \(receiptData.lineItems.count) items")

                    if receiptData.lineItems.isEmpty {
                        self.showBreakdownSheet = false
                        self.showSuccessToast("No line items found on this receipt")
                        return
                    }

                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        self.detectedLineItems      = receiptData.lineItems
                        self.breakdownQuickTotal    = receiptData.likelyTotal ?? transaction.amount
                        self.breakdownQuickMerchant = receiptData.merchant.isEmpty
                            ? transaction.merchant
                            : receiptData.merchant
                    }

                    // Persist line items onto the transaction so re-opening is instant
                    if let idx = self.appState.transactions.firstIndex(where: { $0.id == transaction.id }) {
                        self.appState.transactions[idx].lineItems = receiptData.lineItems
                        if let newTotal = receiptData.likelyTotal {
                            self.appState.transactions[idx].amount = newTotal
                        }
                    }
                }
            }
        }

        /// Safety-net: runs fresh full OCR when the background result timed out.
        private func runFreshOCR(for transaction: Transaction) {
            guard let imageData = transaction.receiptImage,
                  let image     = UIImage(data: imageData) else {
                showBreakdownSheet = false
                showSuccessToast("No receipt image available")
                return
            }

            OCRService.extractText(from: image) { result in
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        self.isProcessingBreakdown = false
                    }
                    switch result {
                    case .success(let data) where !data.lineItems.isEmpty:
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                            self.detectedLineItems      = data.lineItems
                            self.breakdownQuickTotal    = data.likelyTotal ?? transaction.amount
                            self.breakdownQuickMerchant = data.merchant.isEmpty ? transaction.merchant : data.merchant
                        }
                        if let idx = self.appState.transactions.firstIndex(where: { $0.id == transaction.id }) {
                            self.appState.transactions[idx].lineItems = data.lineItems
                        }
                    default:
                        self.showBreakdownSheet = false
                        self.showSuccessToast("No line items found on this receipt")
                    }
                }
            }
        }

    

    private func applyBreakdown() {
        guard let transaction = breakdownTransaction,
              let index = appState.transactions.firstIndex(where: { $0.id == transaction.id }) else { return }

        let originalTransaction = appState.transactions.remove(at: index)
        let selectedItems = detectedLineItems.filter(\.isSelected)
        let isTutorial = tutorialManager.isActive

        for (itemIndex, item) in selectedItems.enumerated() {
            let name = item.name.isEmpty ? originalTransaction.merchant : item.name
            let splitWith: [Person]
            if isTutorial {
                splitWith = itemIndex < 3 ? appState.people : []
            } else {
                splitWith = appState.people
            }
            let newTransaction = Transaction(
                amount: item.amount,
                merchant: name,
                paidBy: originalTransaction.paidBy,
                splitWith: splitWith,
                receiptImage: nil,
                includeInSplit: true,
                isManual: false,
                lineItems: []
            )
            appState.transactions.append(newTransaction)
        }

        if tutorialManager.isActive {
            showBreakdownSheet = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                tutorialManager.advanceToPostBreakdown()
            }
        } else {
            showBreakdownSheet = false
            showSuccessToast("Receipt broken down into \(selectedItems.count) items")
        }
    }

    private func applyAdvancedSplit(to transaction: Transaction, quantities: [PersonQuantity]) {
        guard let index = appState.transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        appState.transactions[index].splitWith = quantities.map(\.person)
        var quantityMap: [UUID: Int] = [:]
        for pq in quantities { quantityMap[pq.person.id] = pq.quantity }
        appState.transactions[index].splitQuantities = quantityMap

        let totalUnits = quantities.reduce(0) { $0 + $1.quantity }
        let summary = quantities.map { pq -> String in
            let pct = totalUnits > 0
                ? Int((Double(pq.quantity) / Double(totalUnits) * 100).rounded())
                : 0
            return "\(pq.person.name): \(pct)%"
        }.joined(separator: "  ·  ")

        showSuccessToast("Split applied — \(summary)")
    }

    private func addManualTransaction() {
        guard !manualMerchant.isEmpty, let amount = Double(manualAmount), amount > 0 else { return }
        let transaction = Transaction(
            amount: amount,
            merchant: manualMerchant,
            paidBy: appState.people.first(where: { $0.isCurrentUser }) ?? appState.people[0],
            splitWith: appState.people,
            isManual: true,
            lineItems: []
        )
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            appState.transactions.append(transaction)
        }
        showManualAdd = false
        manualMerchant = ""
        manualAmount = ""
    }

    private func saveEditedAmount() {
        guard let transaction = editingTransaction,
              let amount = Double(editAmount), amount > 0,
              let index = appState.transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        appState.transactions[index].amount = amount
        showEditAmount = false
        editingTransaction = nil
        editAmount = ""
    }

    private func saveEditedName() {
        guard let transaction = editingTransaction,
              !editName.trimmingCharacters(in: .whitespaces).isEmpty,
              let index = appState.transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        appState.transactions[index].merchant = editName.trimmingCharacters(in: .whitespaces)
        showEditName = false
        editingTransaction = nil
        editName = ""
    }

    private func deleteTransaction(_ transaction: Transaction) {
        guard let index = appState.transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        let deleted = appState.transactions[index]
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            _ = appState.transactions.remove(at: index)
        }
        toastMessage = "Transaction removed"
        undoAction = {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                appState.transactions.insert(deleted, at: index)
            }
            hideToast()
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { hideToast() }
    }

    private func showSuccessToast(_ message: String) {
        toastMessage = message
        undoAction = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { hideToast() }
    }

    private func hideToast() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            showToast = false
            undoAction = nil
        }
    }
}

// MARK: - Advanced Split Sheet

struct AdvancedSplitSheet: View {
    let transaction: Transaction
    let allPeople: [Person]
    let onApply: ([PersonQuantity]) -> Void
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quantities: [PersonQuantity]

    init(
        transaction: Transaction,
        allPeople: [Person],
        onApply: @escaping ([PersonQuantity]) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.transaction = transaction
        self.allPeople   = allPeople
        self.onApply     = onApply
        self.onDismiss   = onDismiss

        let splitIDs = Set(transaction.splitWith.map(\.id))
        self._quantities = State(initialValue: allPeople.map { person in
            PersonQuantity(person: person, quantity: splitIDs.contains(person.id) ? 1 : 0)
        })
    }

    private var includedQuantities: [PersonQuantity] { quantities.filter { $0.quantity > 0 } }
    private var totalUnits: Int { quantities.reduce(0) { $0 + $1.quantity } }
    private var hasUnits: Bool  { totalUnits > 0 }

    private func sharePercent(for pq: PersonQuantity) -> Double { pq.share(in: quantities) * 100 }
    private func owedAmount(for pq: PersonQuantity) -> Double   { pq.amount(for: transaction.amount, in: quantities) }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                infoBanner
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                ScrollView {
                    VStack(spacing: 20) {
                        instructionCard
                        peopleList
                        if hasUnits { summaryCard }
                    }
                    .padding(20)
                    .padding(.bottom, 100)
                }
                .background(Color(.systemBackground))
                applyButton
            }
            .navigationTitle("Advanced Split")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).foregroundColor(.primary)
                    }
                }
            }
        }
    }

    private var infoBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "divide.circle.fill").font(.system(size: 28)).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchant).font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)
                Text(String(format: "$%.2f total", transaction.amount)).font(.system(size: 14)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(20).background(Color(.systemBackground))
    }

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("How it works", systemImage: "info.circle")
                .font(.system(size: 14, weight: .semibold)).foregroundColor(.accentColor)
            Text("Tap a person to include or exclude them. Use the **×** multiplier if someone owes more — e.g. if Alex ate twice as much, give them **2×** and everyone else **1×**.")
                .font(.system(size: 14)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).background(Color.accentColor.opacity(0.07)).cornerRadius(12)
    }

    private var peopleList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Who's splitting?").font(.system(size: 15, weight: .semibold)).foregroundColor(.secondary).padding(.horizontal, 4)
                Spacer()
                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        let allIncluded = quantities.allSatisfy { $0.quantity > 0 }
                        for i in quantities.indices { quantities[i].quantity = allIncluded ? 0 : 1 }
                    }
                }) {
                    Text(quantities.allSatisfy { $0.quantity > 0 } ? "Deselect All" : "Select All")
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.accentColor)
                }
            }
            VStack(spacing: 10) {
                ForEach($quantities) { $pq in
                    PersonQuantityRow(
                        personQuantity: $pq,
                        owedAmount: pq.quantity > 0 ? owedAmount(for: pq) : nil,
                        sharePercent: pq.quantity > 0 ? sharePercent(for: pq) : nil
                    )
                }
            }
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Split Summary").font(.system(size: 15, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Text("\(includedQuantities.count) people").font(.system(size: 13)).foregroundColor(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(includedQuantities) { pq in
                    HStack {
                        Text(pq.person.name).font(.system(size: 15, weight: .medium)).foregroundColor(.primary)
                        Spacer()
                        Text(String(format: "%.0f%%  ·  $%.2f", sharePercent(for: pq), owedAmount(for: pq)))
                            .font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(16).background(Color.primary.opacity(0.05)).cornerRadius(12)
    }

    private var applyButton: some View {
        Button(action: { onApply(includedQuantities); dismiss() }) {
            Text(hasUnits
                 ? "Apply Split to \(includedQuantities.count) \(includedQuantities.count == 1 ? "Person" : "People")"
                 : "Select at Least One Person")
                .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(hasUnits ? Color.accentColor : Color.accentColor.opacity(0.4)).cornerRadius(12)
        }
        .disabled(!hasUnits)
        .padding(20)
        .background(Color(.systemBackground).shadow(color: Color.primary.opacity(0.05), radius: 20, y: -5))
    }
}

// MARK: - Person Quantity Row

private struct PersonQuantityRow: View {
    @Binding var personQuantity: PersonQuantity
    let owedAmount: Double?
    let sharePercent: Double?

    private var isIncluded: Bool { personQuantity.quantity > 0 }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: {
                withAnimation(.spring(response: 0.25)) { personQuantity.quantity = isIncluded ? 0 : 1 }
            }) {
                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundColor(isIncluded ? .accentColor : Color(.tertiaryLabel))
            }
            .buttonStyle(.plain)

            AvatarView(imageData: personQuantity.person.contactImage, initials: personQuantity.person.initials, size: 36)
                .opacity(isIncluded ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                Text(personQuantity.person.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isIncluded ? .primary : .secondary)
                if let pct = sharePercent, let amt = owedAmount {
                    Text(String(format: "%.0f%%  ·  $%.2f", pct, amt))
                        .font(.system(size: 13)).foregroundColor(.accentColor)
                } else {
                    Text("Not included").font(.system(size: 13)).foregroundColor(.secondary)
                }
            }

            Spacer()

            if isIncluded {
                HStack(spacing: 0) {
                    Button(action: {
                        withAnimation(.spring(response: 0.25)) {
                            personQuantity.quantity = max(1, personQuantity.quantity - 1)
                        }
                    }) {
                        Image(systemName: "minus").font(.system(size: 13, weight: .bold))
                            .frame(width: 32, height: 32)
                            .foregroundColor(personQuantity.quantity > 1 ? .primary : Color(.tertiaryLabel))
                    }
                    .buttonStyle(.plain)

                    Text("\(personQuantity.quantity)×")
                        .font(.system(size: 15, weight: .bold)).foregroundColor(.primary)
                        .frame(minWidth: 28).multilineTextAlignment(.center)

                    Button(action: {
                        withAnimation(.spring(response: 0.25)) { personQuantity.quantity += 1 }
                    }) {
                        Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                            .frame(width: 32, height: 32).foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                }
                .background(Color(.tertiarySystemBackground)).cornerRadius(8)
            }
        }
        .padding(14)
        .background(isIncluded ? Color(.secondarySystemBackground) : Color(.secondarySystemBackground).opacity(0.45))
        .cornerRadius(12)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25)) { personQuantity.quantity = isIncluded ? 0 : 1 }
        }
        .animation(.spring(response: 0.25), value: personQuantity.quantity)
    }
}

// MARK: - Receipt Breakdown Sheet

struct ReceiptBreakdownSheet: View {
    @Binding var isPresented: Bool
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var tutorialManager: TutorialManager

    let transaction: Transaction?
    @Binding var lineItems: [ReceiptLineItem]
    @Binding var isLoading: Bool
    @Binding var quickTotal: Double?
    @Binding var quickMerchant: String

    let onUseTotal: () -> Void
    let onUseBreakdown: () -> Void

    // Inline edit state
    @State private var editingItemID: UUID? = nil
    @State private var editingField: EditField = .none
    @State private var editNameText: String = ""
    @State private var editAmountText: String = ""

    enum EditField { case none, name, amount }

    var totalAmount: Double  { lineItems.filter(\.isSelected).reduce(0) { $0 + $1.amount } }
    var totalTax: Double     { lineItems.filter(\.isSelected).reduce(0) { $0 + $1.taxPortion } }
    var totalWithTax: Double { totalAmount + totalTax }

    // Gap between item sum and expected total
    private var receiptTotal: Double { transaction?.amount ?? 0 }
    
    private var effectiveTotal: Double {
        totalAmount  // tax is now its own line item, so always compare against item sum
    }
    
    
    private var gap: Double {
        round((receiptTotal - effectiveTotal) * 100) / 100
    }

    private var hasGap: Bool { abs(gap) > 0.01 }

    private var shouldSpotlightItems: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .breakdownConfirm
    }

    var body: some View {
        ZStack {
            NavigationView {
                VStack(spacing: 0) {
                    infoBanner
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)

                    if isLoading {
                        loadingView
                    } else {
                        ScrollView {
                            VStack(spacing: 24) {
                                selectAllButton
                                itemsList
                                    .tutorialSpotlight(isHighlighted: shouldSpotlightItems, cornerRadius: 16)
                                summarySection
                            }
                            .padding(20)
                        }
                        .background(Color(.systemBackground))
                        bottomButtons
                    }
                }
                .navigationTitle("Receipt Options")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { isPresented = false }) {
                            Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).foregroundColor(.primary)
                        }
                    }
                }
            }

            if tutorialManager.isActive && tutorialManager.isCurrentStep(in: .review) {
                TutorialOverlay(context: .review).zIndex(100)
            }
        }
    }

    // MARK: - Info banner

    private var infoBanner: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: isLoading ? "hourglass" : "doc.text.magnifyingglass")
                    .font(.system(size: 24)).foregroundColor(.primary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isLoading ? "Processing Receipt..." : "Receipt Breakdown Available")
                        .font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)
                    Text(isLoading
                         ? "Extracting line items from your receipt"
                         : "We detected \(lineItems.count) items on this receipt")
                        .font(.system(size: 14)).foregroundColor(.secondary)
                }
                Spacer()
                if isLoading { ProgressView().progressViewStyle(CircularProgressViewStyle()) }
            }
            .padding(16)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(12)
        }
        .padding(20)
        .background(Color(.systemBackground))
    }

    // MARK: - Loading view

    private var loadingView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 28) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .accentColor))
                    .scaleEffect(1.5)

                if let total = quickTotal {
                    VStack(spacing: 6) {
                        Text("Total found")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.6)
                        Text(String(format: "$%.2f", total))
                            .font(.system(size: 38, weight: .bold))
                            .foregroundColor(.primary)
                        if !quickMerchant.isEmpty {
                            Text(quickMerchant)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 20)
                    .padding(.horizontal, 32)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                    .shadow(color: Color.primary.opacity(0.06), radius: 12, y: 4)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                } else {
                    Text("Analyzing receipt...")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.secondary)
                        .transition(.opacity)
                }

                Text(quickTotal != nil ? "Breaking down line items…" : "Reading receipt data…")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: quickTotal)
            Spacer()

            if let total = quickTotal {
                Button(action: { onUseTotal() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").font(.system(size: 15))
                        Text(String(format: "Use $%.2f as total", total))
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor.opacity(0.08))
                    .cornerRadius(12)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // MARK: - Select All

    private var selectAllButton: some View {
        Button(action: {
            let allSelected = lineItems.allSatisfy(\.isSelected)
            withAnimation(.spring(response: 0.3)) {
                for i in lineItems.indices { lineItems[i].isSelected = !allSelected }
            }
        }) {
            HStack {
                Image(systemName: lineItems.allSatisfy(\.isSelected) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .medium))
                Text(lineItems.allSatisfy(\.isSelected) ? "Deselect All" : "Select All")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.accentColor).frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Color.accentColor.opacity(0.1)).cornerRadius(12)
        }
    }

    // MARK: - Items List (all editable)

    private var itemsList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Detected Items")
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(.secondary).padding(.horizontal, 4)
                Spacer()
                Text("Tap name or amount to edit")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary.opacity(0.7))
            }

            VStack(spacing: 12) {
                ForEach($lineItems) { $item in
                    lineItemRow(item: $item)
                }
            }

            // Gap warning: sum doesn't match receipt total
            if hasGap && receiptTotal > 0 {
                HStack(spacing: 8) {
                    Image(systemName: gap > 0 ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(gap > 0 ? .orange : .red)
                    Text(gap > 0
                         ? String(format: "Items sum to $%.2f less than receipt total ($%.2f). Add a 'Missing Item' or adjust amounts.", abs(gap), receiptTotal)
                         : String(format: "Items sum to $%.2f more than receipt total ($%.2f). Reduce amounts or deselect items.", abs(gap), receiptTotal))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(gap > 0 ? .orange : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background((gap > 0 ? Color.orange : Color.red).opacity(0.08))
                .cornerRadius(8)

                if gap > 0 {
                    Button(action: { addMissingItemPlaceholder() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill").font(.system(size: 14))
                            Text(String(format: "Add Missing Item ($%.2f)", gap))
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.08))
                        .cornerRadius(10)
                    }
                }
            }
        }
    }

    private func addMissingItemPlaceholder() {
        let newItem = ReceiptLineItem(
            name: "Missing Item(s)",
            originalPrice: gap,
            discount: 0,
            amount: gap,
            taxPortion: 0,
            isSelected: true
        )
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            lineItems.append(newItem)
        }
    }

    // MARK: - Individual Item Row (fully editable)

    private func lineItemRow(item: Binding<ReceiptLineItem>) -> some View {
        let isMissing = item.wrappedValue.name == "Missing Item(s)"
        let isEditingThis = editingItemID == item.wrappedValue.id

        return VStack(spacing: 10) {
            HStack(spacing: 14) {
                // Checkbox
                Button(action: {
                    withAnimation(.spring(response: 0.3)) { item.wrappedValue.isSelected.toggle() }
                }) {
                    Image(systemName: item.wrappedValue.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundColor(item.wrappedValue.isSelected ? .accentColor : .secondary)
                }

                // Name — tappable to edit inline
                VStack(alignment: .leading, spacing: 6) {
                    if isEditingThis && editingField == .name {
                        // Inline name editor
                        HStack(spacing: 6) {
                            TextField("Item name", text: $editNameText)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.tertiarySystemBackground))
                                .cornerRadius(8)
                                .onSubmit { commitNameEdit(for: item) }

                            Button(action: { commitNameEdit(for: item) }) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.accentColor)
                            }
                            Button(action: { cancelEdit() }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Button(action: { startNameEdit(for: item) }) {
                            HStack(spacing: 4) {
                                Text(item.wrappedValue.name.isEmpty ? "Item" : item.wrappedValue.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(item.wrappedValue.isSelected ? .primary : .primary.opacity(0.4))
                                    .multilineTextAlignment(.leading)

                                if isMissing {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.orange)
                                }

                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    // Amount row
                    if isEditingThis && editingField == .amount {
                        // Inline amount editor
                        HStack(spacing: 6) {
                            Text("$").font(.system(size: 16, weight: .bold)).foregroundColor(.secondary)
                            TextField("0.00", text: $editAmountText)
                                .font(.system(size: 18, weight: .bold))
                                .keyboardType(.decimalPad)
                                .foregroundColor(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.tertiarySystemBackground))
                                .cornerRadius(8)
                                .frame(maxWidth: 120)
                                .onSubmit { commitAmountEdit(for: item) }

                            Button(action: { commitAmountEdit(for: item) }) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.accentColor)
                            }
                            Button(action: { cancelEdit() }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Button(action: { startAmountEdit(for: item) }) {
                            HStack(spacing: 4) {
                                Text(String(format: "$%.2f", item.wrappedValue.amount))
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(item.wrappedValue.isSelected ? .primary : .primary.opacity(0.4))

                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if item.wrappedValue.taxPortion > 0 {
                        HStack(spacing: 4) {
                            Text("+ $\(String(format: "%.2f", item.wrappedValue.taxPortion)) tax")
                                .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                            Text("= $\(String(format: "%.2f", item.wrappedValue.totalWithTax)) total")
                                .font(.system(size: 12, weight: .semibold)).foregroundColor(.primary.opacity(0.6))
                        }
                        .opacity(item.wrappedValue.isSelected ? 1.0 : 0.4)
                    }
                }

                Spacer()

                // Discount badge
                if item.wrappedValue.discount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "tag.fill").font(.system(size: 10)).foregroundColor(.green)
                        Text("-$\(String(format: "%.2f", item.wrappedValue.discount))")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.green)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.green.opacity(0.1)).cornerRadius(6)
                    .opacity(item.wrappedValue.isSelected ? 1.0 : 0.4)
                }

                // Delete button
                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        lineItems.removeAll { $0.id == item.wrappedValue.id }
                    }
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundColor(.red.opacity(0.6))
                        .frame(width: 30, height: 30)
                        .background(Color.red.opacity(0.06))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            // Missing item hint
            if isMissing && !isEditingThis {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundColor(.orange)
                    Text("Tap the name above to rename this item, or tap the amount to adjust it.")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(.orange)
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(16)
        .background(
            item.wrappedValue.isSelected
                ? (isMissing ? Color.orange.opacity(0.06) : Color(.secondarySystemBackground))
                : Color(.secondarySystemBackground).opacity(0.5)
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isMissing ? Color.orange.opacity(0.3) : Color.clear, lineWidth: 1.5)
        )
        .shadow(color: Color.primary.opacity(item.wrappedValue.isSelected ? 0.06 : 0.02), radius: 6, y: 2)
        .animation(.spring(response: 0.3), value: isEditingThis)
    }

    // MARK: - Edit helpers

    private func startNameEdit(for item: Binding<ReceiptLineItem>) {
        cancelEdit()
        editingItemID = item.wrappedValue.id
        editingField  = .name
        editNameText  = item.wrappedValue.name
    }

    private func startAmountEdit(for item: Binding<ReceiptLineItem>) {
        cancelEdit()
        editingItemID   = item.wrappedValue.id
        editingField    = .amount
        editAmountText  = String(format: "%.2f", item.wrappedValue.amount)
    }

    private func commitNameEdit(for item: Binding<ReceiptLineItem>) {
        let trimmed = editNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            item.wrappedValue.name = trimmed
        }
        cancelEdit()
    }

    private func commitAmountEdit(for item: Binding<ReceiptLineItem>) {
        if let newAmount = Double(editAmountText), newAmount > 0 {
            item.wrappedValue.amount        = round(newAmount * 100) / 100
            item.wrappedValue.originalPrice = item.wrappedValue.amount
        }
        cancelEdit()
    }

    private func cancelEdit() {
        editingItemID  = nil
        editingField   = .none
        editNameText   = ""
        editAmountText = ""
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                HStack {
                    Text("Items subtotal").font(.system(size: 15, weight: .medium)).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "$%.2f", totalAmount))
                        .font(.system(size: 18, weight: .semibold)).foregroundColor(.primary)
                }
                if totalTax > 0 {
                    HStack {
                        Text("Tax").font(.system(size: 15, weight: .medium)).foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "$%.2f", totalTax))
                            .font(.system(size: 18, weight: .semibold)).foregroundColor(.primary)
                    }
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                    HStack {
                        Text("Total").font(.system(size: 16, weight: .bold)).foregroundColor(.primary)
                        Spacer()
                        Text(String(format: "$%.2f", totalWithTax))
                            .font(.system(size: 22, weight: .bold)).foregroundColor(.primary)
                    }
                } else {
                    HStack {
                        Text("Selected Total").font(.system(size: 15, weight: .medium)).foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "$%.2f", totalAmount))
                            .font(.system(size: 22, weight: .bold)).foregroundColor(.primary)
                    }
                }
            }
            .padding(20).background(Color.primary.opacity(0.05)).cornerRadius(12)

            // Receipt total reference
            if let transaction = transaction {
                let expected = totalTax > 0 ? totalWithTax : totalAmount
                HStack(spacing: 8) {
                    Image(systemName: abs(expected - transaction.amount) <= 0.01 ? "checkmark.circle.fill" : "info.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(abs(expected - transaction.amount) <= 0.01 ? .green : .secondary)
                    Text(abs(expected - transaction.amount) <= 0.01
                         ? "Items match receipt total ✓"
                         : String(format: "Receipt total: $%.2f  ·  Difference: $%.2f", transaction.amount, abs(expected - transaction.amount)))
                        .font(.system(size: 14))
                        .foregroundColor(abs(expected - transaction.amount) <= 0.01 ? .green : .secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Bottom Buttons

    private var bottomButtons: some View {
        VStack(spacing: 12) {
            Button(action: { onUseBreakdown() }) {
                HStack {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 16))
                    Text("Break Down into \(lineItems.filter(\.isSelected).count) Items")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(Color.accentColor).cornerRadius(12)
            }
            .disabled(lineItems.filter(\.isSelected).isEmpty)
            .opacity(lineItems.filter(\.isSelected).isEmpty ? 0.4 : 1.0)

            Button(action: { onUseTotal() }) {
                HStack {
                    Image(systemName: "receipt").font(.system(size: 16))
                    Text("Keep as Single Total").font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.primary).frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(Color(.secondarySystemBackground))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary, lineWidth: 1.5))
            }
        }
        .padding(20)
        .background(Color(.systemBackground).shadow(color: Color.primary.opacity(0.05), radius: 20, y: -5))
    }
}

// MARK: - Manual Transaction Sheet

struct ManualTransactionSheet: View {
    @Binding var isPresented: Bool
    @Binding var merchant: String
    @Binding var amount: String
    @Environment(\.colorScheme) var colorScheme
    let onAdd: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Merchant Name")
                            .font(.system(size: 15, weight: .semibold)).foregroundColor(.secondary).padding(.horizontal, 4)
                        TextField("e.g., Starbucks", text: $merchant)
                            .font(.system(size: 16, weight: .medium)).padding(16)
                            .background(Color(.secondarySystemBackground)).cornerRadius(12)
                            .shadow(color: Color.primary.opacity(0.03), radius: 4, y: 2)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Amount")
                            .font(.system(size: 15, weight: .semibold)).foregroundColor(.secondary).padding(.horizontal, 4)
                        HStack(spacing: 8) {
                            Text("$").font(.system(size: 20, weight: .semibold)).foregroundColor(.secondary)
                            TextField("0.00", text: $amount).font(.system(size: 16, weight: .medium)).keyboardType(.decimalPad)
                        }
                        .padding(16).background(Color(.secondarySystemBackground)).cornerRadius(12)
                        .shadow(color: Color.primary.opacity(0.03), radius: 4, y: 2)
                    }
                }
                Spacer()
            }
            .padding(24).background(Color(.systemBackground))
            .navigationTitle("Add Transaction").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { isPresented = false; merchant = ""; amount = "" }) {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).foregroundColor(.primary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { onAdd() }) {
                        Text("Add").font(.system(size: 16, weight: .semibold)).foregroundColor(.accentColor)
                    }
                    .disabled(merchant.isEmpty || amount.isEmpty)
                    .opacity(merchant.isEmpty || amount.isEmpty ? 0.3 : 1.0)
                }
            }
        }
    }
}

// MARK: - Edit Amount Sheet

struct EditAmountSheet: View {
    @Binding var isPresented: Bool
    @Binding var amount: String
    @Environment(\.colorScheme) var colorScheme
    let onSave: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Amount").font(.system(size: 14, weight: .medium)).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Text("$").font(.system(size: 28, weight: .semibold)).foregroundColor(.primary)
                        TextField("0.00", text: $amount)
                            .font(.system(size: 28, weight: .semibold)).keyboardType(.decimalPad).foregroundColor(.primary)
                    }
                    .padding(20).background(Color(.secondarySystemBackground)).cornerRadius(16)
                    .shadow(color: Color.primary.opacity(0.05), radius: 8, y: 4)
                }
                Spacer()
            }
            .padding(24).background(Color(.systemBackground))
            .navigationTitle("Edit Amount").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).foregroundColor(.primary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { onSave() }) {
                        Text("Save").font(.system(size: 16, weight: .semibold)).foregroundColor(.accentColor)
                    }
                }
            }
        }
    }
}

// MARK: - Edit Name Sheet

struct EditNameSheet: View {
    @Binding var isPresented: Bool
    @Binding var name: String
    @Environment(\.colorScheme) var colorScheme
    let onSave: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Item Name").font(.system(size: 14, weight: .medium)).foregroundColor(.secondary)
                    TextField("Enter name", text: $name)
                        .font(.system(size: 20, weight: .semibold)).foregroundColor(.primary)
                        .padding(20).background(Color(.secondarySystemBackground)).cornerRadius(16)
                        .shadow(color: Color.primary.opacity(0.05), radius: 8, y: 4)
                }
                Spacer()
            }
            .padding(24).background(Color(.systemBackground))
            .navigationTitle("Edit Name").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).foregroundColor(.primary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { onSave() }) {
                        Text("Save").font(.system(size: 16, weight: .semibold)).foregroundColor(.accentColor)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.3 : 1.0)
                }
            }
        }
    }
}
