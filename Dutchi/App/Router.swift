import SwiftUI
import Combine

@MainActor
class Router: ObservableObject {
    @Published var path = NavigationPath()
    @Published var showProfile = false
    @Published var showLogoIntro = true
    
    func navigateToUpload() {
        path.append("upload")
    }
    
    func navigateToPeople() {
        path.append("people")
    }
    
    func navigateToProcessing() {
        path.append("processing")
    }
    
    func navigateToReview() {
        path.append("review")
    }
    
    func navigateToSettle() {
        path.append("settle")
    }
    
    func navigateBack() {
        if !path.isEmpty {
            path.removeLast()
        }
    }
    
    func dismissLogoIntro() {
        showLogoIntro = false
    }
    
    func reset() {
        path = NavigationPath()
        showProfile = false
        showLogoIntro = false
    }
    
    /// Pops everything off the nav stack and closes profile, leaving the user
    /// on the root UploadView. Used after the settle tutorial step so the
    /// profile sheet can open cleanly over a fresh upload screen.
    func resetToUpload() {
        path = NavigationPath()
        showProfile = false
    }
    
    func handleTutorialNavigation(for stepIndex: Int) {
        switch stepIndex {
        case 2:
            showProfile = true
        case 3:
            navigateToPeople()
        case 4, 5:
            navigateToReview()
        case 6:
            // Pop review off the stack, then push settle
            if !path.isEmpty {
                path.removeLast()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.navigateToSettle()
            }
        // Step 7 is handled directly in TutorialManager.nextStep() —
        // it calls resetToUpload() then opens showProfile = true itself,
        // so no case needed here.
        default:
            break
        }
    }
}
