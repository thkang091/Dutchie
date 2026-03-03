import SwiftUI
import PhotosUI

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tutorialManager: TutorialManager
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedQRCodeItem: PhotosPickerItem?
    @State private var showingAvatarPicker = false
    @State private var showingQRPicker = false
    @State private var selectedHistoryRecord: SplitRecord?
    @State private var historySearchText = ""
    @State private var showQRScanError = false
    @State private var qrScanErrorMessage = ""
    @State private var scrollProxy: ScrollViewProxy? = nil

    private var shouldHighlightPaymentSection: Bool {
        tutorialManager.isActive && (tutorialManager.currentStepIndex == 2 || tutorialManager.currentStepIndex == 7)
    }

    private var filteredHistory: [SplitRecord] {
        if historySearchText.isEmpty { return appState.profile.splitHistory }
        return appState.profile.splitHistory.filter { record in
            record.formattedTotal.localizedCaseInsensitiveContains(historySearchText) ||
            record.formattedDate.localizedCaseInsensitiveContains(historySearchText) ||
            "\(record.participantCount)".contains(historySearchText) ||
            record.settlements.contains {
                $0.fromName.localizedCaseInsensitiveContains(historySearchText) ||
                $0.toName.localizedCaseInsensitiveContains(historySearchText)
            }
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 28) {
                            avatarSection
                            identitySection

                            VStack(spacing: 28) {
                                paymentMethodsSection
                                qrCodeSection
                            }
                            .id("paymentSection")
                            .tutorialSpotlight(isHighlighted: shouldHighlightPaymentSection, cornerRadius: 20)

                            // Only show replay button when tutorial is not currently active
                            if !tutorialManager.isActive {
                                tutorialReplaySection
                            }

                            splitHistorySection
                            Spacer(minLength: 40)
                        }
                        .padding(20)
                    }
                    .onAppear { scrollProxy = proxy }
                }

                if tutorialManager.isActive && tutorialManager.isCurrentStep(in: .profile) {
                    ProfileTutorialOverlay(
                        onNext: {
                            if tutorialManager.isLastStep {
                                tutorialManager.complete()
                            } else {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    tutorialManager.nextStep()
                                }
                            }
                        },
                        onSkip: {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                tutorialManager.skip()
                            }
                        }
                    )
                    .zIndex(200)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        HapticManager.impact(style: .light)
                        if tutorialManager.isActive && tutorialManager.currentStepIndex == 2 {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                tutorialManager.nextStep()
                            }
                        } else {
                            dismiss()
                        }
                    }) {
                        ZStack {
                            Circle().fill(Color.primary.opacity(0.08)).frame(width: 32, height: 32)
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.primary.opacity(0.7))
                        }
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
        }
        .onChange(of: selectedPhoto) { _, newValue in
            Task {
                if let data = try? await newValue?.loadTransferable(type: Data.self) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        appState.profile.avatarImage = data
                    }
                }
                selectedPhoto = nil
            }
        }
        .onChange(of: selectedQRCodeItem) { _, newValue in
            Task {
                if let data = try? await newValue?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    if let extractedLink = QRCodeScanner.extractPaymentLink(from: image) {
                        let isValid = QRCodeScanner.validateZelleQRLink(extractedLink)
                        if isValid {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                appState.profile.zelleQRCode = data
                                appState.profile.zellePaymentLink = extractedLink
                            }
                            HapticManager.notification(type: .success)
                        } else {
                            qrScanErrorMessage = "This doesn't appear to be a valid Zelle QR code."
                            showQRScanError = true
                            HapticManager.notification(type: .error)
                        }
                    } else {
                        qrScanErrorMessage = "Unable to scan QR code. Please make sure the image is clear and the QR code is fully visible."
                        showQRScanError = true
                        HapticManager.notification(type: .error)
                    }
                }
                selectedQRCodeItem = nil
                showingQRPicker = false
            }
        }
        .sheet(item: $selectedHistoryRecord) { record in
            NavigationView {
                SplitHistoryDetailView(record: record)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert("QR Code Error", isPresented: $showQRScanError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(qrScanErrorMessage)
        }
        .onAppear {
            if tutorialManager.isActive && (tutorialManager.currentStepIndex == 2 || tutorialManager.currentStepIndex == 7) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        scrollProxy?.scrollTo("paymentSection", anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var avatarSection: some View {
        VStack(spacing: 20) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(
                    imageData: appState.profile.avatarImage,
                    initials: appState.profile.initials,
                    size: 110
                )
                .overlay(Circle().stroke(
                    LinearGradient(colors: [Color.primary.opacity(0.15), Color.primary.opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3))
                .shadow(color: Color.primary.opacity(0.12), radius: 16, y: 8)

                Button(action: { HapticManager.impact(style: .medium); showingAvatarPicker = true }) {
                    ZStack {
                        Circle().fill(Color.primary).frame(width: 36, height: 36)
                            .shadow(color: Color.primary.opacity(0.3), radius: 8, y: 4)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(colorScheme == .dark ? .black : .white)
                    }
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.9))
                .offset(x: 4, y: 4)
            }

            Text(appState.profile.name.isEmpty ? "Set your name" : appState.profile.name)
                .font(.system(size: 24, weight: .bold)).foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .photosPicker(isPresented: $showingAvatarPicker, selection: $selectedPhoto, matching: .images)
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Identity", icon: "person.fill")
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                        .textCase(.uppercase).tracking(0.8)
                    TextField("Your name", text: $appState.profile.name)
                        .font(.system(size: 16, weight: .medium)).padding(16)
                        .background(Color(.secondarySystemBackground)).cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                        .shadow(color: Color.primary.opacity(0.03), radius: 4, y: 2)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Zelle Phone or Email").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                        .textCase(.uppercase).tracking(0.8)
                    TextField("Phone number or email", text: Binding(
                        get: { appState.profile.zelleContactInfo ?? "" },
                        set: { appState.profile.zelleContactInfo = $0.isEmpty ? nil : $0 }
                    ))
                    .font(.system(size: 16, weight: .medium)).keyboardType(.emailAddress).autocapitalization(.none).autocorrectionDisabled()
                    .padding(16)
                    .background(Color(.secondarySystemBackground)).cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                    .shadow(color: Color.primary.opacity(0.03), radius: 4, y: 2)
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill").font(.system(size: 11))
                            .foregroundColor(Color(red: 0.42, green: 0.22, blue: 0.69).opacity(0.8))
                        Text("Used to send Zelle payment requests to others")
                            .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 2)
                }
            }
            .padding(20).background(Color(.tertiarySystemBackground)).cornerRadius(18)
        }
    }

    private var paymentMethodsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Payment Methods", icon: "creditcard.fill")
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(LinearGradient(
                                    colors: [Color(red: 0.2, green: 0.53, blue: 0.96).opacity(0.2),
                                             Color(red: 0.2, green: 0.53, blue: 0.96).opacity(0.1)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 40, height: 40)
                            Image(systemName: "v.circle.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(Color(red: 0.2, green: 0.53, blue: 0.96))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Venmo Quick Pay").font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)
                            Text("Enable one-tap payment links").font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
                        }
                        Spacer()
                        ShareToggleButton(isShared: Binding(
                            get: { appState.profile.venmoShared ?? true },
                            set: { appState.profile.venmoShared = $0 }
                        ))
                    }
                    .padding(.bottom, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Venmo Username").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                            .textCase(.uppercase).tracking(0.8)
                        TextField("@username", text: Binding(
                            get: { appState.profile.venmoUsername ?? "" },
                            set: {
                                let cleaned = $0.replacingOccurrences(of: "@", with: "")
                                appState.profile.venmoUsername = cleaned.isEmpty ? nil : cleaned
                            }
                        ))
                        .font(.system(size: 16, weight: .medium)).autocapitalization(.none).autocorrectionDisabled()
                        .padding(16).background(Color(.secondarySystemBackground)).cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                        .shadow(color: Color.primary.opacity(0.03), radius: 4, y: 2)

                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill").font(.system(size: 11))
                                .foregroundColor(Color(red: 0.2, green: 0.53, blue: 0.96))
                            Text("Recipients can tap the Venmo link to pay you directly in the app")
                                .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .padding(20).background(Color(.tertiarySystemBackground)).cornerRadius(18)
            }
        }
    }

    private var qrCodeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    sectionHeader(title: "Zelle QR Code", icon: "qrcode")
                    Spacer()
                    if appState.profile.zelleQRCode != nil {
                        ShareToggleButton(isShared: Binding(
                            get: { appState.profile.zelleQRShared ?? true },
                            set: { appState.profile.zelleQRShared = $0 }
                        ))
                    }
                }
                Text("Upload your Zelle payment QR code for automatic link extraction")
                    .font(.system(size: 14, weight: .medium)).foregroundColor(.secondary).padding(.leading, 2)
            }

            if let qrCodeData = appState.profile.zelleQRCode, let qrImage = UIImage(data: qrCodeData) {
                VStack(spacing: 20) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemBackground))
                            .shadow(color: Color.primary.opacity(0.08), radius: 16, y: 8)
                        VStack(spacing: 16) {
                            Image(uiImage: qrImage).resizable().interpolation(.none).scaledToFit()
                                .frame(maxWidth: 240, maxHeight: 240).cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                                .padding(20).background(Color(red: 0.42, green: 0.22, blue: 0.69).opacity(0.05)).cornerRadius(16)
                            VStack(spacing: 8) {
                                Text("Scan to pay via Zelle").font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
                                if appState.profile.zellePaymentLink != nil {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundColor(.green)
                                        Text("Payment link extracted").font(.system(size: 11, weight: .semibold)).foregroundColor(.green)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 4).background(Color.green.opacity(0.1)).cornerRadius(8)
                                }
                            }
                            .padding(.bottom, 4)
                        }
                        .padding(16)
                    }

                    HStack(spacing: 12) {
                        Button(action: { HapticManager.impact(style: .light); showingQRPicker = true }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 14, weight: .semibold))
                                Text("Replace").font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundColor(.primary).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color(.secondarySystemBackground)).cornerRadius(14)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.15), lineWidth: 1.5))
                        }
                        .buttonStyle(ScaleButtonStyle())

                        Button(action: {
                            HapticManager.notification(type: .warning)
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                appState.profile.zelleQRCode = nil
                                appState.profile.zellePaymentLink = nil
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "trash.fill").font(.system(size: 14, weight: .semibold))
                                Text("Remove").font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(LinearGradient(colors: [Color.red, Color.red.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .cornerRadius(14).shadow(color: Color.red.opacity(0.3), radius: 8, y: 4)
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                }
            } else {
                Button(action: { HapticManager.impact(style: .medium); showingQRPicker = true }) {
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [Color(red: 0.42, green: 0.22, blue: 0.69).opacity(0.15),
                                             Color(red: 0.42, green: 0.22, blue: 0.69).opacity(0.05)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 80, height: 80)
                            Image(systemName: "qrcode.viewfinder").font(.system(size: 36, weight: .semibold))
                                .foregroundColor(Color(red: 0.42, green: 0.22, blue: 0.69).opacity(0.6))
                        }
                        VStack(spacing: 6) {
                            Text("Add Zelle QR Code").font(.system(size: 18, weight: .bold)).foregroundColor(.primary)
                            Text("We'll automatically extract the payment link")
                                .font(.system(size: 14, weight: .medium)).foregroundColor(.secondary).multilineTextAlignment(.center)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 13, weight: .semibold))
                            Text("Tap to upload from photos").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(Color(red: 0.42, green: 0.22, blue: 0.69).opacity(0.7))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color(red: 0.42, green: 0.22, blue: 0.69).opacity(0.1)).cornerRadius(20)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 48)
                    .background(Color(.secondarySystemBackground)).cornerRadius(20)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(
                        Color(red: 0.42, green: 0.22, blue: 0.69).opacity(0.3),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                    .shadow(color: Color.primary.opacity(0.04), radius: 8, y: 4)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.98))
            }
        }
        .photosPicker(isPresented: $showingQRPicker, selection: $selectedQRCodeItem, matching: .images)
    }

    // MARK: - Tutorial Replay Section

    private var tutorialReplaySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Tutorial", icon: "play.circle.fill")

            Button(action: {
                HapticManager.impact(style: .medium)
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    tutorialManager.start()
                }
            }) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 52, height: 52)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Replay Tutorial")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("See how Dutchie works again")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(16)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: Color.primary.opacity(0.04), radius: 8, y: 4)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.98))
        }
    }

    // MARK: - Split History Section

    private var splitHistorySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                sectionHeader(title: "Recent Splits", icon: "clock.fill")
                Spacer()
                if !appState.profile.splitHistory.isEmpty {
                    Text("\(appState.profile.splitHistory.count)")
                        .font(.system(size: 14, weight: .bold)).foregroundColor(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.08)).cornerRadius(8)
                    Button(action: {
                        HapticManager.notification(type: .warning)
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            appState.profile.splitHistory.removeAll(); historySearchText = ""
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash.fill").font(.system(size: 12, weight: .semibold))
                            Text("Clear").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(LinearGradient(colors: [Color.red, Color.red.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .cornerRadius(8).shadow(color: Color.red.opacity(0.3), radius: 4, y: 2)
                    }
                    .buttonStyle(ScaleButtonStyle(scale: 0.95))
                }
            }

            if !appState.profile.splitHistory.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)).foregroundColor(.secondary)
                    TextField("Search splits...", text: $historySearchText)
                        .font(.system(size: 15, weight: .medium)).foregroundColor(.primary)
                    if !historySearchText.isEmpty {
                        Button(action: { HapticManager.impact(style: .light); historySearchText = "" }) {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(14).background(Color(.secondarySystemBackground)).cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                .shadow(color: Color.primary.opacity(0.02), radius: 4, y: 2)
            }

            if appState.profile.splitHistory.isEmpty {
                VStack(spacing: 16) {
                    ZStack {
                        Circle().fill(Color.primary.opacity(0.06)).frame(width: 72, height: 72)
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 32)).foregroundColor(.secondary)
                    }
                    VStack(spacing: 6) {
                        Text("No split history yet").font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)
                        Text("Your past splits will appear here").font(.system(size: 14, weight: .medium)).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 48)
                .background(Color(.secondarySystemBackground)).cornerRadius(20)
                .shadow(color: Color.primary.opacity(0.04), radius: 8, y: 2)
            } else if filteredHistory.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass").font(.system(size: 32)).foregroundColor(.secondary)
                    Text("No results found").font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)
                    Text("Try a different search term").font(.system(size: 14, weight: .medium)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 48)
                .background(Color(.secondarySystemBackground)).cornerRadius(20)
                .shadow(color: Color.primary.opacity(0.04), radius: 8, y: 2)
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(filteredHistory.prefix(5))) { record in
                        SplitHistoryCard(record: record) {
                            HapticManager.impact(style: .light)
                            selectedHistoryRecord = record
                        }
                    }
                    if filteredHistory.count > 5 {
                        Text("+ \(filteredHistory.count - 5) more")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundColor(.secondary)
            Text(title).font(.system(size: 20, weight: .bold)).foregroundColor(.primary)
        }
        .padding(.leading, 2)
    }
}

