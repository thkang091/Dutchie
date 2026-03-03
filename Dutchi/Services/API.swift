import Foundation

enum API {
    static var tabscannerAPIKey: String {
        guard let key = Bundle.main.infoDictionary?["TABSCANNER_API_KEY"] as? String else {
            fatalError("TABSCANNER_API_KEY not set")
        }
        return key
    }
    
    static var openAIAPIKey: String {
        guard let key = Bundle.main.infoDictionary?["OPENAI_API_KEY"] as? String else {
            fatalError("OPENAI_API_KEY not set")
        }
        return key
    }
}
