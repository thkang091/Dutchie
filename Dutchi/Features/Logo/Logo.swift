import SwiftUI
import Lottie

struct LogoIntroView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    
    @State private var logoScale: CGFloat = 0.8
    @State private var logoOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var subtitleOpacity: Double = 0
    @State private var accentY: CGFloat = 20
    
    var body: some View {
        logoIntroContent
            .onAppear {
                // Staggered animation sequence
                withAnimation(.easeOut(duration: 0.8)) {
                    logoScale = 1
                    logoOpacity = 1
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeOut(duration: 0.7)) {
                        titleOpacity = 1
                    }
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeOut(duration: 0.7)) {
                        subtitleOpacity = 1
                        accentY = 0
                    }
                }
                
                // Auto-transition after animations complete
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    withAnimation(.easeInOut(duration: 0.8)) {
                        router.dismissLogoIntro()
                    }
                }
            }
    }
    
    private var logoIntroContent: some View {
        ZStack {
            // Clean white background
            Color.white
                .ignoresSafeArea()
            
            // Content
            VStack(spacing: 0) {
                Spacer()
                
                // Logo Animation
                VStack {
                    LottieView(jsonName: "logo")
                        .frame(height: 240)
                        .padding(.horizontal, 40)
                        .scaleEffect(logoScale)
                        .opacity(logoOpacity)
                }
                .frame(maxWidth: .infinity)
                
                Spacer()
                    .frame(height: 40)
                
                // Text Content
                VStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text("Dutchie")
                            .font(.system(size: 42, weight: .bold, design: .default))
                            .tracking(-0.5)
                            .foregroundColor(.black)
                            .opacity(titleOpacity)
                        
                        // Black underline
                        Color.black
                            .frame(height: 3)
                            .frame(width: 120)
                            .cornerRadius(1.5)
                            .opacity(titleOpacity)
                    }
                    
                    Text("Split it easily")
                        .font(.system(size: 18, weight: .medium, design: .default))
                        .tracking(0.3)
                        .foregroundColor(.black.opacity(0.6))
                        .offset(y: accentY)
                        .opacity(subtitleOpacity)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.bottom, 80)
            }
        }
    }
}

// MARK: - Lottie View (Updated for newer Lottie versions)
struct LottieView: UIViewRepresentable {
    let jsonName: String
    
    func makeUIView(context: Context) -> UIView {
        let containerView = UIView()
        containerView.backgroundColor = .clear
        
        // Load animation from bundle - Updated API
        let animationView = LottieAnimationView()
        animationView.animation = LottieAnimation.named(jsonName)
        animationView.contentMode = .scaleAspectFit
        animationView.loopMode = .loop
        animationView.backgroundColor = .clear
        
        containerView.addSubview(animationView)
        animationView.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            animationView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            animationView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            animationView.widthAnchor.constraint(equalTo: containerView.widthAnchor),
            animationView.heightAnchor.constraint(equalTo: containerView.heightAnchor)
        ])
        
        animationView.play()
        
        return containerView
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

#Preview {
    LogoIntroView()
        .environmentObject(AppState())
        .environmentObject(Router())
}
