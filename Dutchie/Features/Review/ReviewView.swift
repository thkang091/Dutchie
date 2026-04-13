import SwiftUI
import UIKit

struct ReviewView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    
    @State private var showManualAdd = false
    @State private var manualMerchant = ""
    @State private var manualAmount = ""
    @State private var showImageViewer = false
    @State private var selectedImage: UIImage?
    @State private var showEditAmount = false
    @State private var editingTransaction: Transaction?
    @State private var editAmount = ""
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var undoAction: (() -> Void)?
    
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
                
                Text("Review Transactions")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black)
                
                Spacer()
                
                Button(action: {
                    router.showProfile = true
                }) {
                    AvatarView(
                        imageData: appState.profile.avatarImage,
                        initials: appState.profile.initials,
                        size: 40
                    )
                }
            }
            .padding(20)
            
            ScrollView {
                VStack(spacing: 16) {
                    ForEach($appState.transactions) { $transaction in
                        TransactionCardView(
                            transaction: $transaction,
                            allPeople: appState.people,
                            onDelete: {
                                deleteTransaction(transaction)
                            },
                            onEditAmount: {
                                editingTransaction = transaction
                                editAmount = String(format: "%.2f", transaction.amount)
                                showEditAmount = true
                            },
                            onImageTap: {
                                if let imageData = transaction.receiptImage,
                                   let image = UIImage(data: imageData) {
                                    selectedImage = image
                                    showImageViewer = true
                                }
                            }
                        )
                    }
                    
                    // Add manually button
                    Button(action: {
                        showManualAdd = true
                    }) {
                        HStack {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 16))
                            
                            Text("Add Manually")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.black, lineWidth: 1.5)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                        )
                    }
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGray6))
            
            // Toast
            if showToast {
                VStack {
                    Spacer()
                    
                    ToastView(
                        message: toastMessage,
                        action: undoAction,
                        actionLabel: undoAction != nil ? "Undo" : nil
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom))
                }
            }
            
            // Bottom CTA
            Button(action: {
                router.navigateToSettle()
            }) {
                Text("Continue to Settlement")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.black)
                    .cornerRadius(12)
            }
            .padding(20)
            .background(Color.white)
        }
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $showManualAdd) {
            NavigationView {
                VStack(spacing: 20) {
                    TextField("Merchant name", text: $manualMerchant)
                        .font(.system(size: 16))
                        .padding(12)
                        .background(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.black, lineWidth: 1)
                        )
                    
                    TextField("Amount", text: $manualAmount)
                        .font(.system(size: 16))
                        .keyboardType(.decimalPad)
                        .padding(12)
                        .background(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.black, lineWidth: 1)
                        )
                    
                    Spacer()
                }
                .padding(20)
                .background(Color(uiColor: .systemGray6))
                .navigationTitle("Add Transaction")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            showManualAdd = false
                            manualMerchant = ""
                            manualAmount = ""
                        }
                        .foregroundColor(.black)
                    }
                    
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Add") {
                            addManualTransaction()
                        }
                        .foregroundColor(.black)
                        .disabled(manualMerchant.isEmpty || manualAmount.isEmpty)
                    }
                }
            }
        }
        .sheet(isPresented: $showEditAmount) {
            NavigationView {
                VStack(spacing: 20) {
                    TextField("Amount", text: $editAmount)
                        .font(.system(size: 16))
                        .keyboardType(.decimalPad)
                        .padding(12)
                        .background(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.black, lineWidth: 1)
                        )
                    
                    Spacer()
                }
                .padding(20)
                .background(Color(uiColor: .systemGray6))
                .navigationTitle("Edit Amount")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            showEditAmount = false
                        }
                        .foregroundColor(.black)
                    }
                    
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save") {
                            saveEditedAmount()
                        }
                        .foregroundColor(.black)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showImageViewer) {
            if let image = selectedImage {
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                    
                    Button(action: {
                        showImageViewer = false
                    }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .padding()
                }
            }
        }
    }
    
    private func addManualTransaction() {
        guard !manualMerchant.isEmpty,
              let amount = Double(manualAmount),
              amount > 0 else {
            return
        }
        
        let transaction = Transaction(
            amount: amount,
            merchant: manualMerchant,
            paidBy: appState.people.first(where: { $0.isCurrentUser }) ?? appState.people[0],
            splitWith: appState.people,
            isManual: true
        )
        
        appState.transactions.append(transaction)
        showManualAdd = false
        manualMerchant = ""
        manualAmount = ""
    }
    
    private func saveEditedAmount() {
        guard let transaction = editingTransaction,
              let amount = Double(editAmount),
              amount > 0,
              let index = appState.transactions.firstIndex(where: { $0.id == transaction.id }) else {
            return
        }
        
        appState.transactions[index].amount = amount
        showEditAmount = false
        editingTransaction = nil
        editAmount = ""
    }
    
    private func deleteTransaction(_ transaction: Transaction) {
        guard let index = appState.transactions.firstIndex(where: { $0.id == transaction.id }) else {
            return
        }
        
        let deletedTransaction = appState.transactions[index]
        appState.transactions.remove(at: index)
        
        toastMessage = "Transaction removed"
        undoAction = {
            appState.transactions.insert(deletedTransaction, at: index)
            hideToast()
        }
        
        showToast = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            hideToast()
        }
    }
    
    private func hideToast() {
        withAnimation {
            showToast = false
            undoAction = nil
        }
    }
}
