import SwiftUI

struct TransactionCardView: View {
    @Binding var transaction: Transaction
    let allPeople: [Person]
    let onDelete: () -> Void
    let onEditAmount: () -> Void
    let onImageTap: () -> Void
    
    @State private var showPaidByPicker = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(transaction.formattedAmount)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.black)
                    
                    Text(transaction.merchant)
                        .font(.system(size: 16))
                        .foregroundColor(.black)
                }
                
                Spacer()
                
                if let imageData = transaction.receiptImage,
                   let uiImage = UIImage(data: imageData) {
                    Button(action: onImageTap) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.black, lineWidth: 1)
                            )
                    }
                }
            }
            
            // Paid by
            VStack(alignment: .leading, spacing: 6) {
                Text("Paid by")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
                
                Button(action: {
                    showPaidByPicker.toggle()
                }) {
                    ChipView(
                        person: transaction.paidBy,
                        showRemoveButton: false,
                        onTap: { showPaidByPicker.toggle() }
                    )
                }
                .confirmationDialog("Select payer", isPresented: $showPaidByPicker, titleVisibility: .visible) {
                    ForEach(allPeople) { person in
                        Button(person.name) {
                            transaction.paidBy = person
                        }
                    }
                }
            }
            
            // Split with
            VStack(alignment: .leading, spacing: 6) {
                Text("Split with")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(allPeople) { person in
                            ChipView(
                                person: person,
                                showRemoveButton: false,
                                isSelected: transaction.splitWith.contains(where: { $0.id == person.id }),
                                onTap: {
                                    togglePerson(person)
                                }
                            )
                        }
                    }
                }
            }
            
            // Actions
            HStack(spacing: 16) {
                Toggle(isOn: $transaction.includeInSplit) {
                    Text("Include in split")
                        .font(.system(size: 14))
                }
                .toggleStyle(SwitchToggleStyle(tint: .black))
                
                Spacer()
                
                Button(action: onEditAmount) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                        Text("Edit")
                            .font(.system(size: 14))
                    }
                    .foregroundColor(.black)
                }
                
                Button(action: {
                    transaction.includeInSplit = false
                }) {
                    Text("Mark Personal")
                        .font(.system(size: 14))
                        .foregroundColor(.black)
                }
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
    
    private func togglePerson(_ person: Person) {
        if let index = transaction.splitWith.firstIndex(where: { $0.id == person.id }) {
            transaction.splitWith.remove(at: index)
        } else {
            transaction.splitWith.append(person)
        }
    }
}
