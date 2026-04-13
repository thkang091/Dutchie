import SwiftUI

struct ChipView: View {
    let person: Person
    let showRemoveButton: Bool
    let isSelected: Bool
    let onRemove: (() -> Void)?
    let onTap: (() -> Void)?
    
    init(
        person: Person,
        showRemoveButton: Bool = true,
        isSelected: Bool = true,
        onRemove: (() -> Void)? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.person = person
        self.showRemoveButton = showRemoveButton
        self.isSelected = isSelected
        self.onRemove = onRemove
        self.onTap = onTap
    }
    
    var body: some View {
        HStack(spacing: 8) {
            AvatarView(
                imageData: person.contactImage,
                initials: person.initials,
                size: 24
            )
            
            Text(person.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isSelected ? .black : .gray)
            
            if showRemoveButton {
                Button(action: {
                    onRemove?()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 16, height: 16)
                        .background(Color.white)
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(isSelected ? Color.white : Color.gray.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.black, lineWidth: 1)
                )
        )
        .onTapGesture {
            onTap?()
        }
    }
}
