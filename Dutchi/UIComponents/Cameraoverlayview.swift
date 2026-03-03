import SwiftUI

enum ScanTutorialMode {
    case receipt
    case transaction
}

struct ScanTutorialView: View {
    @Binding var isVisible: Bool
    @Environment(\.colorScheme) var colorScheme

    let mode: ScanTutorialMode
    let onContinue: () -> Void

    var body: some View {
        if mode == .transaction {
            TransactionTutorialView(isVisible: $isVisible, onContinue: onContinue)
        } else {
            ReceiptTutorialView(isVisible: $isVisible, onContinue: onContinue)
        }
    }
}

struct ReceiptTutorialView: View {
    @Binding var isVisible: Bool
    @Environment(\.colorScheme) var colorScheme

    let onContinue: () -> Void

    @State private var opacity: Double = 0
    @State private var wrongCardOffset: CGFloat = 44
    @State private var rightCardOffset: CGFloat = 44
    @State private var wrongCardOpacity: Double = 0
    @State private var rightCardOpacity: Double = 0
    @State private var badgeScale: CGFloat = 0

    private var bgColor: Color {
        colorScheme == .dark ? Color(white: 0.07) : Color(white: 0.10)
    }
    private var textSecondary: Color { Color.white.opacity(0.58) }
    private var cardSurface: Color { Color.white.opacity(colorScheme == .dark ? 0.08 : 0.11) }

    private let tips: [(icon: String, text: String)] = [
        ("light.max",                       "Good light"),
        ("hand.raised.fill",                "Hold steady"),
        ("doc.text.viewfinder",             "Full receipt"),
        ("camera.metering.center.weighted", "Tap to focus"),
    ]

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("Scan Your Receipt")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Position your receipt like the example on the right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .padding(.top, 52)
                .padding(.bottom, 28)

                HStack(alignment: .top, spacing: 14) {
                    receiptPhoneCard(isCorrect: false)
                        .offset(y: wrongCardOffset)
                        .opacity(wrongCardOpacity)
                    receiptPhoneCard(isCorrect: true)
                        .offset(y: rightCardOffset)
                        .opacity(rightCardOpacity)
                }
                .padding(.horizontal, 20)

                Spacer()

                HStack(spacing: 0) {
                    ForEach(tips, id: \.icon) { tip in
                        VStack(spacing: 6) {
                            Image(systemName: tip.icon)
                                .font(.system(size: 17))
                                .foregroundColor(Color.white.opacity(0.70))
                            Text(tip.text)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

                Button(action: dismiss) {
                    HStack(spacing: 10) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Got it — Start Scanning")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Capsule().fill(Color.white))
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 48)
            }
        }
        .opacity(opacity)
        .onAppear { animateIn() }
    }

    private func receiptPhoneCard(isCorrect: Bool) -> some View {
        let badgeColor: Color = isCorrect
            ? Color(red: 0.18, green: 0.75, blue: 0.35)
            : Color(red: 0.88, green: 0.22, blue: 0.18)

        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 22)
                .fill(cardSurface)
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(badgeColor.opacity(0.60), lineWidth: 1.5))
                .frame(width: 152, height: 232)

            receiptIllustration(isCorrect: isCorrect)
                .rotationEffect(.degrees(isCorrect ? 0 : -16))
                .offset(x: isCorrect ? 0 : -10, y: isCorrect ? 24 : 32)
                .frame(width: 152, height: 232)
                .clipShape(RoundedRectangle(cornerRadius: 22))

            Circle()
                .fill(Color.black.opacity(0.70))
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "camera.fill").font(.system(size: 12)).foregroundColor(.white))
                .offset(y: 194)

            ZStack {
                Circle().fill(badgeColor).frame(width: 34, height: 34)
                    .shadow(color: badgeColor.opacity(0.45), radius: 6, x: 0, y: 3)
                Image(systemName: isCorrect ? "checkmark" : "xmark")
                    .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
            }
            .scaleEffect(badgeScale)
            .offset(x: 57, y: -14)
        }
        .frame(width: 152, height: 240)
        .overlay(
            VStack(spacing: 4) {
                Text(isCorrect ? "Do this" : "Don't do this")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(isCorrect
                        ? Color(red: 0.18, green: 0.75, blue: 0.35)
                        : Color(red: 0.88, green: 0.22, blue: 0.18))
                Text(isCorrect ? "Flat, centered,\nand fully visible" : "Tilted, cropped,\nor blurry")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(textSecondary)
                    .multilineTextAlignment(.center)
            }
            .offset(y: 152),
            alignment: .top
        )
    }

    private func receiptIllustration(isCorrect: Bool) -> some View {
        let lineOpacity: Double = isCorrect ? 0.38 : 0.18
        return RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(colorScheme == .dark ? 0.88 : 0.93))
            .frame(width: isCorrect ? 90 : 106, height: isCorrect ? 166 : 154)
            .overlay(
                VStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(lineOpacity + 0.1)).frame(width: 56, height: 9)
                    Divider().opacity(0.25)
                    VStack(spacing: 5) {
                        ForEach(0..<5, id: \.self) { _ in
                            HStack {
                                RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(lineOpacity)).frame(width: 44, height: 6)
                                Spacer()
                                RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(lineOpacity)).frame(width: 20, height: 6)
                            }
                        }
                    }
                    HStack(spacing: 2) {
                        ForEach(0..<13, id: \.self) { _ in
                            Circle().fill(Color.gray.opacity(0.28)).frame(width: 3, height: 3)
                        }
                    }
                    Divider().opacity(0.25)
                    HStack {
                        Text("TOTAL").font(.system(size: 7, weight: .bold)).foregroundColor(.gray.opacity(0.5))
                        Spacer()
                        Text("$$$").font(.system(size: 12, weight: .bold)).foregroundColor(.gray.opacity(0.55))
                    }
                }
                .padding(10)
            )
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.28)) { opacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            isVisible = false
            onContinue()
        }
    }

    private func animateIn() {
        withAnimation(.easeIn(duration: 0.3)) { opacity = 1 }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.12)) {
            wrongCardOffset = 0; wrongCardOpacity = 1
        }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.26)) {
            rightCardOffset = 0; rightCardOpacity = 1
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.5).delay(0.52)) {
            badgeScale = 1.0
        }
    }
}