// MARK: - Share Toggle Button
struct ShareToggleButton: View {
    @Binding var isShared: Bool

    var body: some View {
        Button(action: {
            HapticManager.impact(style: .light)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isShared.toggle()
            }
        }) {
            HStack(spacing: 5) {
                Image(systemName: isShared ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(isShared ? "Shared" : "Hidden")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(isShared ? Color.green : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isShared ? Color.green.opacity(0.12) : Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isShared ? Color.green.opacity(0.3) : Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.95))
    }
}

// MARK: - Profile Tutorial Overlay
struct ProfileTutorialOverlay: View {
    @EnvironmentObject var tutorialManager: TutorialManager
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if tutorialManager.isActive,
                   let step = tutorialManager.currentStep,
                   tutorialManager.isCurrentStep(in: .profile) {

                    overlayWithCutout(step: step)
                        .allowsHitTesting(false)
                        .zIndex(1)

                    if tutorialManager.spotlightFrame != .zero && step.targetView != .fullScreen {
                        glowBorder
                            .allowsHitTesting(false)
                            .zIndex(2)
                    }

                    VStack {
                        card(step: step)
                            .padding(.horizontal, 20)
                            .padding(.top, 60)
                        Spacer()
                    }
                    .zIndex(3)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func overlayWithCutout(step: TutorialStep) -> some View {
        let pad: CGFloat = 12
        let frame = tutorialManager.spotlightFrame
        let hasHole = frame != .zero && step.targetView != .fullScreen
        let cutout = hasHole
            ? CGRect(x: frame.minX - pad, y: frame.minY - pad,
                     width: frame.width + pad * 2, height: frame.height + pad * 2)
            : CGRect.zero
        return Color.black.opacity(0.75).ignoresSafeArea()
            .mask(SpotlightMask(cutoutRect: cutout, cornerRadius: 18))
    }

    private var glowBorder: some View {
        let pad: CGFloat = 12
        let frame = tutorialManager.spotlightFrame
        let rect = CGRect(x: frame.minX - pad, y: frame.minY - pad,
                          width: frame.width + pad * 2, height: frame.height + pad * 2)
        return RoundedRectangle(cornerRadius: 18)
            .stroke(Color.accentColor, lineWidth: 3)
            .shadow(color: Color.accentColor.opacity(0.7), radius: 8)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func card(step: TutorialStep) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(0..<tutorialManager.totalSteps, id: \.self) { index in
                    Capsule()
                        .fill(index <= tutorialManager.currentStepIndex ? Color.accentColor : Color.white.opacity(0.25))
                        .frame(height: 4).frame(maxWidth: .infinity)
                }
            }

            Text(step.title)
                .font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                .multilineTextAlignment(.center).lineLimit(2)

            Text(step.description)
                .font(.system(size: 14, weight: .medium)).foregroundColor(.white.opacity(0.88))
                .multilineTextAlignment(.center).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if tutorialManager.isLastStep {
                    Button(action: {
                        HapticManager.notification(type: .success)
                        onNext()
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
                    Button(action: { HapticManager.impact(style: .light); onSkip() }) {
                        Text("Skip")
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.white.opacity(0.15)).cornerRadius(12)
                    }
                    .buttonStyle(ScaleButtonStyle())

                    Button(action: { HapticManager.impact(style: .medium); onNext() }) {
                        HStack(spacing: 6) {
                            Text("Next").font(.system(size: 14, weight: .bold))
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
    }
}

// MARK: - Split History Card
struct SplitHistoryCard: View {
    let record: SplitRecord
    let onTap: () -> Void

    var body: some View {
        Button(action: { HapticManager.impact(style: .light); onTap() }) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(
                            colors: record.yourBalance >= 0
                                ? [Color.green.opacity(0.15), Color.green.opacity(0.05)]
                                : [Color.red.opacity(0.15), Color.red.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 56, height: 56)
                    Image(systemName: record.yourBalance >= 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(record.yourBalance >= 0 ? .green : .red)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(record.formattedTotal).font(.system(size: 20, weight: .bold)).foregroundColor(.primary).lineLimit(1)
                        Text("•").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                        Text("\(record.participantCount) people").font(.system(size: 14, weight: .medium)).foregroundColor(.secondary).lineLimit(1)
                    }
                    Text("\(record.formattedDate) • \(record.formattedTime)")
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.secondary).lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    if record.yourBalance != 0 {
                        Text(record.yourBalance > 0 ? "OWED" : "OWE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(record.yourBalance >= 0 ? .green : .red).tracking(0.5)
                        Text(record.formattedBalance).font(.system(size: 18, weight: .bold))
                            .foregroundColor(record.yourBalance >= 0 ? .green : .red)
                    } else {
                        Text("SETTLED").font(.system(size: 10, weight: .bold)).foregroundColor(.green).tracking(0.5)
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundColor(.green)
                    }
                }

                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary).padding(.leading, 4)
            }
            .padding(18).background(Color(.secondarySystemBackground)).cornerRadius(18)
            .shadow(color: Color.primary.opacity(0.04), radius: 8, y: 2)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
    }
}

// MARK: - Split History Detail View
struct SplitHistoryDetailView: View {
    @Environment(\.dismiss) var dismiss
    let record: SplitRecord

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("Split Details").font(.system(size: 20, weight: .bold)).foregroundColor(.primary)
                    Spacer()
                    Button(action: { HapticManager.impact(style: .light); dismiss() }) {
                        ZStack {
                            Circle().fill(Color.primary.opacity(0.08)).frame(width: 32, height: 32)
                            Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundColor(.primary.opacity(0.7))
                        }
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
                .background(Color(.secondarySystemBackground))

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 24) {
                        summaryCard
                        settlementsSection
                        Text("\(record.formattedDate) at \(record.formattedTime)")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(.secondary).padding(.top, 8)
                        Spacer(minLength: 40)
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Split Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summaryCard: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: record.yourBalance >= 0
                                ? [Color.green.opacity(0.15), Color.green.opacity(0.05)]
                                : [Color.red.opacity(0.15), Color.red.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 64, height: 64)
                    Image(systemName: record.yourBalance >= 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 28)).foregroundColor(record.yourBalance >= 0 ? .green : .red)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.yourBalance > 0 ? "You were owed" : record.yourBalance < 0 ? "You owed" : "All settled")
                        .font(.system(size: 14, weight: .medium)).foregroundColor(.secondary)
                    if record.yourBalance != 0 {
                        Text(record.formattedBalance).font(.system(size: 32, weight: .bold))
                            .foregroundColor(record.yourBalance >= 0 ? .green : .red)
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
                statItem(icon: "dollarsign.circle.fill", value: record.formattedTotal, label: "Total")
                Divider().frame(height: 40)
                statItem(icon: "person.2.fill", value: "\(record.participantCount)", label: "People")
                Divider().frame(height: 40)
                statItem(icon: "list.bullet", value: "\(record.transactionCount)", label: "Items")
            }
        }
        .padding(24).background(Color(.secondarySystemBackground)).cornerRadius(20)
        .shadow(color: Color.primary.opacity(0.06), radius: 12, y: 4)
    }

    private var settlementsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: 16, weight: .semibold)).foregroundColor(.secondary)
                Text("Settlements").font(.system(size: 20, weight: .bold)).foregroundColor(.primary)
            }
            .padding(.horizontal, 4)
            VStack(spacing: 12) {
                ForEach(record.settlements) { settlementRow($0) }
            }
        }
    }

    private func settlementRow(_ settlement: SettlementSnapshot) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.08)).frame(width: 44, height: 44)
                Image(systemName: "arrow.right").font(.system(size: 16, weight: .semibold)).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(settlement.fromName).font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                    Text(settlement.toName).font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
                }
                Text(settlement.formattedAmount).font(.system(size: 14, weight: .medium)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(16).background(Color(.secondarySystemBackground)).cornerRadius(16)
        .shadow(color: Color.primary.opacity(0.04), radius: 8, y: 2)
    }

    private func statItem(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(.secondary)
                Text(value).font(.system(size: 16, weight: .bold)).foregroundColor(.primary)
            }
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
