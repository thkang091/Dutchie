import SwiftUI

struct AvatarView: View {
    let imageData: Data?
    let initials: String
    let size: CGFloat
    
    init(imageData: Data? = nil, initials: String, size: CGFloat = 40) {
        self.imageData = imageData
        self.initials = initials
        self.size = size
    }
    
    var body: some View {
        ZStack {
            if let imageData = imageData,
               let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.black)
                    .frame(width: size, height: size)
                    .overlay(
                        Text(initials)
                            .font(.system(size: size * 0.4, weight: .medium))
                            .foregroundColor(.white)
                    )
            }
        }
    }
}
