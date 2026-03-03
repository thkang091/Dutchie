import SwiftUI
import Combine
import Lottie

struct TutorialStep: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let description: String
    let targetView: TutorialTarget
    let action: TutorialAction?

    static func == (lhs: TutorialStep, rhs: TutorialStep) -> Bool {
        lhs.id == rhs.id
    }

    enum TutorialTarget {
        case uploadSection
        case uploadButton
        case uploadAndManual  // Multi-spotlight for step 1
        case manualEntry
        case profileButton
        case receiptThumbnail
        case nextButton
        case peopleAddContact
        case peopleList
        case continueButton
        case reviewTransaction
        case breakdownButton
        case breakdownConfirm
        case reviewItemCard
        case splitSection
        case splitToggle
        case settleAll
        case settlePayment
        case shareButton
        case messageIcon
        case fullScreen
        case paymentMethods
    }

    enum TutorialAction {
        case none
        case navigateToProfile
        case navigateToPeople
        case navigateToReview
        case navigateToSettle
    }
}

// MARK: - Which view each step belongs to
enum TutorialViewContext {
    case upload
    case profile
    case people
    case review
    case settle
}

// MARK: - Tutorial Manager
class TutorialManager: ObservableObject {
    @Published var isActive = false
    @Published var currentStepIndex = 0

    // Persisted via AppStorage so tutorial only auto-starts once
    @AppStorage("hasAutoStartedOnce") var hasAutoStartedOnce = false
    @AppStorage("hasSeenTutorial") var hasCompletedTutorial = false

    // Signal buses
    @Published var shouldOpenBreakdownSheet = false
    @Published var shouldAutoApplyBreakdown = false
    @Published var shouldTriggerSplitDemo = false

    // Single-target spotlight frame (most steps)
    @Published var spotlightFrame: CGRect = .zero

    // Multi-target spotlight frames keyed by target.
    @Published var spotlightFrames: [TutorialStep.TutorialTarget: CGRect] = [:]

    // Tick counter — incremented on every registerFrame call so the overlay
    // re-renders even when SwiftUI's dict-diffing misses the mutation.
    @Published var frameUpdateTick: Int = 0

    // FIX: Raised to true while Router is mid-flight popping Review and pushing
    // Settle. complete() is a no-op while this is true, preventing ReviewView's
    // onDisappear from killing the tutorial during the transition.
    @Published var isNavigatingToSettle: Bool = false
    let steps: [TutorialStep] = [
        TutorialStep(title: "Welcome to Dutchie",
                     description: "Hi, I'm Taehoon Kang, Founder of Dutchie. Let me show you how easy it is to split bills with friends!",
                     targetView: .fullScreen, action: .none),

        TutorialStep(title: "Add Your Expenses",
                     description: "Upload transactions by taking a screenshot, or upload a receipt by taking a picture with your camera or selecting one from your photos. You can also use Manual Entry below to type expenses without a receipt.",
                     targetView: .uploadAndManual, action: .none),

        TutorialStep(title: "Add Payment Methods",
                     description: "This is your profile. We recommend adding your Venmo username and Zelle QR code. It makes it super convenient for friends to pay you in a single tap.",
                     targetView: .paymentMethods, action: .navigateToProfile),

        TutorialStep(title: "Add People to Your Split",
                     description: "Add everyone you're splitting with. Tap Import from Contacts to pull friends directly from your phone.",
                     targetView: .peopleAddContact, action: .navigateToPeople),

        TutorialStep(title: "Review Your Receipt",
                     description: "Your receipt is ready. Each transaction shows who paid and how it is split.",
                     targetView: .reviewTransaction, action: .navigateToReview),

        TutorialStep(title: "Receipt Breakdown",
                     description: "We detected all 5 items from your receipt. These will be split individually so each person pays only for what they ordered.",
                     targetView: .breakdownConfirm, action: .none),

        TutorialStep(title: "Share and Settle Up",
                     description: "Dutchie calculates the minimum payments needed. Tap Share to send requests with Venmo and Zelle links or tap the message icon to text someone directly.",
                     targetView: .settleAll, action: .navigateToSettle),

        TutorialStep(title: "You're All Set",
                     description: "Start by adding your Venmo username and Zelle QR code so friends can pay you easily.",
                     targetView: .paymentMethods, action: .navigateToProfile)
    ]
    

