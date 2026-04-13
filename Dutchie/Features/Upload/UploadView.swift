import SwiftUI
import PhotosUI

struct UploadView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showManualEntry = false
    @State private var manualItemName = ""
    @State private var manualItemAmount = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with profile avatar
            HStack {
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
                .padding(.trailing, 20)
                .padding(.top, 20)
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Section A: Add Photos
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Add Photos")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.black)
                        
                        HStack(spacing: 12) {
                            PhotosPicker(
                                selection: $selectedPhotos,
                                maxSelectionCount: 10,
                                matching: .images
                            ) {
                                VStack(spacing: 8) {
                                    Image(systemName: "doc.text.viewfinder")
                                        .font(.system(size: 32))
                                        .foregroundColor(.black)
                                    
                                    Text("Receipt")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.black)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                                .background(Color.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.black, lineWidth: 1)
                                )
                            }
                            
                            Button(action: {
                                // Bank account integration placeholder
                            }) {
                                VStack(spacing: 8) {
                                    Image(systemName: "building.columns")
                                        .font(.system(size: 32))
                                        .foregroundColor(.black)
                                    
                                    Text("Bank Account")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.black)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                                .background(Color.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.black, lineWidth: 1)
                                )
                            }
                        }
                        
                        // Thumbnails
                        if !appState.uploadedImages.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
                                ForEach(Array(appState.uploadedImages.enumerated()), id: \.offset) { index, image in
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 80, height: 80)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(Color.black, lineWidth: 1)
                                            )
                                        
                                        Button(action: {
                                            appState.uploadedImages.remove(at: index)
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.black)
                                                .background(Color.white.clipShape(Circle()))
                                        }
                                        .offset(x: 8, y: -8)
                                    }
                                }
                            }
                        }
                    }
                    
                    Divider()
                        .background(Color.black)
                    
                    // Section B: Manual Upload
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Manual Entry")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.black)
                            
                            Spacer()
                            
                            Button(action: {
                                showManualEntry.toggle()
                            }) {
                                Image(systemName: showManualEntry ? "chevron.up" : "chevron.down")
                                    .foregroundColor(.black)
                            }
                        }
                        
                        if showManualEntry {
                            VStack(spacing: 12) {
                                ForEach(Array(appState.manualTransactions.enumerated()), id: \.offset) { index, item in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.name)
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundColor(.black)
                                            
                                            Text(String(format: "$%.2f", item.amount))
                                                .font(.system(size: 12))
                                                .foregroundColor(.gray)
                                        }
                                        
                                        Spacer()
                                        
                                        Button(action: {
                                            appState.manualTransactions.remove(at: index)
                                        }) {
                                            Image(systemName: "xmark.circle")
                                                .foregroundColor(.black)
                                        }
                                    }
                                    .padding(12)
                                    .background(Color.white)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.black, lineWidth: 1)
                                    )
                                }
                                
                                // Add new manual item
                                VStack(spacing: 8) {
                                    TextField("Item name", text: $manualItemName)
                                        .font(.system(size: 14))
                                        .padding(12)
                                        .background(Color.white)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.black, lineWidth: 1)
                                        )
                                    
                                    HStack {
                                        TextField("Amount", text: $manualItemAmount)
                                            .font(.system(size: 14))
                                            .keyboardType(.decimalPad)
                                            .padding(12)
                                            .background(Color.white)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(Color.black, lineWidth: 1)
                                            )
                                        
                                        Button(action: addManualItem) {
                                            Text("Add")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 20)
                                                .padding(.vertical, 12)
                                                .background(Color.black)
                                                .cornerRadius(8)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGray6))
            
            // Bottom CTA
            Button(action: {
                router.navigateToPeople()
            }) {
                Text("Next")
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
        .onChange(of: selectedPhotos) { _, newPhotos in
            Task {
                for photo in newPhotos {
                    if let data = try? await photo.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        appState.uploadedImages.append(image)
                    }
                }
                selectedPhotos = []
            }
        }
    }
    
    private func addManualItem() {
        guard !manualItemName.isEmpty,
              let amount = Double(manualItemAmount),
              amount > 0 else {
            return
        }
        
        appState.manualTransactions.append((name: manualItemName, amount: amount))
        manualItemName = ""
        manualItemAmount = ""
    }
}
