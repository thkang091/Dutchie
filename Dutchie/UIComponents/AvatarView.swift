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
        Group {
            if let imageData = imageData,
               let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle()
                        .fill(Color.black)
                    
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