    func steps(for context: TutorialViewContext) -> [Int] {
        switch context {
        case .upload:   return [0, 1]
        case .profile:  return [2, 7]
        case .people:   return [3]
        case .review:   return [4, 5]
        case .settle:   return [6]
        }
    }

    func isCurrentStep(in context: TutorialViewContext) -> Bool {
        steps(for: context).contains(currentStepIndex)
    }

    var currentStep: TutorialStep? {
        guard currentStepIndex < steps.count else { return nil }
        return steps[currentStepIndex]
    }

    var isLastStep: Bool { currentStepIndex >= steps.count - 1 }
    var totalSteps: Int  { steps.count }

    weak var router: Router?
    weak var appState: AppState?

    // MARK: - Multi-spotlight helpers

    var isMultiSpotlight: Bool {
        guard let step = currentStep else { return false }
        return step.targetView == .settleAll || step.targetView == .uploadAndManual
    }

    func registerFrame(_ frame: CGRect, for target: TutorialStep.TutorialTarget) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.spotlightFrames[target] != frame {
                self.spotlightFrames[target] = frame
                self.frameUpdateTick += 1
                print("🎯 Registered frame for \(target): \(frame)")
            }
        }
    }

    var activeMultiFrames: [CGRect] {
        guard isMultiSpotlight, let step = currentStep else { return [] }

        // Step 1: Upload section + Manual entry
        if step.targetView == .uploadAndManual {
            return [
                spotlightFrames[.uploadSection],
                spotlightFrames[.manualEntry]
            ].compactMap { $0 }.filter { $0 != .zero }
        }

        // Step 6: Settle payment buttons
        if step.targetView == .settleAll {
            return [
                spotlightFrames[.settlePayment],
                spotlightFrames[.shareButton],
                spotlightFrames[.messageIcon]
            ].compactMap { $0 }.filter { $0 != .zero }
        }

        return []
    }

    // MARK: - Lifecycle

    func start() {
        isActive = true
        currentStepIndex = 0
        spotlightFrame = .zero
        spotlightFrames = [:]
        frameUpdateTick = 0
        isNavigatingToSettle = false
        shouldOpenBreakdownSheet = false
        shouldAutoApplyBreakdown = false
        shouldTriggerSplitDemo = false
        hasAutoStartedOnce = true
        setupTutorialData()
    }

    func nextStep() {
        // Step 5 (breakdown confirm) — trigger auto-apply and let the breakdown
        // sheet's completion handler call advanceToPostBreakdown()
        if currentStepIndex == 5 {
            spotlightFrame = .zero
            shouldAutoApplyBreakdown = true
            return
        }

        // Step 6 (settle) — pop settle back to upload root, then open profile for step 7.
        // The user stays in profile after tapping "Get Started"; closing profile
        // naturally lands them on UploadView.
        if currentStepIndex == 6 {
            spotlightFrame = .zero
            spotlightFrames = [:]

            // Reset nav stack to UploadView (no animation needed — profile sheet
            // will cover it immediately)
            router?.resetToUpload()

            // Small delay so the stack reset settles before the sheet appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    self.currentStepIndex = 7
                }
                self.router?.showProfile = true
            }
            return
        }

        spotlightFrame = .zero

        let nextIndex = currentStepIndex + 1

        // Only wipe multi-frames when NOT landing on step 6.
        if nextIndex != 6 {
            spotlightFrames = [:]
        }

        if nextIndex < steps.count {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                currentStepIndex = nextIndex
            }
            if nextIndex == 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.shouldOpenBreakdownSheet = true
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.router?.handleTutorialNavigation(for: nextIndex)
                }
            }
        } else {
            complete()
        }
    }

    func advanceToPostBreakdown() {
        spotlightFrame = .zero
        // Do NOT clear spotlightFrames — keep pre-registered settle frames.

        // FIX: Raise guard BEFORE router navigation so any onDisappear that
        // fires during the pop+push cannot call complete() prematurely.
        isNavigatingToSettle = true

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            currentStepIndex = 6
        }

        router?.handleTutorialNavigation(for: 6)

        // Lower guard after the navigation animation fully settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.isNavigatingToSettle = false
        }
    }

    func skip() {
        // Intentional user action — bypass navigation guard.
        isNavigatingToSettle = false
        hasCompletedTutorial = true
        complete()
    }

    func complete() {
        // FIX: Suppress if mid-navigation. ReviewView's onDisappear (fired when
        // Router pops it) would otherwise land here and kill the tutorial before
        // SettleShareView appears.
        guard !isNavigatingToSettle else {
            print("complete() suppressed — navigation to settle in progress")
            return
        }

        // Clear all mock tutorial data so it doesn't bleed into real sessions.
        clearTutorialData()

        spotlightFrame = .zero
        spotlightFrames = [:]
        frameUpdateTick = 0
        isNavigatingToSettle = false
        shouldOpenBreakdownSheet = false
        shouldAutoApplyBreakdown = false
        shouldTriggerSplitDemo = false

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isActive = false
            hasCompletedTutorial = true  // persist so it won't auto-start again
        }
    }

    func reset() {
        currentStepIndex = 0
        hasCompletedTutorial = false
        spotlightFrame = .zero
        spotlightFrames = [:]
        frameUpdateTick = 0
        isNavigatingToSettle = false
        shouldOpenBreakdownSheet = false
        shouldAutoApplyBreakdown = false
        shouldTriggerSplitDemo = false
    }

    // MARK: - Tutorial Data

    func setupTutorialData() {
        guard let appState = appState else { return }
        appState.transactions.removeAll()
        appState.uploadedReceipts.removeAll()

        if appState.people.count == 1 {
            appState.people.append(Person(name: "Alex", isCurrentUser: false))
        }
        guard let currentUser = appState.people.first(where: { $0.isCurrentUser }) else { return }

        let sampleImage = createSampleReceiptImage()
        let imageData = sampleImage.jpegData(compressionQuality: 0.8) ?? Data()

        let lineItems = [
            ReceiptLineItem(name: "ARTISAN ROLL",    originalPrice: 6.99,  discount: 0, amount: 6.99,  taxPortion: 0.56, isSelected: true),
            ReceiptLineItem(name: "SHIN RAMYUN",     originalPrice: 15.99, discount: 0, amount: 15.99, taxPortion: 1.28, isSelected: true),
            ReceiptLineItem(name: "1895 CHERRY TOV", originalPrice: 7.49,  discount: 0, amount: 7.49,  taxPortion: 0.60, isSelected: true),
            ReceiptLineItem(name: "KS CHOPONION",    originalPrice: 4.39,  discount: 0, amount: 4.39,  taxPortion: 0.35, isSelected: true),
            ReceiptLineItem(name: "KIMCHI",          originalPrice: 7.99,  discount: 0, amount: 7.99,  taxPortion: 0.64, isSelected: true)
        ]
        let transaction = Transaction(
            amount: 46.28, merchant: "Sample Grocery Store", paidBy: currentUser,
            splitWith: appState.people, receiptImage: imageData,
            includeInSplit: true, isManual: false, lineItems: lineItems
        )
        appState.transactions.append(transaction)
        print("Tutorial data ready: 1 transaction, \(appState.people.count) people")
    }

    /// Wipes all mock data injected by setupTutorialData() so the user starts
    /// a real session on a clean slate after the tutorial completes or is skipped.
    private func clearTutorialData() {
        guard let appState = appState else { return }

        // Remove all tutorial-generated transactions and receipts
        appState.transactions.removeAll()
        appState.uploadedReceipts.removeAll()
        appState.uploadedImages.removeAll()
        appState.manualTransactions.removeAll()

        // Remove Alex (the mock tutorial person) but keep the current user
        appState.people.removeAll { !$0.isCurrentUser }

        print("Tutorial data cleared — app state is clean for real use")
    }

    private func createSampleReceiptImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 500))
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 500))
            let headerAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 18), .foregroundColor: UIColor.black]
            let smallAttrs: [NSAttributedString.Key: Any]  = [.font: UIFont.systemFont(ofSize: 12),     .foregroundColor: UIColor.darkGray]
            let itemAttrs: [NSAttributedString.Key: Any]   = [.font: UIFont.systemFont(ofSize: 13),     .foregroundColor: UIColor.black]
            let totalAttrs: [NSAttributedString.Key: Any]  = [.font: UIFont.boldSystemFont(ofSize: 16), .foregroundColor: UIColor.black]
            "SAMPLE GROCERY".draw(at: CGPoint(x: 80, y: 20), withAttributes: headerAttrs)
            "02/10/2026".draw(at: CGPoint(x: 120, y: 50), withAttributes: smallAttrs)
            let line = UIBezierPath()
            line.move(to: CGPoint(x: 20, y: 80)); line.addLine(to: CGPoint(x: 280, y: 80))
            UIColor.gray.setStroke(); line.lineWidth = 1; line.stroke()
            let items = [("ARTISAN ROLL","$6.99"),("SHIN RAMYUN","$15.99"),("1895 CHERRY TOV","$7.49"),("KS CHOPONION","$4.39"),("KIMCHI","$7.99")]
            var y = 100.0
            for (name, price) in items {
                name.draw(at: CGPoint(x: 20, y: y), withAttributes: itemAttrs)
                price.draw(at: CGPoint(x: 220, y: y), withAttributes: itemAttrs)
                y += 30
            }
            y += 20
            let div = UIBezierPath()
            div.move(to: CGPoint(x: 20, y: y)); div.addLine(to: CGPoint(x: 280, y: y))
            UIColor.gray.setStroke(); div.stroke()
            y += 15; "SUBTOTAL".draw(at: CGPoint(x: 20, y: y), withAttributes: itemAttrs); "$42.85".draw(at: CGPoint(x: 220, y: y), withAttributes: itemAttrs)
            y += 25; "TAX".draw(at: CGPoint(x: 20, y: y), withAttributes: itemAttrs); "$3.43".draw(at: CGPoint(x: 220, y: y), withAttributes: itemAttrs)
            y += 25; "TOTAL".draw(at: CGPoint(x: 20, y: y), withAttributes: totalAttrs); "$46.28".draw(at: CGPoint(x: 210, y: y), withAttributes: totalAttrs)
            y += 50; "THANK YOU!".draw(at: CGPoint(x: 105, y: y), withAttributes: smallAttrs)
        }
    }

    init() {}
}

