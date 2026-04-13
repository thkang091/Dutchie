import SwiftUI
import PhotosUI

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedPhoto: PhotosPickerItem?
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Avatar
                    HStack {
                        Spacer()
                        
                        VStack(spacing: 12) {
                            AvatarView(
                                imageData: appState.profile.avatarImage,
                                initials: appState.profile.initials,
                                size: 80
                            )
                            
                            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                Text("Change Photo")
                                    .font(.system(size: 14))
                                    .foregroundColor(.black)
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(.top, 20)
                    
                    // Section 1 - Identity
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Identity")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.black)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Name")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.gray)
                            
                            TextField("Your name", text: $appState.profile.name)
                                .font(.system(size: 16))
                                .padding(12)
                                .background(Color.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.black, lineWidth: 1)
                                )
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Phone Number")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.gray)
                            
                            TextField("Phone number", text: $appState.profile.phoneNumber)
                                .font(.system(size: 16))
                                .keyboardType(.phonePad)
                                .padding(12)
                                .background(Color.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.black, lineWidth: 1)
                                )
                        }
                    }
                    
                    // Section 2 - Payment Links
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Payment Links")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.black)
                        
                        ForEach($appState.profile.paymentMethods) { $method in
                            PaymentCardView(paymentMethod: $method)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGray6))
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.black)
                }
            }
        }
        .onChange(of: selectedPhoto) { _, newValue in
            Task {
                if let data = try? await newValue?.loadTransferable(type: Data.self) {
                    appState.profile.avatarImage = data
                }
            }
        }
    }
}
