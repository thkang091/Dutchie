import SwiftUI

// Static flag lives outside SwiftUI lifecycle — never resets accidentally
private var sharedImagesAlreadyProcessed = false

@main
struct DutchieApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var router = Router()
    @StateObject private var tutorialManager = TutorialManager()
    
    private let appGroupID = "group.com.taehoonkang.dutchi"
    
    var body: some Scene {
        WindowGroup {
            ContentRoot()
                .environmentObject(appState)
                .environmentObject(router)
                .environmentObject(tutorialManager)
                .onAppear {
                    tutorialManager.router = router
                    tutorialManager.appState = appState
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        processSharedIfNeeded()
                    }
                }
                .onOpenURL { url in
                    if url.scheme == "dutchi" {
                        // Handle both dutchi://import and dutchi://shared-receipts
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            processSharedIfNeeded()
                        }
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.willEnterForegroundNotification
                    )
                ) { _ in
                    // Reset on every foreground so new shares are always picked up
                    sharedImagesAlreadyProcessed = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        processSharedIfNeeded()
                    }
                }
        }
    }
    
    private func processSharedIfNeeded() {
        guard !sharedImagesAlreadyProcessed else {
            print("Shared images already processed, skipping")
            return
        }
        guard hasPendingSharedImages() else { return }
        sharedImagesAlreadyProcessed = true
        handleSharedReceipts()
    }
    
    private func hasPendingSharedImages() -> Bool {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return false }
        let indexURL = containerURL.appendingPathComponent("pending_receipts.json")
        guard let data = try? Data(contentsOf: indexURL),
              let filenames = try? JSONSerialization.jsonObject(with: data) as? [String] else { return false }
        return !filenames.isEmpty
    }
    
    private func handleSharedReceipts() {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        
        let indexURL = containerURL.appendingPathComponent("pending_receipts.json")
        
        guard let data = try? Data(contentsOf: indexURL),
              let filenames = try? JSONSerialization.jsonObject(with: data) as? [String],
              !filenames.isEmpty else { return }
        
        print("✅ Processing \(filenames.count) shared image(s)")
        try? FileManager.default.removeItem(at: indexURL)
        
        let folder = containerURL.appendingPathComponent("SharedReceipts")
        let totalCount = filenames.count
        
        // Reset to root — the root UploadView is already there, don't push another one
        router.reset()
        
        for (index, filename) in filenames.enumerated() {
            let fileURL = folder.appendingPathComponent(filename)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(index) * 0.6) {
                if let imageData = try? Data(contentsOf: fileURL),
                   let image = UIImage(data: imageData) {
                    print("✅ Posting image \(index + 1)/\(totalCount)")
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ProcessSharedImage"),
                        object: image
                    )
                }
                if index == totalCount - 1 {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        }
    }
    
    struct ContentRoot: View {
        @EnvironmentObject var router: Router
        @EnvironmentObject var tutorialManager: TutorialManager
        
        var body: some View {
            ZStack {
                if router.showLogoIntro {
                    LogoIntroView()
                } else {
                    MainView()
                }
            }
        }
    }
    
    struct MainView: View {
        @EnvironmentObject var appState: AppState
        @EnvironmentObject var router: Router
        @EnvironmentObject var tutorialManager: TutorialManager
        
        var body: some View {
            NavigationStack(path: $router.path) {
                UploadView()
                    .navigationDestination(for: String.self) { destination in
                        switch destination {
                        case "upload":  UploadView()
                        case "people":  PeopleView()
                        case "processing": ProcessingView()
                        case "review":  ReviewView()
                        case "settle":  SettleShareView()
                        default:        UploadView()
                        }
                    }
            }
            .sheet(isPresented: $router.showProfile) {
                ProfileView()
                    .environmentObject(appState)
                    .environmentObject(router)
                    .environmentObject(tutorialManager)
            }
        }
    }
}
