import SwiftUI
import UIKit

struct TransactionCardView: View {
    @Binding var transaction: Transaction
    let allPeople: [Person]
    let onDelete: () -> Void
    let onEditAmount: () -> Void
    let onEditName: () -> Void
    let onImageTap: () -> Void
    let onBreakdown: (() -> Void)?
    let onAdvancedSplit: (() -> Void)?

    @State private var showSplitOptions = false
    @State private var showPaidByOptions = false

    @EnvironmentObject var tutorialManager: TutorialManager
    @Environment(\.colorScheme) var colorScheme

    var hasReceiptImage: Bool {
        transaction.receiptImage != nil
    }

    // MARK: - Advanced split detection

    /// True when the transaction has a custom weighted split stored
    private var hasCustomSplit: Bool {
        !transaction.splitQuantities.isEmpty &&
        transaction.splitQuantities.values.contains(where: { $0 > 1 })
    }

    /// Amount owed by a specific person given their quantity weight
    private func weightedAmount(for person: Person) -> Double {
        let quantities = transaction.splitWith.map { p in
            transaction.splitQuantities[p.id] ?? 1
        }
        let total = quantities.reduce(0, +)
        guard total > 0 else { return transaction.perPersonAmount }
        let myQty = transaction.splitQuantities[person.id] ?? 1
        return transaction.amount * (Double(myQty) / Double(total))
    }

    // MARK: - Select All / Deselect All helpers

    private var allPeopleSelected: Bool {
        allPeople.allSatisfy { person in
            transaction.splitWith.contains(where: { $0.id == person.id })
        }
    }

    private func selectAll() {
        withAnimation(.spring(response: 0.3)) {
            for person in allPeople {
                if !transaction.splitWith.contains(where: { $0.id == person.id }) {
                    transaction.splitWith.append(person)
                }
            }
            // Reset any custom split when selecting all equally
            transaction.splitQuantities = [:]
        }
        HapticManager.impact(style: .light)
    }

