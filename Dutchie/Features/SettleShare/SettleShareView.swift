import SwiftUI
import UIKit

struct SettleShareView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    
    @State private var settlements: [PaymentLink] = []
    @State private var showShareSheet = false
    
    var totalTransactions: Int {
        appState.transactions.filter { $0.includeInSplit }.count
    }
    
    var currentUserBalance: Double {
        var balance: Double = 0
        let currentUserId = appState.people.first(where: { $0.isCurrentUser })?.id
        
        for settlement in settlements {
            if settlement.from.id == currentUserId {
                balance -= settlement.amount
            } else if settlement.to.id == currentUserId {
                balance += settlement.amount
            }
        }
        
        return balance
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    router.navigateBack()
                }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.black)
                }
                
                Spacer()
                
                Text("Settle Summary")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black)
                
                Spacer()
                
                // Placeholder for symmetry
                Color.clear
                    .frame(width: 40)
            }
            .padding(20)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Summary
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(.gray)
                            
                            Text("\(totalTransactions) transactions • split among \(appState.people.count) people")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                        }
                        
                        HStack {
                            Image(systemName: currentUserBalance >= 0 ? "arrow.down.circle" : "arrow.up.circle")
                                .foregroundColor(currentUserBalance >= 0 ? .green : .red)
                            
                            if currentUserBalance > 0 {
                                Text("You are owed \(String(format: "$%.2f", currentUserBalance))")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.green)
                            } else if currentUserBalance < 0 {
                                Text("You owe \(String(format: "$%.2f", abs(currentUserBalance)))")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.red)
                            } else {
                                Text("You're all settled")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.black)
                            }
                        }
                    }
                    .padding(16)
                    .background(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.black, lineWidth: 1)
                    )
                    
                    // Settlement List
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Settlements")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.black)
                        
                        ForEach($settlements) { $settlement in
                            SettlementRowView(settlement: $settlement)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGray6))
            
            // Bottom Actions
            VStack(spacing: 12) {
                Button(action: {
                    copyAllSettlements()
                }) {
                    HStack {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 16))
                        
                        Text("Copy All")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.black, lineWidth: 1)
                    )
                }
                
                Button(action: {
                    showShareSheet = true
                }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16))
                        
                        Text("Share")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.black)
                    .cornerRadius(12)
                }
            }
            .padding(20)
            .background(Color.white)
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            settlements = appState.calculateSettlements()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [generateShareText()])
        }
    }
    
    private func copyAllSettlements() {
        UIPasteboard.general.string = generateShareText()
    }
    
    private func generateShareText() -> String {
        var text = "💰 Settlement Summary\n\n"
        
        for settlement in settlements {
            text += "\(settlement.from.name) → \(settlement.to.name): \(settlement.formattedAmount)\n"
        }
        
        text += "\n"
        
        // Add payment methods
        let enabledMethods = appState.profile.paymentMethods.filter { $0.includeWhenSharing }
        
        if !enabledMethods.isEmpty {
            text += "Payment Methods:\n"
            
            for method in enabledMethods {
                if !method.value.isEmpty {
                    text += "\(method.type.rawValue): \(method.value)\n"
                }
            }
        }
        
        return text
    }
}

struct SettlementRowView: View {
    @Binding var settlement: PaymentLink
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AvatarView(
                        imageData: settlement.from.contactImage,
                        initials: settlement.from.initials,
                        size: 32
                    )
                    
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                    
                    AvatarView(
                        imageData: settlement.to.contactImage,
                        initials: settlement.to.initials,
                        size: 32
                    )
                }
                
                Text("\(settlement.from.name) → \(settlement.to.name)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.black)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 8) {
                Text(settlement.formattedAmount)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.black)
                
                Button(action: {
                    UIPasteboard.general.string = settlement.formattedAmount
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                        
                        Text("Copy")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.black)
                }
            }
            
            Toggle("", isOn: $settlement.isPaid)
                .labelsHidden()
                .toggleStyle(CheckboxToggleStyle())
        }
        .padding(16)
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(settlement.isPaid ? Color.green : Color.black, lineWidth: 1)
        )
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: {
            configuration.isOn.toggle()
        }) {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 24))
                .foregroundColor(configuration.isOn ? .green : .black)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