// MARK: - Preference Key

struct TutorialFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Spotlight Masks

struct SpotlightMask: View {
    let cutoutRect: CGRect
    let cornerRadius: CGFloat
    var body: some View {
        GeometryReader { _ in
            ZStack {
                Rectangle().fill(Color.white)
                if cutoutRect != .zero {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.white)
                        .frame(width: cutoutRect.width, height: cutoutRect.height)
                        .position(x: cutoutRect.midX, y: cutoutRect.midY)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
        }
    }
}

struct MultiSpotlightMask: View {
    let cutoutRects: [CGRect]
    let cornerRadius: CGFloat
    var body: some View {
        GeometryReader { _ in
            ZStack {
                Rectangle().fill(Color.white)
                ForEach(cutoutRects.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.white)
                        .frame(width: cutoutRects[i].width, height: cutoutRects[i].height)
                        .position(x: cutoutRects[i].midX, y: cutoutRects[i].midY)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
        }
    }
}

// MARK: - Per-View Tutorial Overlay

struct TutorialOverlay: View {
    @EnvironmentObject var tutorialManager: TutorialManager
    let context: TutorialViewContext

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if tutorialManager.isActive,
                   let step = tutorialManager.currentStep,
                   tutorialManager.isCurrentStep(in: context) {

                    if step.targetView == .settleAll || step.targetView == .uploadAndManual {
                        multiSpotlightOverlay
                            .allowsHitTesting(true)
                            .zIndex(1)

                        if step.targetView == .uploadAndManual {
                            VStack {
                                Spacer()
                                tutorialCard(step: step)
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 44)
                            }
                            .zIndex(3)
                        } else {
                            VStack {
                                tutorialCard(step: step)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 56)
                                Spacer()
                            }
                            .zIndex(3)
                        }

                    } else {
                        overlayWithCutout(step: step)
                            .allowsHitTesting(true)
                            .zIndex(1)

                        tutorialCardPositioned(step: step, in: geometry)
                            .zIndex(3)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private var multiSpotlightOverlay: some View {
        let _ = tutorialManager.frameUpdateTick

        let pad: CGFloat = 12
        let cutouts = tutorialManager.activeMultiFrames.map { frame in
            CGRect(x: frame.minX - pad, y: frame.minY - pad,
                   width: frame.width + pad * 2, height: frame.height + pad * 2)
        }

        return Color.black.opacity(0.75)
            .ignoresSafeArea()
            .mask(MultiSpotlightMask(cutoutRects: cutouts, cornerRadius: 18))
    }

    @ViewBuilder
    private func tutorialCardPositioned(step: TutorialStep, in geometry: GeometryProxy) -> some View {
        let sf           = tutorialManager.spotlightFrame
        let screenHeight = geometry.size.height
        let inBottomHalf = sf != .zero && sf.midY > screenHeight / 2

        let forcedBottom: [TutorialStep.TutorialTarget] = [.uploadSection]
        let forcedTop: [TutorialStep.TutorialTarget]    = [.nextButton, .continueButton, .breakdownConfirm, .peopleAddContact]

        if forcedBottom.contains(step.targetView) || (!forcedTop.contains(step.targetView) && !inBottomHalf) {
            VStack {
                Spacer()
                tutorialCard(step: step).padding(.horizontal, 20).padding(.bottom, 44)
            }
        } else {
            VStack {
                tutorialCard(step: step)
                    .padding(.horizontal, 20)
                    .padding(.top, step.targetView == .breakdownConfirm ? 56 : 60)
                Spacer()
            }
        }
    }

    private func overlayWithCutout(step: TutorialStep) -> some View {
        let pad: CGFloat = 12
        let frame   = tutorialManager.spotlightFrame
        let hasHole = frame != .zero && step.targetView != .fullScreen
        let cutout  = hasHole
            ? CGRect(x: frame.minX - pad, y: frame.minY - pad,
                     width: frame.width + pad * 2, height: frame.height + pad * 2)
            : .zero
        let opacity: Double = step.targetView == .breakdownConfirm ? 0 : 0.75

        return Color.black.opacity(opacity)
            .ignoresSafeArea()
            .mask(SpotlightMask(cutoutRect: cutout, cornerRadius: 18))
    }

    private func tutorialCard(step: TutorialStep) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(0..<tutorialManager.totalSteps, id: \.self) { index in
                    Capsule()
                        .fill(index <= tutorialManager.currentStepIndex
                              ? Color.accentColor : Color.white.opacity(0.25))
                        .frame(height: 4).frame(maxWidth: .infinity)
                }
            }