struct TransactionTutorialView: View {
    @Binding var isVisible: Bool
    @Environment(\.colorScheme) var colorScheme

    let onContinue: () -> Void

    @State private var opacity: Double = 0
    @State private var step: Int = 0
    @State private var phoneOpacity: Double = 0
    @State private var phoneOffset: CGFloat = 30
    @State private var screenshotFlash: Double = 0
    @State private var screenshotScale: CGFloat = 1.0
    @State private var thumbOpacity: Double = 0
    @State private var thumbOffset: CGFloat = 12
    @State private var uploadOpacity: Double = 0
    @State private var uploadOffset: CGFloat = 8
    @State private var highlightRow: Int = -1

    private var bgColor: Color {
        colorScheme == .dark ? Color(white: 0.07) : Color(white: 0.10)
    }
    private var textSecondary: Color { Color.white.opacity(0.58) }

    private let stepLabels = [
        "Open your banking app",
        "Screenshot the transactions page",
        "Upload that screenshot here",
    ]

    private let rows: [(icon: String, color: Color, name: String, amount: String)] = [
        ("fork.knife",      Color(red: 0.25, green: 0.55, blue: 0.95), "Restaurant",    "$42.50"),
        ("film",            Color(red: 0.90, green: 0.20, blue: 0.20), "Movie Theatre", "$34.14"),
        ("cart.fill",       Color(red: 0.95, green: 0.35, blue: 0.10), "Grocery Store", "$67.89"),
        ("tram.fill",       Color(red: 0.30, green: 0.70, blue: 0.45), "Gas Station",   "$58.00"),
        ("bag.fill",        Color(red: 0.65, green: 0.25, blue: 0.85), "Department Store","$21.68"),
    ]

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("Upload Your Transactions")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Screenshot your banking app and upload it")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .padding(.top, 52)
                .padding(.bottom, 20)

