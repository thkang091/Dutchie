import SwiftUI

@main
struct DutchieApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var router = Router()
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .environmentObject(router)
        }
    }
}

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    
    var body: some View {
        NavigationStack(path: $router.path) {
            UploadView()
                .navigationDestination(for: String.self) { destination in
                    switch destination {
                    case "upload":
                        UploadView()
                    case "people":
                        PeopleView()
                    case "processing":
                        ProcessingView()
                    case "review":
                        ReviewView()
                    case "settle":
                        SettleShareView()
                    default:
                        UploadView()
                    }
                }
        }
        .sheet(isPresented: $router.showProfile) {
            ProfileView()
        }
    }
}