            if tutorialManager.currentStepIndex == 0 {
                AnimatedProfileIconInCard()
            }

            Text(step.title)
                .font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                .multilineTextAlignment(.center).lineLimit(2)

            Text(step.description)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.88))
                .multilineTextAlignment(.center).lineSpacing(2).lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if tutorialManager.isLastStep {
                    Button(action: {
                        HapticManager.notification(type: .success)
                        tutorialManager.complete()
                    }) {
                        HStack(spacing: 8) {
                            Text("Get Started").font(.system(size: 15, weight: .bold))
                            Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.accentColor).cornerRadius(12)
                        .shadow(color: Color.accentColor.opacity(0.4), radius: 8, y: 4)
                    }
                    .buttonStyle(ScaleButtonStyle())
                } else {
                    Button(action: { HapticManager.impact(style: .light); tutorialManager.skip() }) {
                        Text("Skip")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.white.opacity(0.15)).cornerRadius(12)
                    }
                    .buttonStyle(ScaleButtonStyle())

                    Button(action: { HapticManager.impact(style: .medium); tutorialManager.nextStep() }) {
                        HStack(spacing: 6) {
                            Text(nextButtonLabel).font(.system(size: 14, weight: .bold))
                            Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.accentColor).cornerRadius(12)
                        .shadow(color: Color.accentColor.opacity(0.4), radius: 8, y: 4)
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }

            Text("\(tutorialManager.currentStepIndex + 1) of \(tutorialManager.totalSteps)")
                .font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.5))
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.1), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.5), radius: 24, y: 6)
        )
        .overlay(alignment: .top) {
            if tutorialManager.currentStepIndex == 0 {
                AnimatedProfileIconOverlay()
            }
        }
    }

    private var nextButtonLabel: String {
        switch tutorialManager.currentStepIndex {
        case 0:  return "Start"
        case 5:  return "Continue"
        default: return "Next"
        }
    }
}

