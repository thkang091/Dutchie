import SwiftUI
import Combine

@MainActor
class Router: ObservableObject {
    @Published var path = NavigationPath()
    @Published var showProfile = false
    
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
    
    func reset() {
        path = NavigationPath()
    }
}