    private func deselectAll() {
        withAnimation(.spring(response: 0.3)) {
            transaction.splitWith = []
            transaction.splitQuantities = [:]
        }
        HapticManager.impact(style: .light)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            mainContent
            deleteSection
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .shadow(color: Color.primary.opacity(0.06), radius: 8, y: 2)
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerRow

            if hasReceiptImage {
                receiptButtons
            }

            paidBySection
            splitSection
        }
        .padding(20)
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(alignment: .top) {
            merchantInfo
            Spacer()
            amountSection
        }
    }

    private var merchantInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onEditName) {
                HStack(spacing: 6) {
                    Text(transaction.merchant)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)

                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var amountSection: some View {
        VStack(alignment: .trailing, spacing: 4) {
            amountButton

            if transaction.isManual {
                Text("Manual")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var amountButton: some View {
        Button(action: onEditAmount) {
            HStack(spacing: 4) {
                Text(transaction.formattedAmount)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.primary)

                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Receipt Buttons

    private var receiptButtons: some View {
        HStack(spacing: 12) {
            viewReceiptButton

            if onBreakdown != nil {
                breakdownButton
            }

            Spacer()
        }
    }

    private var viewReceiptButton: some View {
        Button {
            onImageTap()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "photo.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)

                Text("View Receipt")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.08))
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(Rectangle())
    }

    private var breakdownButton: some View {
        Button {
            onBreakdown?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                Text("Break Down")
                    .font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.08))
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Paid By Section

    private var paidBySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            paidByToggleButton

            if showPaidByOptions {
                paidByList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var paidByToggleButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3)) {
                showPaidByOptions.toggle()
            }
        }) {
            HStack {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)

                Text("Paid by \(transaction.paidBy.name)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))

                Spacer()

                Image(systemName: showPaidByOptions ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var paidByList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(allPeople) { person in
                PaidByRow(
                    person: person,
                    isSelected: transaction.paidBy.id == person.id,
                    onSelect: { selectPaidBy(person) }
                )
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Split Section

    private var splitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            splitToggleRow

            if showSplitOptions {
                splitPeopleContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Collapsed toggle row — shows split summary + Advanced button always visible
    private var splitToggleRow: some View {
        HStack(spacing: 8) {
            // Left: expand/collapse the person list
            Button(action: {
                withAnimation(.spring(response: 0.3)) {
                    showSplitOptions.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Split with \(transaction.splitWith.count) \(transaction.splitWith.count == 1 ? "person" : "people")")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary.opacity(0.8))

                        // Custom split badge — visible in collapsed state
                        if hasCustomSplit {
                            Text("Custom weights applied")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }
                    }

                    Spacer()

                    Image(systemName: showSplitOptions ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(PlainButtonStyle())

            // Right: Advanced Split button — always visible so users can find it
            if let advancedSplit = onAdvancedSplit {
                Button(action: advancedSplit) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Advanced")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(hasCustomSplit ? .white : .accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hasCustomSplit ? Color.accentColor : Color.accentColor.opacity(0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    /// Expanded people list with Select All / Deselect All at top
    private var splitPeopleContent: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Select All / Deselect All
            HStack {
                Button(action: {
                    if allPeopleSelected { deselectAll() } else { selectAll() }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: allPeopleSelected
                              ? "person.crop.circle.badge.minus"
                              : "person.crop.circle.badge.checkmark")
                            .font(.system(size: 13))
                        Text(allPeopleSelected ? "Deselect All" : "Select All")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(allPeopleSelected ? .red.opacity(0.85) : .accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        (allPeopleSelected ? Color.red : Color.accentColor).opacity(0.09)
                    )
                    .cornerRadius(8)
                }

                Spacer()

                // Clear custom split shortcut
                if hasCustomSplit {
                    Button(action: {
                        withAnimation(.spring(response: 0.3)) {
                            transaction.splitQuantities = [:]
                        }
                    }) {
                        Text("Reset to Equal")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.bottom, 2)

            // Individual person rows — show weighted amounts when custom split is active
            VStack(alignment: .leading, spacing: 8) {
                ForEach(allPeople) { person in
                    PersonRow(
                        person: person,
                        isIncluded: isPersonIncluded(person),
                        // Show weighted amount if custom split, otherwise equal split
                        perPersonAmount: hasCustomSplit && isPersonIncluded(person)
                            ? weightedAmount(for: person)
                            : transaction.perPersonAmount,
                        customWeight: hasCustomSplit
                            ? (transaction.splitQuantities[person.id] ?? 1)
                            : nil,
                        onToggle: { togglePersonInSplit(person) }
                    )
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Delete Section

    private var deleteSection: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(height: 1)

            Button(action: onDelete) {
                HStack {
                    Image(systemName: "trash")
                        .font(.system(size: 14))

                    Text("Remove Transaction")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(.red.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
        }
    }

    // MARK: - Helper Methods

    private func selectPaidBy(_ person: Person) {
        withAnimation(.spring(response: 0.3)) {
            transaction.paidBy = person
            showPaidByOptions = false
        }
    }

    private func isPersonIncluded(_ person: Person) -> Bool {
        transaction.splitWith.contains(where: { $0.id == person.id })
    }

    private func togglePersonInSplit(_ person: Person) {
        withAnimation(.spring(response: 0.3)) {
            if let index = transaction.splitWith.firstIndex(where: { $0.id == person.id }) {
                transaction.splitWith.remove(at: index)
                transaction.splitQuantities.removeValue(forKey: person.id)
            } else {
                transaction.splitWith.append(person)
            }
        }
    }
}

// MARK: - Paid By Row Component

struct PaidByRow: View {
    let person: Person
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                selectionIcon

                AvatarView(
                    imageData: person.contactImage,
                    initials: person.initials,
                    size: 32
                )

                Text(person.name)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(.primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(isSelected ? Color.primary.opacity(0.08) : Color.clear)
            .cornerRadius(8)
        }
    }

    private var selectionIcon: some View {
        Circle()
            .fill(isSelected ? Color.primary : Color.clear)
            .frame(width: 20, height: 20)
            .overlay(
                Circle()
                    .stroke(Color.primary.opacity(isSelected ? 1.0 : 0.4), lineWidth: 2)
            )
            .overlay(
                Circle()
                    .fill(colorScheme == .dark ? Color.black : Color.white)
                    .frame(width: 8, height: 8)
                    .opacity(isSelected ? 1.0 : 0)
            )
    }
}

// MARK: - Person Row Component

struct PersonRow: View {
    let person: Person
    let isIncluded: Bool
    let perPersonAmount: Double
    /// Non-nil when a custom weighted split is active — shows the multiplier badge
    let customWeight: Int?
    let onToggle: () -> Void
    @Environment(\.colorScheme) var colorScheme

    // Convenience init to keep existing call sites without customWeight working
    init(
        person: Person,
        isIncluded: Bool,
        perPersonAmount: Double,
        customWeight: Int? = nil,
        onToggle: @escaping () -> Void
    ) {
        self.person = person
        self.isIncluded = isIncluded
        self.perPersonAmount = perPersonAmount
        self.customWeight = customWeight
        self.onToggle = onToggle
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                checkmarkIcon

                AvatarView(
                    imageData: person.contactImage,
                    initials: person.initials,
                    size: 32
                )

                Text(person.name)
                    .font(.system(size: 15))
                    .foregroundColor(.primary)

                // Weight badge, e.g. "2×"
                if let weight = customWeight, isIncluded, weight > 1 {
                    Text("\(weight)×")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .cornerRadius(5)
                }

                Spacer()

                if isIncluded {
                    amountText
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(isIncluded ? Color.primary.opacity(0.05) : Color.clear)
            .cornerRadius(8)
        }
    }

    private var checkmarkIcon: some View {
        Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .foregroundColor(isIncluded ? .primary : .secondary)
    }

    private var amountText: some View {
        Text(String(format: "$%.2f", perPersonAmount))
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.secondary)
    }
}