struct AnimatedProfileIconOverlay: View {
    @State private var scale: CGFloat = 1.0
    @State private var yOffset: CGFloat = -100
    @State private var showCircleOverlay = true
    @State private var showingLottie = true

    var body: some View {
        let screenWidth = UIScreen.main.bounds.width
        let targetSize = screenWidth * 0.875
        let maxScale = targetSize / 56

        ZStack {
            // Lottie plays through the ENTIRE animation — only swapped to
            // picture AFTER the zoom-out completes.
            if showingLottie {
                TutorialLottieView(jsonName: "Video")
                    .frame(width: 56, height: 56)
                    .scaleEffect(1.3)
                    .clipShape(Circle())
                    .scaleEffect(scale)
            } else {
                Image("Picture")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                    .scaleEffect(scale)
            }

            if showCircleOverlay {
                Circle()
                    .stroke(Color.accentColor.opacity(0.4), lineWidth: 2)
                    .frame(width: 56, height: 56)
                    .scaleEffect(scale)
            }
        }
        .offset(y: yOffset)
        .onAppear {
            let playBeforeZoom: Double  = 0.5   // video plays at icon size first
            let zoomInDuration: Double  = 0.7   // zoom in duration
            let holdAtPeak: Double      = 1.5   // video plays at FULL SIZE for 1.5s
            let zoomOutDuration: Double = 0.7   // zoom out duration

            // Phase 1 — video plays at normal icon size for 0.5s
            DispatchQueue.main.asyncAfter(deadline: .now() + playBeforeZoom) {

                // Hide circle stroke just before zoom
                withAnimation(.easeOut(duration: 0.25)) {
                    showCircleOverlay = false
                }

                // Phase 2 — zoom IN, video still playing
                withAnimation(.spring(response: zoomInDuration, dampingFraction: 0.7)) {
                    scale = maxScale
                }

                // Phase 3 — hold at peak for 1.5s, video keeps looping at full size
                // (no action needed here, Lottie loops automatically)

                // Phase 4 — zoom back OUT after hold
                DispatchQueue.main.asyncAfter(deadline: .now() + zoomInDuration + holdAtPeak) {
                    withAnimation(.spring(response: zoomOutDuration, dampingFraction: 0.7)) {
                        scale   = 1.0
                        yOffset = 45
                    }

                    // Phase 5 — swap Lottie → Picture once zoom-out is nearly done
                    // At this point scale ≈ 1.0 on both branches so the swap is seamless
                    DispatchQueue.main.asyncAfter(deadline: .now() + zoomOutDuration * 0.85) {
                        showingLottie = false

                        withAnimation(.easeIn(duration: 0.3)) {
                            showCircleOverlay = true
                        }
                    }
                }
            }
        }
    }
}

