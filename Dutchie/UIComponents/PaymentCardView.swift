import SwiftUI

struct PaymentCardView: View {
    @Binding var paymentMethod: PaymentMethod
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(paymentMethod.type.rawValue)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
                
                Spacer()
                
                Toggle("", isOn: $paymentMethod.includeWhenSharing)
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: .black))
            }
            
            TextField(paymentMethod.type.placeholder, text: $paymentMethod.value)
                .font(.system(size: 14))
                .padding(12)
                .background(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.black, lineWidth: 1)
                )
            
            if !paymentMethod.value.isEmpty && paymentMethod.type == .venmo {
                Text(paymentMethod.type.helper + paymentMethod.value.replacingOccurrences(of: "@", with: ""))
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            } else {
                Text(paymentMethod.type.helper)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            
            HStack(spacing: 4) {
                Image(systemName: paymentMethod.includeWhenSharing ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(paymentMethod.includeWhenSharing ? .black : .gray)
                
                Text("Include when sharing")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.black, lineWidth: 1)
                )
        )
    }
}