                ZStack(alignment: .bottomTrailing) {
                    phoneCard
                    screenshotThumbnail
                    uploadBadge
                }
                .frame(width: 260, height: 300)
                .padding(.bottom, 20)

                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        ForEach(0..<3) { i in
                            Capsule()
                                .fill(step == i ? Color.white : Color.white.opacity(0.28))
                                .frame(width: step == i ? 20 : 7, height: 7)
                                .animation(.spring(response: 0.38), value: step)
                        }
                    }
                    Text(stepLabels[min(step, 2)])
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(height: 18)
                        .id(step)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.22), value: step)
                }
                .padding(.bottom, 24)

                Spacer()

                tipsRow
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)

                Button(action: dismissView) {
                    HStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Got it — Choose Screenshot")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Capsule().fill(Color.white))
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 48)
            }
        }
        .opacity(opacity)
        .onAppear { animateIn() }
    }

    private var phoneCard: some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(Color(red: 0.96, green: 0.97, blue: 0.99))
            .frame(width: 210, height: 290)
            .overlay(
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(red: 0.20, green: 0.40, blue: 0.80))
                        Spacer()
                        Text("Transactions")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.black)
                        Spacer()
                        Circle()
                            .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                            .frame(width: 20, height: 20)
                            .overlay(
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(.gray)
                            )
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white)
                        .frame(height: 28)
                        .overlay(
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(red: 0.85, green: 0.88, blue: 0.95))
                                    .frame(width: 32, height: 18)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(red: 0.20, green: 0.40, blue: 0.80).opacity(0.7))
                                    .frame(width: 70, height: 7)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)

                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(row.color.opacity(0.15))
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Image(systemName: row.icon)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(row.color)
                                    )
                                Text(row.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Color(red: 0.10, green: 0.12, blue: 0.18))
                                    .lineLimit(1)
                                Spacer()
                                Text(row.amount)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Color(red: 0.20, green: 0.40, blue: 0.80))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                highlightRow == index
                                    ? Color(red: 0.20, green: 0.40, blue: 0.80).opacity(0.08)
                                    : Color.clear
                            )
                            .animation(.easeInOut(duration: 0.25), value: highlightRow)

                            if index < rows.count - 1 {
                                Divider()
                                    .padding(.leading, 54)
                                    .opacity(0.5)
                            }
                        }
                    }

                    Spacer()
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 6)
            .scaleEffect(screenshotScale)
            .offset(y: phoneOffset)
            .opacity(phoneOpacity)
    }

    private var screenshotThumbnail: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color(red: 0.96, green: 0.97, blue: 0.99))
            .frame(width: 46, height: 62)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white, lineWidth: 2))
            .overlay(
                VStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { i in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(rows[i].color.opacity(0.6))
                                .frame(width: 6, height: 6)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.gray.opacity(0.5))
                                .frame(width: CGFloat(14 + i * 2), height: 3)
                            Spacer()
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color(red: 0.20, green: 0.40, blue: 0.80).opacity(0.6))
                                .frame(width: 8, height: 3)
                        }
                        .padding(.horizontal, 5)
                    }
                }
            )
            .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
            .offset(x: 14, y: 14)
            .offset(y: thumbOffset)
            .opacity(thumbOpacity)
    }

    private var uploadBadge: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.18, green: 0.75, blue: 0.35))
                .frame(width: 30, height: 30)
                .shadow(color: Color(red: 0.18, green: 0.75, blue: 0.35).opacity(0.4), radius: 6, x: 0, y: 3)
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
        }
        .offset(x: 14, y: -14)
        .offset(y: uploadOffset)
        .opacity(uploadOpacity)
    }

    private var tipsRow: some View {
        let tips: [(icon: String, text: String)] = [
            ("apps.iphone",        "Open bank app"),
            ("camera.viewfinder",  "Screenshot it"),
            ("photo.on.rectangle", "Upload here"),
            ("list.bullet",        "All rows visible"),
        ]
        return HStack(spacing: 0) {
            ForEach(tips, id: \.icon) { tip in
                VStack(spacing: 6) {
                    Image(systemName: tip.icon)
                        .font(.system(size: 17))
                        .foregroundColor(Color.white.opacity(0.70))
                    Text(tip.text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.58))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func animateIn() {
        withAnimation(.easeIn(duration: 0.3)) { opacity = 1 }

        withAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(0.15)) {
            phoneOpacity = 1
            phoneOffset = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            cycleRowHighlights(index: 0)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeIn(duration: 0.15)) { step = 1 }
            withAnimation(.easeIn(duration: 0.05).delay(0.05)) { screenshotFlash = 0.0 }
            withAnimation(.easeOut(duration: 0.10).delay(0.05)) { screenshotScale = 0.94 }
            withAnimation(.spring(response: 0.25).delay(0.16)) { screenshotScale = 1.0 }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.75)) {
                thumbOpacity = 1
                thumbOffset = 0
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            withAnimation(.easeIn(duration: 0.15)) { step = 2 }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72).delay(0.08)) {
                uploadOpacity = 1
                uploadOffset = 0
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
            withAnimation(.easeOut(duration: 0.3)) {
                thumbOpacity = 0
                uploadOpacity = 0
            }
            withAnimation(.easeOut(duration: 0.35).delay(0.25)) {
                phoneOpacity = 0
                phoneOffset = 30
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                step = 0
                highlightRow = -1
                thumbOffset = 12
                uploadOffset = 8
                animateIn()
            }
        }
    }

    private func cycleRowHighlights(index: Int) {
        guard index < rows.count else {
            highlightRow = -1
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { highlightRow = index }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(.easeInOut(duration: 0.15)) { highlightRow = -1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                cycleRowHighlights(index: index + 1)
            }
        }
    }

    private func dismissView() {
        withAnimation(.easeOut(duration: 0.28)) { opacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            isVisible = false
            onContinue()
        }
    }
}

struct CameraOverlayView: View {
    @Binding var isVisible: Bool
    let mode: ScanTutorialMode
    let onDismiss: () -> Void

    var body: some View {
        ScanTutorialView(isVisible: $isVisible, mode: mode, onContinue: onDismiss)
    }
}

struct CameraInstructionOverlay: View {
    @State private var showOverlay = true
    let mode: ScanTutorialMode
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            if showOverlay {
                CameraOverlayView(isVisible: $showOverlay, mode: mode, onDismiss: onDismiss)
            }
        }
    }
}