struct AnimatedProfileIconInCard: View {
    var body: some View {
        Color.clear.frame(width: 56, height: 56)
    }
}

// MARK: - Tutorial-Specific Lottie View
//
// Uses a Coordinator to hold a strong reference to LottieAnimationView so
// SwiftUI re-renders (triggered by scale/state changes) don't destroy and
// recreate it — which would silently stop playback.

struct TutorialLottieView: UIViewRepresentable {
    let jsonName: String

    class Coordinator {
        let animationView: LottieAnimationView

        init(jsonName: String) {
            animationView                    = LottieAnimationView()
            animationView.animation          = LottieAnimation.named(jsonName)
            animationView.contentMode        = .scaleAspectFit
            animationView.loopMode           = .loop
            animationView.backgroundBehavior = .pauseAndRestore
            animationView.backgroundColor    = .clear
            animationView.play()
            print("🎬 Lottie '\(jsonName)' started")
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(jsonName: jsonName)
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear

        let av = context.coordinator.animationView
        container.addSubview(av)
        av.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            av.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            av.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            av.topAnchor.constraint(equalTo: container.topAnchor),
            av.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Coordinator owns the animation view — nothing to update
    }
}

// MARK: - Single-target Spotlight Modifier

struct TutorialSpotlight: ViewModifier {
    let isHighlighted: Bool
    @EnvironmentObject var tutorialManager: TutorialManager

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TutorialFrameKey.self,
                        value: isHighlighted ? geo.frame(in: .global) : .zero
                    )
                }
            )
            .onPreferenceChange(TutorialFrameKey.self) { frame in
                if isHighlighted && frame != .zero {
                    DispatchQueue.main.async { tutorialManager.spotlightFrame = frame }
                } else if !isHighlighted && tutorialManager.spotlightFrame != .zero {
                    DispatchQueue.main.async { tutorialManager.spotlightFrame = .zero }
                }
            }
    }
}

