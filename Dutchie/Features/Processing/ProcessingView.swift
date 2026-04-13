import SwiftUI

struct ProcessingView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    
    @State private var isProcessing = true
    @State private var progress: Double = 0
    
    var body: some View {
        VStack {
            Spacer()
            
            VStack(spacing: 24) {
                // Processing icon
                ZStack {
                    Circle()
                        .stroke(Color.black.opacity(0.1), lineWidth: 4)
                        .frame(width: 100, height: 100)
                    
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.black, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 100, height: 100)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: progress)
                    
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.black)
                }
                
                Text("Processing receipts...")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.black)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGray6))
        .navigationBarBackButtonHidden(true)
        .onAppear {
            simulateProcessing()
        }
    }
    
    private func simulateProcessing() {
        // Simulate OCR processing
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            progress += 0.05
            
            if progress >= 1.0 {
                timer.invalidate()
                
                // Create transactions from uploaded data
                createTransactions()
                
                // Navigate to review after a brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    router.navigateToReview()
                }
            }
        }
    }
    
    private func createTransactions() {
        // Create transactions from uploaded images
        for (index, image) in appState.uploadedImages.enumerated() {
            let transaction = Transaction(
                amount: Double.random(in: 20...150),
                merchant: "Transaction \(index + 1)",
                paidBy: appState.people.first(where: { $0.isCurrentUser }) ?? appState.people[0],
                splitWith: appState.people,
                receiptImage: image.jpegData(compressionQuality: 0.8)
            )
            appState.transactions.append(transaction)
        }
        
        // Create transactions from manual entries
        for manual in appState.manualTransactions {
            let transaction = Transaction(
                amount: manual.amount,
                merchant: manual.name,
                paidBy: appState.people.first(where: { $0.isCurrentUser }) ?? appState.people[0],
                splitWith: appState.people,
                isManual: true
            )
            appState.transactions.append(transaction)
        }
    }
}
