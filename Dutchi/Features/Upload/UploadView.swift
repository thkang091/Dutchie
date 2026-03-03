import SwiftUI
import PhotosUI
import UIKit

struct UploadedTransaction: Identifiable {
    let id = UUID()
    let image: UIImage
    let accountType: OCRService.AccountType
    let items: [OCRService.TransactionItem]
    let totalDebits: Double
    let totalCredits: Double
}

struct UploadView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    @EnvironmentObject var tutorialManager: TutorialManager
    @Environment(\.colorScheme) var colorScheme

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showManualEntry = false
    @State private var manualItemName = ""
    @State private var manualItemAmount = ""
    @State private var showReceiptViewer = false
    @State private var selectedReceiptForViewing: UploadedReceipt?
    @State private var showTransactionViewer = false
    @State private var selectedTransactionForViewing: UploadedTransaction?
    @State private var showPhotoOptions = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showAccountTypePrompt = false
    @State private var uploadedTransactions: [UploadedTransaction] = []
    @State private var uploadType: OCRService.DocumentType = .unknown
    @State private var showInvalidReceiptAlert = false
    @State private var invalidReceiptMessage = ""
    @State private var isProcessingImage = false
    @State private var processingMessage = "Validating receipt..."
    @State private var processingSubtitle: String? = nil   // shown below main message for low-quality path
    @State private var isLowQualityGPTMode = false         // drives the amber warning banner
    @State private var showUnsavedItemAlert = false
    @State private var sharedImageObserver: NSObjectProtocol?
    @State private var processingToken: Int = 0
    @State private var batchQueue: [UIImage] = []
    @State private var batchTotal: Int = 0
    @State private var batchDone: Int = 0
    @State private var batchErrors: [String] = []
    @State private var showUploadTutorial = false
    @State private var uploadTutorialMode: ScanTutorialMode = .receipt
    @State private var pendingAction: (() -> Void)? = nil

    private func processImages(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        batchQueue = images
        batchTotal = images.count
        batchDone = 0
        batchErrors = []
        isProcessingImage = true
        isLowQualityGPTMode = false
        processingSubtitle = nil
        updateBatchMessage()
        setupOCRStatusCallback()
        processNextInQueue()
    }

    private func processImage(_ image: UIImage) {
        processImages([image])
    }

    /// Registers the OCRService status callback so UploadView knows when the pipeline
    /// switches into "poor quality → GPT" mode and can update the UI accordingly.
    private func setupOCRStatusCallback() {
        OCRService.onStatusUpdate = { [self] status in
            DispatchQueue.main.async {
                if let status = status, status.hasPrefix("low_quality_gpt:") {
                    let detail = String(status.dropFirst("low_quality_gpt:".count))
                    withAnimation(.spring(response: 0.3)) {
                        isLowQualityGPTMode = true
                        processingMessage   = "This is taking a bit longer…"
                        processingSubtitle  = "The receipt isn't very clear, so we're having AI read it carefully. It'll be ready in a few seconds."
                    }
                } else {
                    // "done" or nil — reset
                    withAnimation(.spring(response: 0.3)) {
                        isLowQualityGPTMode = false
                        processingSubtitle  = nil
                    }
                }
            }
        }
    }

    private func updateBatchMessage() {
        guard !isLowQualityGPTMode else { return } // don't overwrite the low-quality message
        if batchTotal == 1 {
            processingMessage = uploadType == .transactionHistory
                ? "Reading transactions..."
                : "Reading receipt..."
        } else {
            processingMessage = uploadType == .transactionHistory
                ? "Reading statement \(batchDone + 1) of \(batchTotal)..."
                : "Reading receipt \(batchDone + 1) of \(batchTotal)..."
        }
    }

    private func processNextInQueue() {
        guard !batchQueue.isEmpty else {
            withAnimation(.spring(response: 0.3)) {
                isProcessingImage = false
                isLowQualityGPTMode = false
                processingSubtitle = nil
            }
            OCRService.onStatusUpdate = nil
            if !batchErrors.isEmpty {
                invalidReceiptMessage = batchErrors.count == 1
                    ? batchErrors[0]
                    : "\(batchErrors.count) photos didn't look like receipts or statements. Please retake them."
                showInvalidReceiptAlert = true
            }
            batchErrors = []
            return
        }

        let image = batchQueue.removeFirst()
        let capturedToken = processingToken

        // Reset low-quality mode for each new image in the batch
        withAnimation(.spring(response: 0.3)) {
            isLowQualityGPTMode = false
            processingSubtitle = nil
        }
        updateBatchMessage()

        OCRService.processDocument(from: image, hint: uploadType) { result in
            DispatchQueue.main.async {
                guard processingToken == capturedToken else { return }
                batchDone += 1

                // Reset low-quality state after each image finishes
                withAnimation(.spring(response: 0.3)) {
                    isLowQualityGPTMode = false
                    processingSubtitle = nil
                }
                updateBatchMessage()

                switch result {
                case .success(let data):
                    if let receiptData = data as? OCRService.ReceiptData {
                        handleReceiptData(receiptData, image: image)
                    } else if let transactionData = data as? OCRService.TransactionData {
                        handleTransactionData(transactionData, image: image)
                    }
                case .failure:
                    batchErrors.append("Image \(batchDone) of \(batchTotal): doesn't look like a receipt or statement. Please retake.")
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard processingToken == capturedToken else { return }
                    processNextInQueue()
                }
            }
        }
    }

    private func cancelProcessing() {
        processingToken += 1
        batchQueue = []
        batchErrors = []
        OCRService.onStatusUpdate = nil
        OCRService.cancelAccountTypeSelection()
        withAnimation(.spring(response: 0.3)) {
            isProcessingImage = false
            showAccountTypePrompt = false
            isLowQualityGPTMode = false
            processingSubtitle = nil
        }
    }

    private func handleReceiptData(_ receiptData: OCRService.ReceiptData, image: UIImage) {
        let validation = validateReceiptData(receiptData)
        if !validation.valid {
            invalidReceiptMessage = validation.message
            showInvalidReceiptAlert = true
            return
        }

        var reconciledData = receiptData
        reconciledData = reconcileTotalWithItems(reconciledData)

        assert(
            reconciledData.backgroundResultToken == receiptData.backgroundResultToken,
            "reconcileTotalWithItems dropped the backgroundResultToken — fix that function"
        )

        let receipt = UploadedReceipt(image: image, ocrResult: reconciledData)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            appState.uploadedReceipts.append(receipt)
        }
    }

    private func reconcileTotalWithItems(_ data: OCRService.ReceiptData) -> OCRService.ReceiptData {
        guard let total = data.likelyTotal, total > 0, !data.lineItems.isEmpty else { return data }
        var items = data.lineItems
        items.removeAll { $0.name == "Missing Item(s)" }
        let cleanSum = items.reduce(0.0) { $0 + $1.amount }
        let cleanGap = round((total - cleanSum) * 100) / 100
        if abs(cleanGap) > 0.01 {
            items.append(ReceiptLineItem(
                name: "Missing Item(s)",
                originalPrice: cleanGap,
                discount: 0,
                amount: cleanGap,
                taxPortion: 0,
                isSelected: true
            ))
        }
        var result = data
        result.lineItems = items
        return result
    }

    private func handleTransactionData(_ transactionData: OCRService.TransactionData, image: UIImage) {
        let validation = validateTransactionData(transactionData)
        if !validation.valid {
            invalidReceiptMessage = validation.message
            showInvalidReceiptAlert = true
            return
        }

        let debitTransactions = transactionData.items.filter { $0.isDebit }
        let uploadedTransaction = UploadedTransaction(
            image: image,
            accountType: transactionData.accountType,
            items: debitTransactions,
            totalDebits: transactionData.totalDebits,
            totalCredits: transactionData.totalCredits
        )

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            uploadedTransactions.append(uploadedTransaction)
        }

        for transaction in debitTransactions {
            appState.manualTransactions.append((name: transaction.description, amount: transaction.amount))
        }
    }

    private func validateReceiptData(_ data: OCRService.ReceiptData) -> (valid: Bool, message: String) {
        let hasAmount = !data.amounts.isEmpty || (data.likelyTotal ?? 0) > 0
        if !hasAmount {
            return (false, "This doesn't look like a receipt or transaction statement. Please retake the photo.")
        }
        let minConfidence: Float
        switch data.processingMethod {
        case .tabscanner:         minConfidence = 0.50
        case .gptMini, .gptFourO: minConfidence = 0.45
        case .visionFallback:     minConfidence = 0.35
        }
        if data.confidence < minConfidence {
            return (false, "This doesn't look like a receipt or transaction statement. Please retake the photo.")
        }
        if data.processingMethod == .tabscanner {
            if data.merchant.isEmpty && !data.hasReceiptStructure {
                return (false, "This doesn't look like a receipt or transaction statement. Please retake the photo.")
            }
        }
        return (true, "")
    }

    private func validateTransactionData(_ data: OCRService.TransactionData) -> (valid: Bool, message: String) {
        if data.items.isEmpty {
            return (false, "This doesn't look like a receipt or transaction statement. Please retake the photo.")
        }
        let debitTransactions = data.items.filter { $0.isDebit }
        if debitTransactions.isEmpty {
            return (false, "This doesn't look like a receipt or transaction statement. Please retake the photo.")
        }
        if data.confidence < 0.4 {
            return (false, "This doesn't look like a receipt or transaction statement. Please retake the photo.")
        }
        if data.totalDebits < 0.01 {
            return (false, "This doesn't look like a receipt or transaction statement. Please retake the photo.")
        }
        return (true, "")
    }

    private var shouldHighlightProfileButton: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .profileButton
    }
    private var shouldHighlightNextButton: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .nextButton
    }
    private var isUploadAndManualMultiSpotlight: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .uploadAndManual
    }

    var totalAmount: Double {
        let receiptTotal = appState.uploadedReceipts.reduce(0.0) { $0 + $1.total }
        let manualTotal = appState.manualTransactions.reduce(0.0) { $0 + $1.amount }
        return receiptTotal + manualTotal
    }

    var totalItems: Int {
        let receiptItems = appState.uploadedReceipts.reduce(0) { $0 + ($1.lineItems.isEmpty ? 0 : $1.lineItems.count) }
        let manualItems = appState.manualTransactions.count
        return receiptItems + manualItems
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            mainContent.zIndex(1)

            if isProcessingImage {
                loadingOverlay.zIndex(50)
            }

            if showReceiptViewer, let receipt = selectedReceiptForViewing {
                fullScreenReceiptViewer(receipt: receipt)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(100)
            }

            if showTransactionViewer, let transaction = selectedTransactionForViewing {
                fullScreenTransactionViewer(transaction: transaction)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(100)
            }

            if showAccountTypePrompt {
                accountTypePrompt.zIndex(200)
            }

            if showUploadTutorial {
                CameraOverlayView(
                    isVisible: $showUploadTutorial,
                    mode: uploadTutorialMode
                ) {
                    pendingAction?()
                    pendingAction = nil
                }
                .transition(.opacity)
                .zIndex(250)
            }

            if tutorialManager.isActive {
                TutorialOverlay(context: .upload).zIndex(300)
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            setupAccountTypeListener()
            setupSharedImageListener()
            if !tutorialManager.isActive && !tutorialManager.hasCompletedTutorial {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tutorialManager.start() }
            }
        }
        .onChange(of: selectedPhotos) { _, newPhotos in loadPhotos(newPhotos) }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let image = image { processImage(image) }
                showCamera = false
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showPhotoPicker) {
            MultiImagePicker { images in
                if !images.isEmpty { processImages(images) }
            }
        }
        .alert("Invalid Photo", isPresented: $showInvalidReceiptAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(invalidReceiptMessage)
        }
        .alert("Unsaved Item", isPresented: $showUnsavedItemAlert) {
            Button("Discard", role: .destructive) {
                manualItemName = ""
                manualItemAmount = ""
                router.navigateToPeople()
            }
            Button("Add Item", role: .cancel) {}
        } message: {
            Text("You have an unsaved item in manual entry. Would you like to add it before continuing?")
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            headerSection
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 24) {
                    if totalAmount > 0 { summaryCard }
                    uploadSectionCombined
                    if !appState.uploadedReceipts.isEmpty { receiptThumbnailsSection }
                    if !uploadedTransactions.isEmpty { transactionThumbnailsSection }
                    manualEntrySection
                }
                .padding(20)
                .padding(.bottom, 100)
            }
            .zIndex(0)
            bottomCTA.zIndex(0)
        }
    }

    private var headerSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Items")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.primary)
                    Text("Upload receipts or add manually")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: {
                    HapticManager.impact(style: .light)
                    router.showProfile = true
                }) {
                    AvatarView(
                        imageData: appState.profile.avatarImage,
                        initials: appState.profile.initials,
                        size: 44
                    )
                    .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 2))
                    .shadow(color: Color.primary.opacity(0.1), radius: 8, y: 4)
                }
                .buttonStyle(ScaleButtonStyle())
                .tutorialSpotlight(isHighlighted: shouldHighlightProfileButton, cornerRadius: 22)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .background(Color(.systemBackground))
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Total Amount")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                Text(String(format: "$%.2f", totalAmount))
                    .font(.system(size: 28, weight: .bold)).foregroundColor(.primary)
            }
            Spacer()
            HStack(spacing: 16) {
                if !appState.uploadedReceipts.isEmpty {
                    summaryStatItem(icon: "receipt", value: "\(appState.uploadedReceipts.count)", label: "Receipts")
                }
                if !uploadedTransactions.isEmpty {
                    summaryStatItem(icon: "list.bullet.rectangle", value: "\(uploadedTransactions.count)", label: "Statements")
                }
            }
        }
        .padding(24)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(20)
        .shadow(color: Color.primary.opacity(0.08), radius: 16, y: 8)
    }

    private func summaryStatItem(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 16, weight: .bold)).foregroundColor(.primary)
                Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            }
        }
    }

    private var uploadSectionCombined: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Upload", icon: "arrow.up.doc")
            HStack(spacing: 12) {
                uploadTypeButton(
                    title: "Receipt",
                    subtitle: "Store, restaurant,\ncafe receipts",
                    icon: "receipt",
                    type: .receipt
                ) {
                    uploadType = .receipt
                    showPhotoOptions = true
                }
                uploadTypeButton(
                    title: "Transactions",
                    subtitle: "Bank or card\nstatement",
                    icon: "list.bullet.rectangle",
                    type: .transactionHistory
                ) {
                    uploadType = .transactionHistory
                    showPhotoOptions = true
                }
            }
        }
        .tutorialMultiSpotlight(target: .uploadSection, isActive: isUploadAndManualMultiSpotlight)
        .confirmationDialog(
            uploadType == .transactionHistory ? "Add Transaction Statement" : "Add Receipt Photo",
            isPresented: $showPhotoOptions,
            titleVisibility: .visible
        ) {
            Button("Take Photo") {
                uploadTutorialMode = uploadType == .transactionHistory ? .transaction : .receipt
                pendingAction = { showCamera = true }
                showUploadTutorial = true
            }
            Button("Choose from Gallery") {
                uploadTutorialMode = uploadType == .transactionHistory ? .transaction : .receipt
                pendingAction = { showPhotoPicker = true }
                showUploadTutorial = true
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func uploadTypeButton(
        title: String,
        subtitle: String,
        icon: String,
        type: OCRService.DocumentType,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            HapticManager.impact(style: .medium)
            action()
        }) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 56, height: 56)
                    Image(systemName: icon)
                        .font(.system(size: 24))
                        .foregroundColor(.primary.opacity(0.7))
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 8)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.1),
                            style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            )
            .shadow(color: Color.primary.opacity(0.04), radius: 8, y: 4)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
        .disabled(isProcessingImage)
        .opacity(isProcessingImage ? 0.6 : 1.0)
    }

    private var receiptThumbnailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Receipts", icon: "receipt")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                ForEach(Array(appState.uploadedReceipts.enumerated()), id: \.offset) { index, receipt in
                    receiptThumbnail(receipt: receipt, index: index)
                }
            }
        }
    }

    private func receiptThumbnail(receipt: UploadedReceipt, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Button(action: {
                HapticManager.impact(style: .light)
                selectedReceiptForViewing = receipt
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showReceiptViewer = true }
            }) {
                VStack(spacing: 8) {
                    Image(uiImage: receipt.image)
                        .resizable().scaledToFill()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    VStack(spacing: 2) {
                        Text(receipt.merchant.isEmpty ? "Receipt" : receipt.merchant)
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).lineLimit(1)
                        Text(String(format: "$%.2f", receipt.total))
                            .font(.system(size: 14, weight: .bold)).foregroundColor(.primary)
                        // Show warning badge if quality was poor
                        if let warn = receipt.imageQualityWarning, !warn.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(.orange)
                                Text("Low quality")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .shadow(color: Color.primary.opacity(0.06), radius: 8, y: 4)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.96))

            Button(action: {
                HapticManager.notification(type: .warning)
                withAnimation(.spring(response: 0.3)) { _ = appState.uploadedReceipts.remove(at: index) }
            }) {
                ZStack {
                    Circle().fill(Color.red).frame(width: 28, height: 28)
                        .shadow(color: Color.primary.opacity(0.3), radius: 6, y: 2)
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                }
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.9))
            .offset(x: 4, y: -4)
        }
    }

    private var transactionThumbnailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Transaction Statements", icon: "list.bullet.rectangle")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                ForEach(Array(uploadedTransactions.enumerated()), id: \.offset) { index, transaction in
                    transactionThumbnail(transaction: transaction, index: index)
                }
            }
        }
    }
    
    private struct SpinningCoinView: View {
        @State private var scaleX: CGFloat = 1.0
        @State private var isFrontFace = true

        var body: some View {
            ZStack {
                Circle()
                    .fill(isFrontFace ? Color(white: 0.12) : Color.white)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1.5))
                    .overlay(
                        Text("$")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(isFrontFace ? .white : Color(white: 0.12))
                    )
            }
            .scaleEffect(x: scaleX, y: 1.0)
            .onAppear { startFlipping() }
        }

        private func startFlipping() {
            func halfFlip(to target: CGFloat, duration: Double, then next: @escaping () -> Void) {
                withAnimation(.easeIn(duration: duration)) { scaleX = target }
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { next() }
            }
            func loop() {
                halfFlip(to: 0, duration: 0.22) {
                    isFrontFace.toggle()
                    halfFlip(to: 1, duration: 0.22) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { loop() }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { loop() }
        }
    }

    private func transactionThumbnail(transaction: UploadedTransaction, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Button(action: {
                HapticManager.impact(style: .light)
                selectedTransactionForViewing = transaction
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showTransactionViewer = true }
            }) {
                VStack(spacing: 8) {
                    Image(uiImage: transaction.image)
                        .resizable().scaledToFill()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    VStack(spacing: 2) {
                        Text(transaction.accountType == .creditCard ? "Credit Card" : "Debit Card")
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).lineLimit(1)
                        Text(String(format: "$%.2f", transaction.totalDebits))
                            .font(.system(size: 14, weight: .bold)).foregroundColor(.primary)
                        Text("\(transaction.items.count) items")
                            .font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .shadow(color: Color.primary.opacity(0.06), radius: 8, y: 4)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.96))

            Button(action: {
                HapticManager.notification(type: .warning)
                deleteTransaction(at: index)
            }) {
                ZStack {
                    Circle().fill(Color.red).frame(width: 28, height: 28)
                        .shadow(color: Color.primary.opacity(0.3), radius: 6, y: 2)
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                }
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.9))
            .offset(x: 4, y: -4)
        }
    }

    private func fullScreenReceiptViewer(receipt: UploadedReceipt) -> some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showReceiptViewer = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { selectedReceiptForViewing = nil }
                }
            VStack(spacing: 20) {
                Spacer()
                Image(uiImage: receipt.image)
                    .resizable().aspectRatio(contentMode: .fit).cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.5), radius: 20, y: 10).padding(.horizontal, 20)
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.15)).frame(width: 48, height: 48)
                            Image(systemName: "receipt").font(.system(size: 20)).foregroundColor(.white)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(receipt.merchant.isEmpty ? "Receipt" : receipt.merchant)
                                .font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
                            if !receipt.lineItems.isEmpty {
                                Text("\(receipt.lineItems.count) items")
                                    .font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.7))
                            }
                        }
                        Spacer()
                        Text(String(format: "$%.2f", receipt.total))
                            .font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                    }
                    // Show image quality warning if present
                    if let warn = receipt.imageQualityWarning, !warn.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.orange)
                            Text(warn)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.75))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(10)
                    }
                }
                .padding(20).background(Color.white.opacity(0.1)).cornerRadius(16).padding(.horizontal, 20)
                Spacer()
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        HapticManager.impact(style: .light)
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showReceiptViewer = false }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { selectedReceiptForViewing = nil }
                    }) {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.15)).frame(width: 44, height: 44)
                                .background(Circle().fill(.ultraThinMaterial))
                            Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        }
                    }
                    .buttonStyle(ScaleButtonStyle()).padding(20)
                }
                Spacer()
            }
        }
    }

    private func fullScreenTransactionViewer(transaction: UploadedTransaction) -> some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Image(uiImage: transaction.image)
                    .resizable().aspectRatio(contentMode: .fit).cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.5), radius: 20, y: 10)
                    .padding(.horizontal, 20).frame(maxHeight: 300)
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.15)).frame(width: 48, height: 48)
                            Image(systemName: transaction.accountType == .creditCard ? "creditcard.fill" : "banknote.fill")
                                .font(.system(size: 20)).foregroundColor(.white)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(transaction.accountType == .creditCard ? "Credit Card" : "Debit Card")
                                .font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
                            Text("\(transaction.items.count) transactions · $\(String(format: "%.2f", transaction.totalDebits)) spent")
                                .font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.7))
                        }
                        Spacer()
                        Text(String(format: "$%.2f", transaction.totalDebits))
                            .font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(transaction.items.enumerated()), id: \.offset) { _, item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.description)
                                            .font(.system(size: 14, weight: .medium)).foregroundColor(.white)
                                        if let date = item.date {
                                            Text(date).font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
                                        }
                                    }
                                    Spacer()
                                    Text(String(format: "$%.2f", item.amount))
                                        .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                                }
                                .padding(12).background(Color.white.opacity(0.1)).cornerRadius(8)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }
                .padding(20).background(Color.white.opacity(0.1)).cornerRadius(16).padding(.horizontal, 20)
                Spacer()
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        HapticManager.impact(style: .light)
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showTransactionViewer = false }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { selectedTransactionForViewing = nil }
                    }) {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.15)).frame(width: 44, height: 44)
                                .background(Circle().fill(.ultraThinMaterial))
                            Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        }
                    }
                    .buttonStyle(ScaleButtonStyle()).padding(20)
                }
                Spacer()
            }
        }
    }

    private var manualEntrySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            manualEntryToggle
            if showManualEntry {
                VStack(spacing: 16) {
                    addNewItemCard
                    if !appState.manualTransactions.isEmpty { addedItemsList }
                }
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.95, anchor: .top).combined(with: .opacity),
                    removal: .scale(scale: 0.95, anchor: .top).combined(with: .opacity)
                ))
            }
        }
    }

    private var manualEntryToggle: some View {
        Button(action: {
            HapticManager.impact(style: .light)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showManualEntry.toggle() }
        }) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)).frame(width: 48, height: 48)
                    Image(systemName: "keyboard").font(.system(size: 20, weight: .semibold)).foregroundColor(.primary.opacity(0.7))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Manual Entry").font(.system(size: 18, weight: .bold)).foregroundColor(.primary)
                    if !showManualEntry && !appState.manualTransactions.isEmpty {
                        Text("\(appState.manualTransactions.count) item\(appState.manualTransactions.count == 1 ? "" : "s") added")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
                    } else if !showManualEntry {
                        Text("Add items without receipt")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.secondary)
                    .rotationEffect(.degrees(showManualEntry ? 180 : 0))
            }
            .padding(16).background(Color(.secondarySystemBackground)).cornerRadius(16)
            .shadow(color: Color.primary.opacity(0.04), radius: 8, y: 4)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
        .tutorialMultiSpotlight(target: .manualEntry, isActive: isUploadAndManualMultiSpotlight)
    }

    private var addNewItemCard: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Item Name")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary).textCase(.uppercase).tracking(0.8)
                TextField("e.g., Dinner, Movie tickets", text: $manualItemName)
                    .font(.system(size: 16, weight: .medium)).padding(16)
                    .background(Color(.tertiarySystemBackground)).cornerRadius(14)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Amount")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary).textCase(.uppercase).tracking(0.8)
                    HStack(spacing: 8) {
                        Text("$").font(.system(size: 20, weight: .bold)).foregroundColor(.secondary)
                        TextField("0.00", text: $manualItemAmount)
                            .font(.system(size: 16, weight: .medium)).keyboardType(.decimalPad)
                    }
                    .padding(16).background(Color(.tertiarySystemBackground)).cornerRadius(14)
                }
                VStack {
                    Spacer()
                    Button(action: { HapticManager.impact(style: .medium); addManualItem() }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(canAddItem ? Color.accentColor : Color.primary.opacity(0.3))
                                .frame(width: 56, height: 56)
                            Image(systemName: "plus").font(.system(size: 22, weight: .bold)).foregroundColor(.white)
                        }
                    }
                    .buttonStyle(ScaleButtonStyle(scale: 0.92)).disabled(!canAddItem)
                }
            }
        }
        .padding(20).background(Color(.secondarySystemBackground)).cornerRadius(18)
        .shadow(color: Color.primary.opacity(0.06), radius: 12, y: 6)
    }

    private var addedItemsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Added Items").font(.system(size: 15, weight: .semibold)).foregroundColor(.secondary).padding(.horizontal, 4)
            VStack(spacing: 10) {
                ForEach(Array(appState.manualTransactions.enumerated()), id: \.offset) { index, item in
                    addedItemRow(item: item, index: index)
                }
            }
        }
    }

    private func addedItemRow(item: (name: String, amount: Double), index: Int) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.08)).frame(width: 40, height: 40)
                Text("\(index + 1)").font(.system(size: 14, weight: .bold)).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)
                Text(String(format: "$%.2f", item.amount)).font(.system(size: 18, weight: .bold)).foregroundColor(.primary)
            }
            Spacer()
            Button(action: { HapticManager.notification(type: .warning); deleteManualTransaction(at: index) }) {
                Image(systemName: "trash.fill").font(.system(size: 15)).foregroundColor(.white)
                    .frame(width: 40, height: 40).background(Color.red).cornerRadius(12)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.9))
        }
        .padding(16).background(Color(.secondarySystemBackground)).cornerRadius(14)
        .shadow(color: Color.primary.opacity(0.04), radius: 6, y: 3)
    }

    @ViewBuilder
    private var accountTypePrompt: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 48)).foregroundColor(.primary.opacity(0.7))
                    Text("What type of account is this?")
                        .font(.system(size: 22, weight: .bold)).foregroundColor(.primary).multilineTextAlignment(.center)
                    Text("This helps us correctly identify\nyour spending transactions")
                        .font(.system(size: 15, weight: .medium)).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 20)
                }
                VStack(spacing: 12) {
                    accountTypeButton(title: "Credit Card", description: "Purchases increase balance", icon: "creditcard.fill", accountType: .creditCard)
                    accountTypeButton(title: "Debit Card", description: "Purchases decrease balance", icon: "banknote.fill", accountType: .debitCard)
                }
                Button(action: {
                    HapticManager.impact(style: .light)
                    OCRService.cancelAccountTypeSelection()
                    withAnimation(.spring(response: 0.3)) {
                        showAccountTypePrompt = false
                        isProcessingImage = false
                    }
                }) {
                    Text("Cancel").font(.system(size: 16, weight: .semibold)).foregroundColor(.secondary).padding(.top, 8)
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(.systemBackground))
                    .shadow(color: Color.primary.opacity(0.2), radius: 20, y: 10)
            )
            .padding(.horizontal, 40)
        }
        .transition(.opacity)
    }

    private func accountTypeButton(title: String, description: String, icon: String, accountType: OCRService.AccountType) -> some View {
        Button(action: { HapticManager.impact(style: .medium); handleAccountTypeSelection(accountType) }) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.08)).frame(width: 56, height: 56)
                    Image(systemName: icon).font(.system(size: 24)).foregroundColor(.primary.opacity(0.7))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 18, weight: .bold)).foregroundColor(.primary)
                    Text(description).font(.system(size: 14, weight: .medium)).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundColor(.secondary)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.1), lineWidth: 2))
            )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.97))
    }

    private var bottomCTA: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            Button(action: {
                HapticManager.impact(style: .medium)
                if hasUnsavedManualEntry { showUnsavedItemAlert = true }
                else { router.navigateToPeople() }
            }) {
                HStack(spacing: 8) {
                    Text("Next").font(.system(size: 17, weight: .semibold))
                    Image(systemName: "arrow.right").font(.system(size: 14, weight: .bold))
                }
                .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 18)
                .background(Color.accentColor).cornerRadius(16)
                .shadow(color: Color.accentColor.opacity(0.3), radius: 12, y: 4)
            }
            .buttonStyle(ScaleButtonStyle())
            .tutorialSpotlight(isHighlighted: shouldHighlightNextButton, cornerRadius: 16)
            .padding(20)
            .background(Color(.systemBackground).shadow(color: Color.primary.opacity(0.05), radius: 20, y: -5))
        }
    }

    // MARK: - Loading Overlay
    //
    // Shows different UI depending on whether we're in normal or low-quality GPT mode:
    //   Normal:    spinner + "Reading receipt…" + progress bar (batch)
    //   Low quality: amber warning icon + "This is taking a bit longer…" + subtitle explanation

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
                .onTapGesture { cancelProcessing() }

            VStack(spacing: 20) {
                // Close button
                HStack {
                    Spacer()
                    Button(action: { HapticManager.impact(style: .light); cancelProcessing() }) {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.15)).frame(width: 32, height: 32)
                            Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                        }
                    }
                    .buttonStyle(ScaleButtonStyle(scale: 0.9))
                }

                if isLowQualityGPTMode {
                    // ── Low-quality GPT path ─────────────────────────────────────
                    VStack(spacing: 16) {
                        SpinningCoinView()
                            .frame(width: 56, height: 56)

                        Text(processingMessage)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)

                        if let subtitle = processingSubtitle {
                            Text(subtitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.75))
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))


                } else {
                    // ── Normal processing path ───────────────────────────────────
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)

                    Text(processingMessage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .animation(.spring(response: 0.3), value: processingMessage)

                    if batchTotal > 1 {
                        VStack(spacing: 8) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white.opacity(0.2))
                                        .frame(height: 6)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white)
                                        .frame(
                                            width: batchTotal > 0
                                                ? geo.size.width * CGFloat(batchDone) / CGFloat(batchTotal)
                                                : 0,
                                            height: 6
                                        )
                                        .animation(.spring(response: 0.4), value: batchDone)
                                }
                            }
                            .frame(height: 6)
                            Text("\(batchDone) of \(batchTotal) done")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                }

                Text("Tap to cancel")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.9)))
            .padding(.horizontal, 50)
            .animation(.spring(response: 0.35), value: isLowQualityGPTMode)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: isProcessingImage)
    }

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundColor(.secondary)
            Text(title).font(.system(size: 20, weight: .bold)).foregroundColor(.primary)
        }
        .padding(.leading, 2)
    }

    private var canAddItem: Bool { !manualItemName.isEmpty && Double(manualItemAmount) ?? 0 > 0 }
    private var hasUnsavedManualEntry: Bool { !manualItemName.isEmpty || !manualItemAmount.isEmpty }

    private func setupAccountTypeListener() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RequestAccountType"),
            object: nil,
            queue: .main
        ) { _ in
            withAnimation(.spring(response: 0.3)) {
                isProcessingImage = false
                showAccountTypePrompt = true
            }
        }
    }

    private func setupSharedImageListener() {
        guard sharedImageObserver == nil else { return }
        sharedImageObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProcessSharedImage"),
            object: nil,
            queue: .main
        ) { notification in
            if let image = notification.object as? UIImage {
                uploadType = .receipt
                processImage(image)
            }
        }
    }

    private func handleAccountTypeSelection(_ accountType: OCRService.AccountType) {
        withAnimation(.spring(response: 0.3)) { showAccountTypePrompt = false }
        isProcessingImage = true
        processingMessage = "Processing transactions..."
        OCRService.setAccountType(accountType)
    }

    private func loadPhotos(_ photos: [PhotosPickerItem]) {
        for photo in photos {
            photo.loadTransferable(type: Data.self) { result in
                DispatchQueue.main.async {
                    if case .success(let data) = result, let data, let image = UIImage(data: data) {
                        processImage(image)
                    }
                }
            }
        }
        selectedPhotos = []
    }

    private func addManualItem() {
        guard !manualItemName.isEmpty, let amount = Double(manualItemAmount), amount > 0 else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            appState.manualTransactions.append((name: manualItemName, amount: amount))
            manualItemName = ""
            manualItemAmount = ""
        }
    }

    private func deleteTransaction(at index: Int) {
        guard index < uploadedTransactions.count else { return }
        let transaction = uploadedTransactions[index]
        withAnimation(.spring(response: 0.3)) {
            uploadedTransactions.remove(at: index)
            for item in transaction.items {
                if let i = appState.manualTransactions.firstIndex(where: { $0.name == item.description && $0.amount == item.amount }) {
                    appState.manualTransactions.remove(at: i)
                }
            }
        }
    }

    private func deleteManualTransaction(at index: Int) {
        guard index < appState.manualTransactions.count else { return }
        let item = appState.manualTransactions[index]
        withAnimation(.spring(response: 0.3)) {
            appState.manualTransactions.remove(at: index)
            for (transIndex, transaction) in uploadedTransactions.enumerated().reversed() {
                let wasPartOf = transaction.items.contains(where: { $0.description == item.name && $0.amount == item.amount })
                if wasPartOf {
                    let remaining = transaction.items.filter { transItem in
                        appState.manualTransactions.contains(where: { $0.name == transItem.description && $0.amount == transItem.amount })
                    }.count
                    if remaining == 0 { uploadedTransactions.remove(at: transIndex) }
                }
            }
        }
    }
}

