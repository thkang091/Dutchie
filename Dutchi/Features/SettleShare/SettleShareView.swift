import SwiftUI
import UIKit
import Messages
import MessageUI
import UserNotifications


// MARK: - Message Compose Coordinator
class MessageComposeCoordinator: NSObject, MFMessageComposeViewControllerDelegate {
    static let shared = MessageComposeCoordinator()

    func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        controller.dismiss(animated: true)
    }
}


struct SettleShareView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    @Environment(\.colorScheme) var colorScheme
    
    @State private var settlements: [PaymentLink] = []
    @State private var showShareSheet = false
    @State private var showCopyToast = false
    @State private var selectedSettlementId: UUID?
    @EnvironmentObject var tutorialManager: TutorialManager
    @State private var showAmountCopiedBanner = false
    @State private var copiedAmount = ""
    @State private var canSendText = MFMessageComposeViewController.canSendText()
    @State private var transactionIDs: [UUID] = []
    
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var hasAppeared = false
    
    // Payment prompt shown whenever the current user owes money
    @State private var showPaymentPrompt = false
    @State private var pendingSettlementForShare: PaymentLink? = nil
    
    // When the user owes on multiple settlements and hits the top Share button,
    // we queue them up and show the prompt one at a time.
    @State private var pendingSettlementQueue: [PaymentLink] = []
    
    private var isSettleAllActive: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .settleAll
    }
    
    var totalTransactions: Int {
        appState.transactions.filter { $0.includeInSplit }.count
    }
    
    var currentUserBalance: Double {
        var balance: Double = 0
        let currentUserId = appState.people.first(where: { $0.isCurrentUser })?.id
        for settlement in settlements {
            if settlement.from.id == currentUserId { balance -= settlement.amount }
            else if settlement.to.id == currentUserId { balance += settlement.amount }
        }
        return balance
    }
    
    // MARK: - Payment Method Helpers
    
    private var hasVenmoSetup: Bool {
        let hasUsername = !(appState.profile.venmoUsername?.replacingOccurrences(of: "@", with: "").isEmpty ?? true)
        let hasLink     = !(appState.profile.venmoPaymentLink?.isEmpty ?? true)
        return hasUsername || hasLink
    }
    
    private var hasZelleLinkSetup: Bool {
        let hasQRLink = !(appState.profile.zellePaymentLink?.isEmpty ?? true)
        let hasEmail  = appState.profile.zelleEmail?.contains("@") == true
        return hasQRLink || hasEmail
    }
    
    private var hasZellePhoneOnly: Bool {
        let qrLink = appState.profile.zellePaymentLink ?? ""
        let email  = appState.profile.zelleEmail ?? ""
        return qrLink.isEmpty && !email.isEmpty && !email.contains("@")
    }
    
    private func currentUserOwes(in settlement: PaymentLink) -> Bool {
        let currentUserId = appState.people.first(where: { $0.isCurrentUser })?.id
        return settlement.from.id == currentUserId
    }
    
    
    
    // MARK: - Body
    
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            
            VStack(spacing: 0) {
                headerView
                
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 20) {
                            balanceSummaryCard.id("balanceSummary")
                            paymentsSection.id("paymentsSection")
                            Spacer(minLength: 100)
                        }
                        .padding(20)
                    }
                    .disabled(tutorialManager.isActive)
                    .onAppear { scrollProxy = proxy }
                    .onChange(of: tutorialManager.currentStepIndex) { index in
                        guard tutorialManager.isActive else { return }
                        if index == 6 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                withAnimation(.easeInOut(duration: 0.5)) {
                                    proxy.scrollTo("paymentsSection", anchor: .top)
                                }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                tutorialManager.frameUpdateTick = 0
                            }
                        }
                    }
                }
                
                bottomActionsBar
            }
            
            if showAmountCopiedBanner {
                VStack {
                    amountCopiedBannerView
                    Spacer()
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
                .zIndex(101)
            }
            
            if showCopyToast {
                VStack {
                    Spacer()
                    copyToastView
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        ))
                        .zIndex(100)
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showCopyToast)
            }
            
            if tutorialManager.isActive {
                TutorialOverlay(context: .settle).zIndex(200)
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            // Always recalculate and copy on every appear — exactly like pressing Copy All
            recalculateSettlements()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                copyAllSettlements()
            }
            
            guard !hasAppeared else { return }
            hasAppeared = true
            setupNotificationActions()
            updateTransactionIDs()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { saveSplitToHistory() }
            if tutorialManager.isActive && tutorialManager.currentStepIndex < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    tutorialManager.currentStepIndex = 6
                }
            }
        }
        .onChange(of: transactionIDsHash) { _ in
            guard hasAppeared else { return }
            recalculateSettlements()
            updateTransactionIDs()
            // Keep clipboard fresh whenever settlements change
            copyAllSettlements(silent: true)
        }
        // Payment prompt — shown when user owes so they can pay via Venmo or Zelle
        .sheet(isPresented: $showPaymentPrompt) {
            if let settlement = pendingSettlementForShare {
                PaymentPromptView(
                    settlement: settlement,
                    appState: appState,
                    onDismiss: {
                        showPaymentPrompt = false
                        pendingSettlementForShare = nil
                        pendingSettlementQueue = []
                    },
                    onSendMessageInstead: {
                        showPaymentPrompt = false
                        let s = settlement
                        pendingSettlementForShare = nil
                        // Process remaining queue after dismissal animation
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            shareToContact(settlement: s)
                            advancePaymentQueue()
                        }
                    },
                    onSkipToShareSheet: {
                        // User wants to share via a different app (not Venmo/Zelle)
                        showPaymentPrompt = false
                        let s = settlement
                        pendingSettlementForShare = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            shareViaNativeSheet(settlement: s)
                            advancePaymentQueue()
                        }
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
    
    // MARK: - Transaction Tracking
    
    private var transactionIDsHash: String {
        appState.transactions.map {
            "\($0.id.uuidString)-\($0.splitWith.map(\.id.uuidString).joined())"
        }.joined(separator: "|")
    }
    
    private func updateTransactionIDs() {
        transactionIDs = appState.transactions.map { $0.id }
    }
    
    // MARK: - Recalculate
    
    private func recalculateSettlements() {
        print("\n=== RECALCULATING SETTLEMENTS ===")
        for t in appState.transactions {
            print("  \(t.merchant): splitWith = \(t.splitWith.map(\.name))")
        }
        settlements = appState.calculateSettlements()
        for s in settlements {
            print("  \(s.from.name) -> \(s.to.name): \(s.formattedAmount)")
        }
        print("=== END ===\n")
    }
    
    // MARK: - Notification Setup
    
    private func setupNotificationActions() {
        let center = UNUserNotificationCenter.current()
        let copyAction = UNNotificationAction(identifier: "COPY_AMOUNT", title: "Copy Amount", options: [.foreground])
        let category = UNNotificationCategory(identifier: "PAYMENT_AMOUNT", actions: [copyAction], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button(action: {
                    HapticManager.impact(style: .light)
                    router.navigateBack()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 40, height: 40)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .shadow(color: Color.primary.opacity(0.05), radius: 4, y: 2)
                }
                .disabled(tutorialManager.isActive)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Payments")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.primary)
                    Text("\(totalTransactions) transactions")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(.systemBackground))
            
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }
    
    // MARK: - Save to History
    
    private func saveSplitToHistory() {
        let snapshots = settlements.map {
            SettlementSnapshot(id: $0.id, fromName: $0.from.name, toName: $0.to.name, amount: $0.amount)
        }
        let total = appState.transactions.filter { $0.includeInSplit }.reduce(0.0) { $0 + $1.amount }
        let record = SplitRecord(
            date: Date(),
            totalAmount: total,
            participantCount: appState.people.count,
            transactionCount: totalTransactions,
            settlements: snapshots,
            yourBalance: currentUserBalance
        )
        let fiveMinutesAgo = Date().addingTimeInterval(-300)
        let isDuplicate = appState.profile.splitHistory.contains {
            $0.contentHash == record.contentHash && $0.date > fiveMinutesAgo
        }
        if !isDuplicate {
            appState.profile.splitHistory.insert(record, at: 0)
            if appState.profile.splitHistory.count > 20 {
                appState.profile.splitHistory = Array(appState.profile.splitHistory.prefix(20))
            }
            HapticManager.notification(type: .success)
        }
    }
    
    // MARK: - Balance Summary Card
    
    private var balanceSummaryCard: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: currentUserBalance >= 0
                            ? [Color.green.opacity(0.15), Color.green.opacity(0.05)]
                            : [Color.red.opacity(0.15), Color.red.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 64, height: 64)
                    Image(systemName: currentUserBalance >= 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(currentUserBalance >= 0 ? .green : .red)
                }
                .scaleEffect(selectedSettlementId == nil ? 1.0 : 0.95)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selectedSettlementId)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(currentUserBalance > 0 ? "Receiving" : currentUserBalance < 0 ? "Sending" : "All settled")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    if currentUserBalance != 0 {
                        Text(String(format: "$%.2f", abs(currentUserBalance)))
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(currentUserBalance >= 0 ? .green : .red)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundColor(.green)
                            Text("$0.00").font(.system(size: 32, weight: .bold)).foregroundColor(.primary)
                        }
                    }
                }
                Spacer()
            }
            
            HStack(spacing: 0) {
                statItem(icon: "person.2.fill", value: "\(appState.people.count)", label: "People")
                Divider().frame(height: 40).background(Color.primary.opacity(0.1))
                statItem(icon: "arrow.left.arrow.right", value: "\(settlements.count)", label: "Payments")
            }
            .padding(.top, 8)
        }
        .padding(24)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(20)
        .shadow(color: Color.primary.opacity(0.06), radius: 12, y: 4)
    }
    
    private func statItem(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(.secondary)
                Text(value).font(.system(size: 18, weight: .bold)).foregroundColor(.primary)
            }
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Payments Section
    
    private var paymentsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Payments")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.primary)
                .padding(.horizontal, 4)
            
            if settlements.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 12) {
                    ForEach($settlements) { $settlement in
                        SettlementRowView(
                            settlement: $settlement,
                            isSelected: selectedSettlementId == settlement.id,
                            isFirstRow: settlement.id == settlements.first?.id,
                            onShare: {
                                handleShareTap(for: settlement)
                            }
                        )
                        .tutorialMultiSpotlight(
                            target: .settlePayment,
                            isActive: isSettleAllActive && settlement.id == settlements.first?.id
                        )
                        .onTapGesture {
                            guard !tutorialManager.isActive else { return }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedSettlementId = selectedSettlementId == settlement.id ? nil : settlement.id
                            }
                        }
                        .disabled(tutorialManager.isActive)
                    }
                }
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle").font(.system(size: 48)).foregroundColor(.green.opacity(0.5))
            Text("Everything's Paid!").font(.system(size: 18, weight: .semibold)).foregroundColor(.primary)
            Text("No payments needed").font(.system(size: 14)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(20)
    }
    
    // MARK: - Bottom Actions
    
    private var bottomActionsBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: { HapticManager.impact(style: .medium); copyAllSettlements() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.on.doc.fill").font(.system(size: 16))
                            Text("Copy All").font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(16)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.15), lineWidth: 1.5))
                        .shadow(color: Color.primary.opacity(0.04), radius: 8, y: 2)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .disabled(tutorialManager.isActive)
                    
                    Button(action: { HapticManager.impact(style: .medium); prepareAndShare() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up.fill").font(.system(size: 16))
                            Text("Share").font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.accentColor)
                        .cornerRadius(16)
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 12, y: 4)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .tutorialMultiSpotlight(target: .shareButton, isActive: isSettleAllActive)
                    .disabled(tutorialManager.isActive)
                }
            }
            .padding(20)
            .background(Color(.systemBackground).shadow(color: Color.primary.opacity(0.05), radius: 20, y: -5))
        }
    }
    
    // MARK: - Copy Toast
    
    private var copyToastView: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.green).frame(width: 32, height: 32)
                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
            }
            Text("Copied to clipboard").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Capsule().fill(Color.primary.opacity(0.92)).shadow(color: Color.primary.opacity(0.3), radius: 20, y: 8))
        .padding(.horizontal, 20)
        .padding(.bottom, 120)
    }
    
    private func showCopyToastWithHaptic() {
        HapticManager.notification(type: .success)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showCopyToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showCopyToast = false }
        }
    }
    
    // MARK: - Amount Copied Banner
    
    private func showAmountCopiedBanner(amount: String) {
        copiedAmount = amount
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showAmountCopiedBanner = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showAmountCopiedBanner = false }
        }
    }
    
    private var amountCopiedBannerView: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.green).frame(width: 36, height: 36)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Amount Copied!").font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                Text("\(copiedAmount) is ready to paste").font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.9))
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.accentColor)
                .shadow(color: Color.accentColor.opacity(0.4), radius: 20, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.top, 60)
    }
    
    // MARK: - Zelle Link Generation
    
    private func generateZelleDeepLink(amount: Double) -> String? {
        if let link = appState.profile.zellePaymentLink, !link.isEmpty { return link }
        if let email = appState.profile.zelleEmail, email.contains("@"), !email.isEmpty {
            let amt     = String(format: "%.2f", amount)
            let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
            return "zelle://payment?token=\(encoded)&amount=\(amt)"
        }
        return nil
    }
    
    private func zellePhoneInstructions() -> String? {
        guard hasZellePhoneOnly, let phone = appState.profile.zelleEmail, !phone.isEmpty else { return nil }
        return "Zelle: Send to \(phone) via your bank app or the Zelle app"
    }
    
    // MARK: - Core Share Routing
    
    /// Single entry point for all share taps — both per-row and the bottom Share button.
    /// If the current user owes money on any of the given settlements, show the payment
    /// prompt first. Otherwise fall through to the native share sheet.
    private func handleShareTap(for settlement: PaymentLink) {
        if currentUserOwes(in: settlement) {
            pendingSettlementQueue = []
            pendingSettlementForShare = settlement
            showPaymentPrompt = true
        } else {
            shareToContact(settlement: settlement)
        }
    }
    
    /// Called by the bottom Share button. Copies amounts, then:
    /// - If the current user owes on one or more settlements, show the payment prompt
    ///   for the first owed settlement and queue the rest.
    /// - If the user owes nothing, go straight to the native share sheet.
    private func prepareAndShare() {
        // Copy amounts to clipboard
        let amountToCopy = settlements.count == 1
        ? settlements[0].formattedAmount
        : settlements.map { $0.formattedAmount }.joined(separator: ", ")
        let bannerMsg = settlements.count == 1 ? settlements[0].formattedAmount : "\(settlements.count) amounts"
        UIPasteboard.general.string = amountToCopy
        HapticManager.notification(type: .success)
        showAmountCopiedBanner(amount: bannerMsg)
        
        for s in settlements {
            let recipient = s.to.isCurrentUser ? s.from : s.to
            sendPaymentNotification(amount: s.formattedAmount, recipient: recipient.name)
        }
        
        // Split settlements into ones the current user owes vs. ones they are receiving
        let owedByUser = settlements.filter { currentUserOwes(in: $0) }
        let receivedByUser = settlements.filter { !currentUserOwes(in: $0) }
        
        if owedByUser.isEmpty {
            // User is only receiving money — go straight to the native share sheet
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { presentShareSheet() }
        } else {
            // Show the payment prompt for the first settlement the user owes,
            // queue the rest. Settlements where the user is receiving will be
            // shared via the native sheet after the prompt flow completes.
            var queue = Array(owedByUser.dropFirst())
            
            // If there are settlements where the user receives money, tack on a
            // share-sheet pass for those at the end of the queue by temporarily
            // appending them as a group share at the end (handled via receivedByUser).
            // We store a sentinel: pendingSettlementQueue contains only owed ones;
            // after the queue drains we share the rest via the sheet automatically.
            pendingSettlementQueue = queue
            pendingSettlementForShare = owedByUser[0]
            
            // After the entire prompt queue drains, share the receiving-side ones via sheet
            // This is handled inside advancePaymentQueue by checking the queue is empty.
            // We store receivedByUser settlements so advancePaymentQueue can fire the sheet.
            pendingReceivingSettlements = receivedByUser
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showPaymentPrompt = true
            }
        }
    }
    
    // Settlements where the user is receiving (used after payment prompt queue drains)
    @State private var pendingReceivingSettlements: [PaymentLink] = []
    
    // Advance the queue; when empty, share receiving-side settlements via native sheet
    private func advancePaymentQueue() {
        if !pendingSettlementQueue.isEmpty {
            let next = pendingSettlementQueue.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pendingSettlementForShare = next
                showPaymentPrompt = true
            }
        } else if !pendingReceivingSettlements.isEmpty {
            // All owed settlements handled — share receiving ones via the native sheet
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                presentShareSheet()
                pendingReceivingSettlements = []
            }
        }
    }
    
    // MARK: - Share Helpers
    
    private func presentShareSheet() {
        let text = settlements.count == 1 ? generateMessageText(for: settlements[0]) : generateSummaryText()
        var items: [Any] = [text]
        
        if let qrData = appState.profile.zelleQRCode, let qrImage = UIImage(data: qrData) {
            items.append(qrImage)
        }
        
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        
        func tryPresent() {
            var top = root
            while let presented = top.presentedViewController {
                if presented.isBeingDismissed {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tryPresent() }
                    return
                }
                top = presented
            }
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = top.view
                popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            top.present(activityVC, animated: true)
        }
        
        tryPresent()
    }
    
    /// Share a single settlement via the native share sheet (used from the payment prompt's
    /// "Share via another app" option).
    private func shareViaNativeSheet(settlement: PaymentLink) {
        let text = generateMessageText(for: settlement)
        var items: [Any] = [text]
        
        if let qrData = appState.profile.zelleQRCode, let qrImage = UIImage(data: qrData) {
            items.append(qrImage)
        }
        
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        
        func tryPresent() {
            var top = root
            while let presented = top.presentedViewController {
                if presented.isBeingDismissed {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tryPresent() }
                    return
                }
                top = presented
            }
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = top.view
                popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            top.present(activityVC, animated: true)
        }
        
        tryPresent()
    }
    
    private func copyAllSettlements(silent: Bool = false) {
        let currentSettlements = settlements.isEmpty ? appState.calculateSettlements() : settlements
        let summaryText: String
        if currentSettlements.isEmpty {
            summaryText = generateSummaryText()
        } else {
            
            var text = "Payment Summary\n\n"
            for s in currentSettlements {
                text += "\(s.from.name) -> \(s.to.name): \(s.formattedAmount)\n"
            }
            summaryText = text
        }
        var items: [[String: Any]] = [["public.utf8-plain-text": summaryText]]
        if let qrData = appState.profile.zelleQRCode,
           let qrImage = UIImage(data: qrData),
           let png = qrImage.pngData() {
            items.append(["public.png": png])
        }
        UIPasteboard.general.items = items
        if !silent { showCopyToastWithHaptic() }
    }
    
    private func shareToContact(settlement: PaymentLink) {
        let recipient = settlement.to.isCurrentUser ? settlement.from : settlement.to
        
        UIPasteboard.general.string = settlement.formattedAmount
        HapticManager.notification(type: .success)
        showAmountCopiedBanner(amount: settlement.formattedAmount)
        
        let text = generateMessageText(for: settlement)
        sendPaymentNotification(amount: settlement.formattedAmount, recipient: recipient.name)
        
        if let phoneNumber = recipient.phoneNumber, !phoneNumber.isEmpty {
            if MFMessageComposeViewController.canSendText() {
                HapticManager.impact(style: .medium)
                openMessageComposer(recipient: phoneNumber, body: text)
            } else {
                let sms = "sms:\(phoneNumber)&body=\(text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
                if let url = URL(string: sms) { HapticManager.impact(style: .medium); UIApplication.shared.open(url) }
            }
        } else {
            if MFMessageComposeViewController.canSendText() {
                let controller = MFMessageComposeViewController()
                controller.body = text
                controller.messageComposeDelegate = MessageComposeCoordinator.shared
                presentController(controller)
            } else {
                if let url = URL(string: "sms:") { HapticManager.impact(style: .medium); UIApplication.shared.open(url) }
            }
        }
    }
    
    private func openMessageComposer(recipient: String, body: String) {
        let controller = MFMessageComposeViewController()
        controller.recipients = [recipient]
        controller.body = body
        controller.messageComposeDelegate = MessageComposeCoordinator.shared
        presentController(controller)
    }
    
    private func attachZelleQR(to controller: MFMessageComposeViewController) {
        if let qrData = appState.profile.zelleQRCode,
           let qrImage = UIImage(data: qrData),
           let png = qrImage.pngData() {
            controller.addAttachmentData(png, typeIdentifier: "public.png", filename: "zelle-qr.png")
        }
    }
    
    private func presentController(_ controller: UIViewController) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        
        // Dismiss everything currently presented, then wait for the animation to
        // fully complete before pushing the new controller. This prevents the blank
        // white screen that appears when presenting over a SwiftUI sheet mid-dismiss.
        if let presented = root.presentedViewController {
            presented.dismiss(animated: true) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    HapticManager.impact(style: .medium)
                    root.present(controller, animated: true)
                }
            }
        } else {
            HapticManager.impact(style: .medium)
            root.present(controller, animated: true)
        }
    }
    
    // MARK: - Notification
    
    private func sendPaymentNotification(amount: String, recipient: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Dutchie Payment"
            content.body = "Send \(amount) to \(recipient)"
            content.sound = .default
            content.badge = 1
            content.categoryIdentifier = "PAYMENT_AMOUNT"
            content.userInfo = ["amount": amount, "recipient": recipient]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(
                identifier: "dutchie-payment-\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )
            center.add(request)
        }
    }
    
    // MARK: - Message Text Generation
    
    private func generateMessageText(for settlement: PaymentLink) -> String {
        let currentUser = appState.people.first(where: { $0.isCurrentUser })
        let userIsPaying = settlement.from.id == currentUser?.id
        
        var text: String
        
        if userIsPaying {
            // Current user owes — casual ask for payment info
            text = "Your Payment from Dutchie (Split Smarter, Not Harder)\n\nHey! I owe you \(settlement.formattedAmount) from our recent split. Can I get your Venmo or Zelle?\n\n"
            text += "Payment Summary\n"
            text += "\(settlement.from.name) -> \(settlement.to.name): \(settlement.formattedAmount)\n\n"
        } else {
            // Current user is receiving — include quick pay links so the other person can pay easily
            text = "Your Payment from Dutchie (Split Smarter, Not Harder)\n\n Hey! You owe me \(settlement.formattedAmount) from our recent split.\n\n"
            text += "Payment Summary\n"
            text += "\(settlement.from.name) -> \(settlement.to.name): \(settlement.formattedAmount)\n\n"
            
            var paymentLines: [String] = []
            
            if let username = appState.profile.venmoUsername?.replacingOccurrences(of: "@", with: ""), !username.isEmpty {
                let amt  = String(format: "%.2f", settlement.amount)
                let note = "Split payment".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Split%20payment"
                paymentLines.append("Venmo: venmo://paycharge?txn=pay&recipients=\(username)&amount=\(amt)&note=\(note)")
                paymentLines.append("(Don't have Venmo? Search @\(username) in the app, or download at venmo.com)")
            } else if let venmoLink = appState.profile.venmoPaymentLink, !venmoLink.isEmpty {
                paymentLines.append("Venmo: \(venmoLink)")
            }
            
            if let zelleLink = generateZelleDeepLink(amount: settlement.amount) {
                paymentLines.append("Zelle: \(zelleLink)")
            } else if let phoneNote = zellePhoneInstructions() {
                paymentLines.append(phoneNote)
                paymentLines.append("(Don't have Zelle? Download it free or use it inside your bank app)")
            }
            
            if !paymentLines.isEmpty {
                text += "Quick Pay:\n"
                for line in paymentLines { text += "\(line)\n" }
                text += "\n"
            }
        }
        
        return text
    }
    
    private func generateSummaryText() -> String {
        var text = "Your Payment from Dutchie (Split Smarter, Not Harder)\n\n"
        
        for s in settlements {
            text += "\(s.from.name) -> \(s.to.name): \(s.formattedAmount)\n"
        }
        text += "\n"
        
        let hasPaymentInfo = hasVenmoSetup || hasZelleLinkSetup || hasZellePhoneOnly
        if hasPaymentInfo {
            text += "Quick Pay:\n"
            if let username = appState.profile.venmoUsername?.replacingOccurrences(of: "@", with: ""), !username.isEmpty {
                let note = "Split payment".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Split%20payment"
                text += "Venmo: venmo://paycharge?txn=pay&recipients=\(username)&note=\(note)\n"
                text += "(Don't have Venmo? Search @\(username) in the app, or download at venmo.com)\n"
            } else if let venmoLink = appState.profile.venmoPaymentLink, !venmoLink.isEmpty {
                text += "Venmo: \(venmoLink)\n"
            }
            
            if let zelleLink = generateZelleDeepLink(amount: settlements.first?.amount ?? 0) {
                text += "Zelle: \(zelleLink)\n"
            } else if let phoneNote = zellePhoneInstructions() {
                text += "\(phoneNote)\n"
                text += "(Don't have Zelle? Download it free or use it inside your bank app)\n"
            }
            text += "\n"
        }
        
        return text
    }
    
    // MARK: - Payment Prompt View
    /// Shown when the current user is the one who owes money.
    struct PaymentPromptView: View {
        let settlement: PaymentLink
        let appState: AppState
        let onDismiss: () -> Void
        let onSendMessageInstead: () -> Void
        let onSkipToShareSheet: () -> Void
        
        var body: some View {
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.primary.opacity(0.2))
                    .frame(width: 36, height: 4)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 24) {
                        
                        // Header
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(
                                        colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.06)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 72, height: 72)
                                Image(systemName: "creditcard.fill")
                                    .font(.system(size: 30, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }
                            
                            Text("How would you like to pay?")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.center)
                            
                            Text("You owe \(settlement.to.name) \(settlement.formattedAmount). Choose a payment method below.")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                                .padding(.horizontal, 8)
                        }
                        
                        // Venmo only — just opens the app home, user pays from there
                        paymentCard(
                            icon: "v.circle.fill",
                            iconColor: Color(red: 0.2, green: 0.53, blue: 0.96),
                            title: "Pay with Venmo",
                            subtitle: "Opens the Venmo app",
                            installNote: "Not installed? We will take you to the App Store",
                            deepLink: "venmo://",
                            appStoreURL: "https://apps.apple.com/app/venmo/id351727428"
                        )
                        
                        // Secondary actions
                        VStack(spacing: 10) {
                            Button(action: onSendMessageInstead) {
                                HStack(spacing: 8) {
                                    Image(systemName: "message.fill").font(.system(size: 15))
                                    Text("Send a Message Instead")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(14)
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.15), lineWidth: 1.5))
                            }
                            .buttonStyle(ScaleButtonStyle())
                            
                            Button(action: onSkipToShareSheet) {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.and.arrow.up").font(.system(size: 15))
                                    Text("Share via Another App")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(14)
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.15), lineWidth: 1.5))
                            }
                            .buttonStyle(ScaleButtonStyle())
                            
                            Button(action: onDismiss) {
                                Text("Cancel")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .background(Color(.systemBackground))
        }
        
        private func paymentCard(
            icon: String,
            iconColor: Color,
            title: String,
            subtitle: String,
            installNote: String,
            deepLink: String,
            appStoreURL: String
        ) -> some View {
            Button(action: {
                HapticManager.impact(style: .medium)
                guard let url = URL(string: deepLink) else { return }
                UIApplication.shared.open(url) { success in
                    if !success, let storeURL = URL(string: appStoreURL) {
                        UIApplication.shared.open(storeURL)
                    }
                }
            }) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(iconColor.opacity(0.12))
                            .frame(width: 52, height: 52)
                        Image(systemName: icon)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundColor(iconColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(subtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(installNote)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(iconColor.opacity(0.7))
                    }
                    
                    Spacer()
                    
                    Image(systemName: "arrow.up.forward.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(iconColor.opacity(0.5))
                }
                .padding(16)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(iconColor.opacity(0.2), lineWidth: 1.5))
                .shadow(color: iconColor.opacity(0.06), radius: 8, y: 4)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.97))
        }
    }
    
    
    // MARK: - Settlement Row View
    struct SettlementRowView: View {
        @Binding var settlement: PaymentLink
        let isSelected: Bool
        let isFirstRow: Bool
        let onShare: () -> Void
        
        @State private var showCopyConfirmation = false
        @EnvironmentObject var tutorialManager: TutorialManager
        
        private var isSettleAllActive: Bool {
            tutorialManager.isActive && tutorialManager.currentStep?.targetView == .settleAll
        }
        
        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    HStack(spacing: -10) {
                        AvatarView(imageData: settlement.from.contactImage, initials: settlement.from.initials, size: 44)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2.5))
                            .shadow(color: Color.primary.opacity(0.1), radius: 4, y: 2)
                        AvatarView(imageData: settlement.to.contactImage, initials: settlement.to.initials, size: 44)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2.5))
                            .shadow(color: Color.primary.opacity(0.1), radius: 4, y: 2)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(settlement.from.name)
                                .font(.system(size: 15, weight: .semibold)).foregroundColor(.primary).lineLimit(1)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                            Text(settlement.to.name)
                                .font(.system(size: 15, weight: .semibold)).foregroundColor(.primary).lineLimit(1)
                        }
                        Text(settlement.formattedAmount)
                            .font(.system(size: 22, weight: .bold)).foregroundColor(.primary)
                    }
                    
                    Spacer(minLength: 8)
                    
                    HStack(spacing: 10) {
                        Button(action: {
                            HapticManager.impact(style: .light)
                            UIPasteboard.general.string = settlement.formattedAmount
                            withAnimation(.spring(response: 0.3)) { showCopyConfirmation = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation(.spring(response: 0.3)) { showCopyConfirmation = false }
                            }
                        }) {
                            Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(showCopyConfirmation ? .green : .secondary)
                                .frame(width: 40, height: 40)
                                .background(showCopyConfirmation ? Color.green.opacity(0.1) : Color.primary.opacity(0.05))
                                .cornerRadius(10)
                        }
                        .buttonStyle(ScaleButtonStyle(scale: 0.9))
                        .disabled(tutorialManager.isActive)
                        
                        Button(action: { HapticManager.impact(style: .medium); onShare() }) {
                            Image(systemName: "message.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.blue)
                                .frame(width: 40, height: 40)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(10)
                        }
                        .buttonStyle(ScaleButtonStyle(scale: 0.9))
                        .tutorialMultiSpotlight(target: .messageIcon, isActive: isSettleAllActive && isFirstRow)
                        .disabled(tutorialManager.isActive)
                    }
                }
                .padding(18)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(18)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                .shadow(color: Color.primary.opacity(0.05), radius: 8, y: 4)
                .scaleEffect(isSelected ? 0.98 : 1.0)
            }
        }
    }
    
    // MARK: - Share Sheet
    struct ShareSheet: UIViewControllerRepresentable {
        let activityItems: [Any]
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        }
        func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
    }
}