// MARK: - Multi-target Spotlight Modifier

struct TutorialMultiSpotlight: ViewModifier {
    let target: TutorialStep.TutorialTarget
    let isActive: Bool
    @EnvironmentObject var tutorialManager: TutorialManager
    @State private var reportedFrame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.frame(in: .global)) { newFrame in
                            guard isActive, newFrame.width > 0 else { return }
                            tutorialManager.registerFrame(newFrame, for: target)
                        }
                        .onAppear {
                            let frame = geo.frame(in: .global)
                            if isActive && frame.width > 0 {
                                tutorialManager.registerFrame(frame, for: target)
                            }
                        }
                        .onChange(of: isActive) { newValue in
                            guard newValue else {
                                tutorialManager.registerFrame(.zero, for: target)
                                return
                            }
                            for i in 1...20 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                                    let frame = geo.frame(in: .global)
                                    guard frame.width > 0 else { return }
                                    tutorialManager.registerFrame(frame, for: target)
                                }
                            }
                        }
                        .onChange(of: tutorialManager.currentStepIndex) { index in
                            guard (index == 1 || index == 6), isActive else { return }
                            for i in 1...20 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                                    let frame = geo.frame(in: .global)
                                    guard frame.width > 0 else { return }
                                    tutorialManager.registerFrame(frame, for: target)
                                }
                            }
                        }
                }
            )
    }
}

extension View {
    func tutorialSpotlight(isHighlighted: Bool, cornerRadius: CGFloat = 16) -> some View {
        modifier(TutorialSpotlight(isHighlighted: isHighlighted))
    }

    func tutorialMultiSpotlight(target: TutorialStep.TutorialTarget, isActive: Bool) -> some View {
        modifier(TutorialMultiSpotlight(target: target, isActive: isActive))
    }
}

// MARK: - Tutorial Welcome View

struct TutorialWelcomeView: View {
    @EnvironmentObject var tutorialManager: TutorialManager

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.8), Color.accentColor.opacity(0.5), Color(.systemBackground)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ).ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()
                ZStack {
                    Circle().fill(Color.white).frame(width: 120, height: 120)
                        .shadow(color: Color.black.opacity(0.2), radius: 20, y: 10)
                    Image(systemName: "person.3.fill").font(.system(size: 50)).foregroundColor(.accentColor)
                }
                VStack(spacing: 12) {
                    Text("Welcome to Dutchie").font(.system(size: 32, weight: .bold)).foregroundColor(.white)
                    Text("Split bills with friends effortlessly")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.9)).multilineTextAlignment(.center)
                }
                Spacer()
                VStack(spacing: 14) {
                    Button(action: { HapticManager.impact(style: .medium); tutorialManager.start() }) {
                        Text("Start Tutorial")
                            .font(.system(size: 17, weight: .bold)).foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity).padding(.vertical, 18).background(Color.white)
                            .cornerRadius(14).shadow(color: Color.black.opacity(0.2), radius: 12, y: 4)
                    }.buttonStyle(ScaleButtonStyle())

                    Button(action: { HapticManager.impact(style: .light); tutorialManager.skip() }) {
                        Text("Skip")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Color.white.opacity(0.2)).cornerRadius(14)
                    }.buttonStyle(ScaleButtonStyle())
                }
                .padding(.horizontal, 32).padding(.bottom, 40)
            }
        }
    }
}