// NOTE: UploadedReceipt needs to expose its OCR result for the quality warning badge.
// Add this extension or add `ocrResult: OCRService.ReceiptData?` to UploadedReceipt.
// If UploadedReceipt is defined elsewhere, add the property there:
//
//   var ocrResult: OCRService.ReceiptData?
//
// and set it in UploadedReceipt.init(image:ocrResult:).

struct CameraPicker: UIViewControllerRepresentable {
    let onImagePicked: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let controller = CameraViewController()
        controller.onImagePicked = onImagePicked
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}

class CameraViewController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    var onImagePicked: ((UIImage?) -> Void)?
    private var imagePicker: UIImagePickerController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    private func setupCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            onImagePicked?(nil)
            return
        }

        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        picker.modalPresentationStyle = .fullScreen
        picker.showsCameraControls = true
        imagePicker = picker

        addChild(picker)
        picker.view.frame = view.bounds
        picker.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(picker.view)
        picker.didMove(toParent: self)
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        let image = info[.originalImage] as? UIImage
        dismiss(animated: true) { [weak self] in
            self?.onImagePicked?(image)
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        dismiss(animated: true) { [weak self] in
            self?.onImagePicked?(nil)
        }
    }
}

struct MultiImagePicker: UIViewControllerRepresentable {
    let onImagesPicked: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 0
        config.filter = .images
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MultiImagePicker
        init(_ parent: MultiImagePicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }

            var images: [UIImage?] = Array(repeating: nil, count: results.count)
            let group = DispatchGroup()

            for (index, result) in results.enumerated() {
                group.enter()
                result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                    images[index] = object as? UIImage
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                self.parent.onImagesPicked(images.compactMap { $0 })
            }
        }
    }
}
