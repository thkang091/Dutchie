import SwiftUI

struct ToastView: View {
    let message: String
    let action: (() -> Void)?
    let actionLabel: String?
    
    init(message: String, action: (() -> Void)? = nil, actionLabel: String? = nil) {
        self.message = message
        self.action = action
        self.actionLabel = actionLabel
    }
    
    var body: some View {
        HStack {
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.white)
            
            Spacer()
            
            if let action = action, let actionLabel = actionLabel {
                Button(action: action) {
                    Text(actionLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black)
        .cornerRadius(8)
        .shadow(radius: 4)
    }
}
