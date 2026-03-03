import SwiftUI

struct ProcessingView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    @EnvironmentObject var tutorialManager: TutorialManager
    @Environment(\.colorScheme) var colorScheme
    
    @State private var isProcessing = true
    @State private var progress: Double = 0
    @State private var currentItem = 0
    @State private var totalItems = 0
    
    var body: some View {
        VStack {
            Spacer()
            
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.15), lineWidth: 4)
                        .frame(width: 100, height: 100)
                    
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 100, height: 100)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: progress)
                    
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.primary)
                }
                
                VStack(spacing: 8) {
                    Text("Creating transactions...")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.primary)
                    
                    if totalItems > 0 {
                        Text("\(currentItem) of \(totalItems)")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .navigationBarBackButtonHidden(true)
        .onAppear {
            processTransactions()
        }
    }
    
    private func processTransactions() {
        // ✅ If tutorial is active and transactions already exist, skip straight to review
        if tutorialManager.isActive && !appState.transactions.isEmpty {
            print("📚 Tutorial mode: transactions already set up, skipping processing")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                router.navigateToReview()
            }
            return
        }
        
        totalItems = appState.uploadedReceipts.count + appState.manualTransactions.count
        
        print("Total items to process: \(totalItems)")
        print("  Receipts with OCR: \(appState.uploadedReceipts.count)")
        print("  Manual entries: \(appState.manualTransactions.count)")
        
        let totalSteps = 20
        let stepDuration = 0.05
        var currentStep = 0
        
        Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { timer in
            currentStep += 1
            progress = Double(currentStep) / Double(totalSteps)
            
            if currentStep >= totalSteps {
                timer.invalidate()
                
                createTransactionsFromProcessedData()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    router.navigateToReview()
                }
            }
        }
    }
    
    private func ensureSampleDataForTutorial() {
        // This should already be done by TutorialManager.start()
        // But we'll check again just in case
        
        if appState.uploadedReceipts.isEmpty {
            print("⚠️ No sample receipt found - creating one now")
            
            let sampleImage = createSampleReceiptImage()
            
            let lineItems = [
                ReceiptLineItem(
                    name: "ARTISAN ROLL",
                    originalPrice: 6.99,
                    discount: 0,
                    amount: 6.99,
                    taxPortion: 0.56,
                    isSelected: true
                ),
                ReceiptLineItem(
                    name: "SHIN RAMYUN",
                    originalPrice: 15.99,
                    discount: 0,
                    amount: 15.99,
                    taxPortion: 1.28,
                    isSelected: true
                ),
                ReceiptLineItem(
                    name: "1895 CHERRY TOV",
                    originalPrice: 7.49,
                    discount: 0,
                    amount: 7.49,
                    taxPortion: 0.60,
                    isSelected: true
                ),
                ReceiptLineItem(
                    name: "KS CHOPONION",
                    originalPrice: 4.39,
                    discount: 0,
                    amount: 4.39,
                    taxPortion: 0.35,
                    isSelected: true
                ),
                ReceiptLineItem(
                    name: "KIMCHI",
                    originalPrice: 7.99,
                    discount: 0,
                    amount: 7.99,
                    taxPortion: 0.64,
                    isSelected: true
                )
            ]
            
            let ocrData = OCRService.ReceiptData(
                merchant: "Sample Grocery Store",
                amounts: [42.85],
                hasReceiptStructure: true,
                confidence: 1.0,
                likelyTotal: 46.28,
                lineItems: lineItems,
                processingMethod: .tabscanner,
                receiptDate: "02/10/2026",
                taxAmount: 3.43,
                subtotal: 42.85,
                totalSavings: nil,
                isQuickResult: false,
                currency: "USD"
            )
            
            let receipt = UploadedReceipt(image: sampleImage, ocrResult: ocrData)
            appState.uploadedReceipts.append(receipt)
        }
        
        // Ensure we have at least 2 people for tutorial
        if appState.people.count == 1 {
            print("⚠️ Only 1 person - adding sample friend")
            let friend = Person(name: "Alex", isCurrentUser: false)
            appState.people.append(friend)
        }
    }
    
    private func createSampleReceiptImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 500))
        let image = renderer.image { context in
            // Background
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 500))
            
            // Header
            let headerAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 18),
                .foregroundColor: UIColor.black
            ]
            let centerX = 150.0
            "SAMPLE GROCERY".draw(
                at: CGPoint(x: centerX - 70, y: 20),
                withAttributes: headerAttributes
            )
            
            // Date
            let smallAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.darkGray
            ]
            "02/10/2026".draw(
                at: CGPoint(x: centerX - 30, y: 50),
                withAttributes: smallAttributes
            )
            
            // Divider
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 20, y: 80))
            path.addLine(to: CGPoint(x: 280, y: 80))
            UIColor.gray.setStroke()
            path.lineWidth = 1
            path.stroke()
            
            // Items
            let itemAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.black
            ]
            
            let items = [
                ("ARTISAN ROLL", "$6.99"),
                ("SHIN RAMYUN", "$15.99"),
                ("1895 CHERRY TOV", "$7.49"),
                ("KS CHOPONION", "$4.39"),
                ("KIMCHI", "$7.99")
            ]
            
            var yPos = 100.0
            for (name, price) in items {
                name.draw(at: CGPoint(x: 20, y: yPos), withAttributes: itemAttributes)
                price.draw(at: CGPoint(x: 220, y: yPos), withAttributes: itemAttributes)
                yPos += 30
            }
            
            // Subtotal
            yPos += 20
            let divider2 = UIBezierPath()
            divider2.move(to: CGPoint(x: 20, y: yPos))
            divider2.addLine(to: CGPoint(x: 280, y: yPos))
            UIColor.gray.setStroke()
            divider2.lineWidth = 1
            divider2.stroke()
            
            yPos += 15
            "SUBTOTAL".draw(at: CGPoint(x: 20, y: yPos), withAttributes: itemAttributes)
            "$42.85".draw(at: CGPoint(x: 220, y: yPos), withAttributes: itemAttributes)
            
            // Tax
            yPos += 25
            "TAX".draw(at: CGPoint(x: 20, y: yPos), withAttributes: itemAttributes)
            "$3.43".draw(at: CGPoint(x: 220, y: yPos), withAttributes: itemAttributes)
            
            // Total
            yPos += 25
            let totalAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 16),
                .foregroundColor: UIColor.black
            ]
            "TOTAL".draw(at: CGPoint(x: 20, y: yPos), withAttributes: totalAttributes)
            "$46.28".draw(at: CGPoint(x: 210, y: yPos), withAttributes: totalAttributes)
            
            // Thank you
            yPos += 50
            "THANK YOU!".draw(
                at: CGPoint(x: centerX - 45, y: yPos),
                withAttributes: smallAttributes
            )
        }
        
        return image
    }
    
    private func createTransactionsFromProcessedData() {
        print("\n=== CREATING TRANSACTIONS FROM PRE-PROCESSED DATA ===")
        
        guard let currentUser = appState.people.first(where: { $0.isCurrentUser }) else {
            print("ERROR: No current user found")
            return
        }
        
        // Process receipts — use makeTransaction so backgroundResultToken is always threaded through
        for (index, receipt) in appState.uploadedReceipts.enumerated() {
            currentItem = index + 1
            
            print("\nProcessing receipt \(currentItem):")
            print("  Merchant: \(receipt.merchant)")
            print("  Total: $\(receipt.total)")
            print("  Line items: \(receipt.lineItems.count)")
            print("  Background token: \(receipt.backgroundResultToken?.prefix(8) ?? "none")…")
            print("  Image size: \(receipt.image.size)")
            print("  Using ORIGINAL image data (\(receipt.imageData.count) bytes)")
            
            let transaction = appState.makeTransaction(from: receipt)
            
            print("  ✓ Transaction created with amount: $\(transaction.amount)")
            print("  ✓ Line items stored: \(transaction.lineItems.count)")
            print("  ✓ Background token: \(transaction.backgroundResultToken?.prefix(8) ?? "none")…")
            appState.transactions.append(transaction)
        }
        
        // Process manual entries
        for (index, manual) in appState.manualTransactions.enumerated() {
            currentItem = appState.uploadedReceipts.count + index + 1
            
            print("\nProcessing manual entry \(currentItem - appState.uploadedReceipts.count):")
            print("  Name: \(manual.name)")
            print("  Amount: $\(manual.amount)")
            
            let transaction = Transaction(
                amount: manual.amount,
                merchant: manual.name,
                paidBy: currentUser,
                splitWith: appState.people,
                receiptImage: nil,
                includeInSplit: true,
                isManual: true,
                lineItems: []
            )
            
            print("  ✓ Transaction created")
            appState.transactions.append(transaction)
        }
        
        print("\n=== TRANSACTIONS CREATED ===")
        print("Total transactions: \(appState.transactions.count)")
        
        // Clear temporary data
        appState.uploadedReceipts.removeAll()
        appState.uploadedImages.removeAll()
        appState.manualTransactions.removeAll()
        
        print("Cleared temporary upload data")
        print("=== PROCESSING COMPLETE ===\n")
    }
}
