import SwiftUI
import Contacts
import ContactsUI

// MARK: - Persistence Manager

class PeopleStorageManager {
    static let shared = PeopleStorageManager()

    private let recentPeopleKey = "recentPeople_v1"
    private let savedGroupsKey  = "savedGroups_v1"

    private init() {}

    func loadRecentPeople() -> [RecentPerson] {
        guard let data = UserDefaults.standard.data(forKey: recentPeopleKey),
              let decoded = try? JSONDecoder().decode([RecentPerson].self, from: data) else { return [] }
        return decoded
    }

    func addRecentPerson(_ person: RecentPerson) {
        var recent = loadRecentPeople()
        recent.removeAll { $0.name == person.name }
        recent.insert(person, at: 0)
        recent = Array(recent.prefix(5))
        if let encoded = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(encoded, forKey: recentPeopleKey)
        }
    }

    func loadSavedGroups() -> [PersistedGroup] {
        guard let data = UserDefaults.standard.data(forKey: savedGroupsKey),
              let decoded = try? JSONDecoder().decode([PersistedGroup].self, from: data) else { return [] }
        return decoded
    }

    func saveGroup(_ group: PersistedGroup) {
        var groups = loadSavedGroups()
        groups.removeAll { $0.id == group.id }
        groups.insert(group, at: 0)
        if let encoded = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(encoded, forKey: savedGroupsKey)
        }
    }

    func deleteGroup(id: String) {
        var groups = loadSavedGroups()
        groups.removeAll { $0.id == id }
        if let encoded = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(encoded, forKey: savedGroupsKey)
        }
    }

    func updateGroupLastUsed(id: String) {
        var groups = loadSavedGroups()
        if let index = groups.firstIndex(where: { $0.id == id }) {
            groups[index].lastUsed = Date()
            if let encoded = try? JSONEncoder().encode(groups) {
                UserDefaults.standard.set(encoded, forKey: savedGroupsKey)
            }
        }
    }
}

// MARK: - Models

struct RecentPerson: Codable, Identifiable {
    var id: String { name }
    let name: String
    let phoneNumber: String?
    let imageData: Data?
    var lastUsed: Date

    init(name: String, phoneNumber: String? = nil, imageData: Data? = nil) {
        self.name        = name
        self.phoneNumber = phoneNumber
        self.imageData   = imageData
        self.lastUsed    = Date()
    }
}

struct PersistedGroupMember: Codable, Identifiable {
    var id: String { name }
    let name: String
    let phoneNumber: String?
    let imageData: Data?
}

struct PersistedGroup: Codable, Identifiable {
    let id: String
    var name: String
    var members: [PersistedGroupMember]
    var lastUsed: Date

    init(id: String = UUID().uuidString, name: String, members: [PersistedGroupMember]) {
        self.id       = id
        self.name     = name
        self.members  = members
        self.lastUsed = Date()
    }

    var memberNames: [String] { members.map(\.name) }
}

// MARK: - Inline Group Row with chip selection

struct GroupRow: View {
    let group: PersistedGroup
    let onConfirm: (Set<String>) -> Void
    let onDelete: () -> Void

    @State private var isExpanded: Bool = false
    @State private var selected: Set<String>
    @State private var swipeOffset: CGFloat = 0
    @State private var showingDeleteConfirm = false

    // How far the row slides to reveal the delete button
    private let deleteButtonWidth: CGFloat = 80

    init(group: PersistedGroup, onConfirm: @escaping (Set<String>) -> Void, onDelete: @escaping () -> Void) {
        self.group     = group
        self.onConfirm = onConfirm
        self.onDelete  = onDelete
        _selected      = State(initialValue: Set(group.members.map(\.name)))
    }

    private var allSelected: Bool { selected.count == group.members.count }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Delete button revealed on swipe (only shown when collapsed)
            if !isExpanded {
                deleteRevealButton
            }

            // Main card
            mainCard
                .offset(x: isExpanded ? 0 : swipeOffset)
                .gesture(
                    isExpanded ? nil : DragGesture(minimumDistance: 15, coordinateSpace: .local)
                        .onChanged { value in
                            // Only allow left swipe
                            if value.translation.width < 0 {
                                swipeOffset = max(value.translation.width, -deleteButtonWidth)
                            } else if swipeOffset < 0 {
                                swipeOffset = min(0, swipeOffset + value.translation.width)
                            }
                        }
                        .onEnded { value in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                if value.translation.width < -(deleteButtonWidth * 0.5) {
                                    swipeOffset = -deleteButtonWidth
                                } else {
                                    swipeOffset = 0
                                }
                            }
                        }
                )
        }
        .clipped()
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isExpanded ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.08),
                    lineWidth: isExpanded ? 1.5 : 1
                )
        )
        .shadow(color: Color.primary.opacity(0.05), radius: 8, y: 3)
        .alert("Remove Group", isPresented: $showingDeleteConfirm) {
            Button("Remove", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove \"\(group.name)\" from your quick groups?")
        }
        // Reset swipe when something else taps
        .onChange(of: isExpanded) { expanded in
            if expanded {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    swipeOffset = 0
                }
            }
        }
    }

    // MARK: - Delete reveal button (swipe target)

    private var deleteRevealButton: some View {
        Button(action: {
            HapticManager.notification(type: .warning)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                swipeOffset = 0
            }
            showingDeleteConfirm = true
        }) {
            VStack(spacing: 6) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 18, weight: .semibold))
                Text("Delete")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(width: deleteButtonWidth)
            .frame(maxHeight: .infinity)
            .background(Color.red)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Main card content

    private var mainCard: some View {
        VStack(spacing: 0) {
            // Header row — tap to expand/collapse
            Button(action: {
                HapticManager.impact(style: .light)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                    if isExpanded {
                        selected = Set(group.members.map(\.name))
                    }
                }
            }) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 46, height: 46)

                        Image(systemName: "person.3.fill")
                            .font(.system(size: 17))
                            .foregroundColor(.primary.opacity(0.6))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)

                        Text("\(group.members.count) people")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Stacked avatar preview (up to 3)
                    avatarStack

                    if !isExpanded {
                        // Swipe hint label when collapsed
                        Text("Swipe to delete")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.6))
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.99))
            // Tapping the header resets any open swipe
            .simultaneousGesture(
                TapGesture().onEnded {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        swipeOffset = 0
                    }
                }
            )

            // Expanded chip area
            if isExpanded {
                VStack(spacing: 14) {
                    Divider()
                        .padding(.horizontal, 14)

                    // Select all / deselect all row
                    HStack {
                        Text("\(selected.count) of \(group.members.count) selected")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)

                        Spacer()

                        Button(action: {
                            HapticManager.impact(style: .light)
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                if allSelected {
                                    selected.removeAll()
                                } else {
                                    selected = Set(group.members.map(\.name))
                                }
                            }
                        }) {
                            Text(allSelected ? "Deselect All" : "Select All")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal, 14)

                    // Chips
                    chipGrid

                    // Action row: Delete Group + Add People
                    HStack(spacing: 10) {
                        // Prominent Delete Group button
                        Button(action: {
                            HapticManager.notification(type: .warning)
                            showingDeleteConfirm = true
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Delete Group")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.red.opacity(0.25), lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(ScaleButtonStyle(scale: 0.96))

                        // Confirm / Add button
                        Button(action: {
                            guard !selected.isEmpty else { return }
                            HapticManager.impact(style: .medium)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                isExpanded = false
                            }
                            onConfirm(selected)
                        }) {
                            HStack(spacing: 6) {
                                Text(
                                    selected.isEmpty
                                        ? "Select someone"
                                        : "Add \(selected.count)"
                                )
                                .font(.system(size: 14, weight: .semibold))

                                if !selected.isEmpty {
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 12, weight: .bold))
                                }
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(selected.isEmpty ? Color.primary.opacity(0.25) : Color.accentColor)
                            .cornerRadius(12)
                            .shadow(
                                color: selected.isEmpty ? Color.clear : Color.accentColor.opacity(0.3),
                                radius: 8, y: 3
                            )
                        }
                        .disabled(selected.isEmpty)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    // Small stacked avatars shown in collapsed state
    private var avatarStack: some View {
        let preview = Array(group.members.prefix(3))
        return HStack(spacing: -8) {
            ForEach(Array(preview.enumerated()), id: \.element.id) { index, member in
                AvatarView(
                    imageData: member.imageData,
                    initials: String(member.name.prefix(2).uppercased()),
                    size: 28
                )
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                .zIndex(Double(preview.count - index))
            }
        }
    }

    // Scrollable chip row
    private var chipGrid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(group.members) { member in
                    memberChip(member: member)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private func memberChip(member: PersistedGroupMember) -> some View {
        let isSelected = selected.contains(member.name)
        let firstName  = member.name.components(separatedBy: " ").first ?? member.name

        return Button(action: {
            HapticManager.impact(style: .light)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                if isSelected {
                    selected.remove(member.name)
                } else {
                    selected.insert(member.name)
                }
            }
        }) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    AvatarView(
                        imageData: member.imageData,
                        initials: String(member.name.prefix(2).uppercased()),
                        size: 52
                    )
                    .overlay(
                        Circle()
                            .stroke(
                                isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                                lineWidth: isSelected ? 2.5 : 1.5
                            )
                    )

                    // Checkmark badge
                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.accentColor : Color(.systemBackground))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))

                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .offset(x: 2, y: -2)
                }

                Text(firstName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .opacity(isSelected ? 1.0 : 0.55)
            .scaleEffect(isSelected ? 1.0 : 0.95)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.93))
    }
}

// MARK: - Main View

struct PeopleView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    @EnvironmentObject var tutorialManager: TutorialManager
    @Environment(\.colorScheme) var colorScheme

    @State private var newPersonName           = ""
    @State private var showContactPicker       = false
    @State private var showSaveGroupDialog     = false
    @State private var groupName               = ""
    @State private var recentPeople: [RecentPerson]  = []
    @State private var savedGroups: [PersistedGroup] = []
    @State private var showDeleteGroupAlert    = false
    @State private var groupToDelete: PersistedGroup?
    @State private var recentPeopleExpanded    = false
    @State private var savedGroupsExpanded     = false

    private let storage = PeopleStorageManager.shared

    private var shouldHighlightContactButton: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .peopleAddContact
    }
    private var shouldHighlightPeopleList: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .peopleList
    }
    private var shouldHighlightContinue: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .continueButton
    }

    var addedPeopleCount: Int {
        appState.people.filter { !$0.isCurrentUser }.count
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                headerSection

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 24) {
                        if addedPeopleCount > 0 {
                            summaryCard
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.9).combined(with: .opacity),
                                    removal: .scale(scale: 0.9).combined(with: .opacity)
                                ))
                        }

                        addPeopleSection

                        if addedPeopleCount > 0 {
                            peopleListSection
                        }

                        if !recentPeople.isEmpty {
                            recentPeopleSection
                        }

                        if !savedGroups.isEmpty {
                            savedGroupsSection
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 120)
                }
                .disabled(tutorialManager.isActive)

                bottomCTA
            }

            if tutorialManager.isActive {
                TutorialOverlay(context: .people).zIndex(200)
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            appState.ensureCurrentUser()
            clearSessionPeople()
            loadPersistedData()
            if tutorialManager.isActive && !tutorialManager.isCurrentStep(in: .people) {
                withAnimation { tutorialManager.currentStepIndex = 3 }
            }
        }
        .alert("Save Group", isPresented: $showSaveGroupDialog) {
            TextField("Group name (e.g., Weekend Crew)", text: $groupName)
            Button("Save") {
                if !groupName.isEmpty {
                    saveCurrentGroup()
                    groupName = ""
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save this group for quick access later")
        }
        .alert("Remove Group", isPresented: $showDeleteGroupAlert) {
            Button("Remove", role: .destructive) {
                if let group = groupToDelete {
                    withAnimation {
                        storage.deleteGroup(id: group.id)
                        savedGroups = storage.loadSavedGroups()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This group will be removed from your quick groups list.")
        }
    }

    // MARK: - Session & Persistence

    private func clearSessionPeople() {
        guard !tutorialManager.isActive else { return }
        let currentUser = appState.people.first(where: { $0.isCurrentUser })
        appState.people = [currentUser].compactMap { $0 }
    }

    private func loadPersistedData() {
        recentPeople = storage.loadRecentPeople()
        savedGroups  = storage.loadSavedGroups()
    }

    private func saveCurrentGroup() {
        let nonUserPeople = appState.people.filter { !$0.isCurrentUser }
        guard !nonUserPeople.isEmpty else { return }
        let members = nonUserPeople.map {
            PersistedGroupMember(name: $0.name, phoneNumber: $0.phoneNumber, imageData: $0.contactImage)
        }
        let group = PersistedGroup(name: groupName, members: members)
        storage.saveGroup(group)
        savedGroups = storage.loadSavedGroups()
        appState.saveGroup(name: groupName)
    }

    private func recordRecentPeople(from people: [Person]) {
        for person in people where !person.isCurrentUser {
            storage.addRecentPerson(RecentPerson(name: person.name, phoneNumber: person.phoneNumber, imageData: person.contactImage))
        }
        recentPeople = storage.loadRecentPeople()
    }

    private func applySelectedMembers(_ selectedNames: Set<String>, from group: PersistedGroup) {
        let currentUser = appState.people.first(where: { $0.isCurrentUser })
        let toAdd = group.members
            .filter { selectedNames.contains($0.name) }
            .map { m -> Person in
                let img = m.imageData ?? recentPeople.first(where: { $0.name == m.name })?.imageData
                return Person(name: m.name, contactImage: img, phoneNumber: m.phoneNumber)
            }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            appState.people = [currentUser].compactMap { $0 } + toAdd.filter { !$0.isCurrentUser }
        }
        storage.updateGroupLastUsed(id: group.id)
        savedGroups = storage.loadSavedGroups()
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button(action: {
                    HapticManager.impact(style: .light)
                    router.navigateBack()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 40, height: 40)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .shadow(color: Color.primary.opacity(0.05), radius: 4, y: 2)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(tutorialManager.isActive)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Who's Splitting?")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.primary)
                    Text("Add people to split with")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    HapticManager.impact(style: .light)
                    router.showProfile = true
                }) {
                    AvatarView(
                        imageData: appState.profile.avatarImage,
                        initials: appState.profile.initials,
                        size: 44
                    )
                    .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 2))
                    .shadow(color: Color.primary.opacity(0.1), radius: 8, y: 4)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(tutorialManager.isActive)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .background(Color(.systemBackground))

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 64, height: 64)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.primary.opacity(0.6))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("People Splitting")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Text("\(appState.people.count)")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.primary)
                    Text("people")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.top, 10)
                }
            }

            Spacer()
        }
        .padding(24)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(20)
        .shadow(color: Color.primary.opacity(0.06), radius: 12, y: 4)
    }

    // MARK: - Add People Section

    private var addPeopleSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Add People", icon: "person.badge.plus")
            VStack(spacing: 12) {
                currentUserRow
                addPersonInput
                contactPickerButton
            }
        }
    }

    private var currentUserRow: some View {
        HStack(spacing: 14) {
            AvatarView(
                imageData: appState.profile.avatarImage,
                initials: appState.profile.initials,
                size: 48
            )
            .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 2))

            VStack(alignment: .leading, spacing: 4) {
                Text(appState.profile.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                Text("You")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                Text("Added").font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.green)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.1))
            .cornerRadius(12)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: Color.primary.opacity(0.03), radius: 4, y: 2)
    }

    private var addPersonInput: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "person.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)

                TextField("Enter name", text: $newPersonName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                    .submitLabel(.done)
                    .disabled(tutorialManager.isActive)
                    .onSubmit { if !newPersonName.isEmpty { addPerson() } }
            }
            .padding(16)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        newPersonName.isEmpty ? Color.primary.opacity(0.1) : Color.primary.opacity(0.2),
                        lineWidth: newPersonName.isEmpty ? 1 : 2
                    )
            )

            Button(action: {
                HapticManager.impact(style: .medium)
                addPerson()
            }) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(newPersonName.isEmpty ? .secondary : .white)
                    .frame(width: 56, height: 56)
                    .background(newPersonName.isEmpty ? Color.primary.opacity(0.08) : Color.accentColor)
                    .cornerRadius(14)
                    .shadow(color: newPersonName.isEmpty ? Color.clear : Color.accentColor.opacity(0.3), radius: 8, y: 4)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.92))
            .disabled(newPersonName.isEmpty || tutorialManager.isActive)
        }
    }

    private var contactPickerButton: some View {
        Button(action: {
            HapticManager.impact(style: .light)
            showContactPicker = true
        }) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: 40, height: 40)
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 18))
                        .foregroundColor(.primary.opacity(0.7))
                }

                Text("Add from Contacts")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1), lineWidth: 1.5))
            .shadow(color: Color.primary.opacity(0.03), radius: 4, y: 2)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
        .tutorialSpotlight(isHighlighted: shouldHighlightContactButton, cornerRadius: 14)
        .disabled(tutorialManager.isActive)
        .sheet(isPresented: $showContactPicker) {
            SearchableContactPickerView { contacts in
                var newlyAdded: [Person] = []
                for contact in contacts {
                    let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                    if !fullName.isEmpty && !appState.people.contains(where: { $0.name == fullName }) {
                        let phone  = contact.phoneNumbers.first?.value.stringValue
                        let person = Person(name: fullName, contactImage: contact.imageData, phoneNumber: phone)
                        appState.addPerson(person)
                        newlyAdded.append(person)
                    }
                }
                recordRecentPeople(from: newlyAdded)
            }
        }
    }

    // MARK: - Recent People Section (collapsible)

    private var recentPeopleSection: some View {
        VStack(spacing: 0) {
            Button(action: {
                HapticManager.impact(style: .light)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    recentPeopleExpanded.toggle()
                }
            }) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 46, height: 46)
                        Image(systemName: "clock.fill")
                            .font(.system(size: 17))
                            .foregroundColor(.primary.opacity(0.6))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recent People")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("\(recentPeople.count) people")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    HStack(spacing: -8) {
                        ForEach(Array(recentPeople.prefix(3).enumerated()), id: \.element.id) { index, person in
                            AvatarView(
                                imageData: person.imageData,
                                initials: String(person.name.prefix(2).uppercased()),
                                size: 28
                            )
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            .zIndex(Double(3 - index))
                        }
                    }

                    Image(systemName: recentPeopleExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.99))
            .disabled(tutorialManager.isActive)

            if recentPeopleExpanded {
                VStack(spacing: 0) {
                    Divider().padding(.horizontal, 14)

                    VStack(spacing: 8) {
                        ForEach(recentPeople) { person in
                            let alreadyAdded = appState.people.contains(where: { $0.name == person.name })
                            recentPersonRow(person: person, alreadyAdded: alreadyAdded)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    recentPeopleExpanded ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.08),
                    lineWidth: recentPeopleExpanded ? 1.5 : 1
                )
        )
        .shadow(color: Color.primary.opacity(0.05), radius: 8, y: 3)
    }

    private func recentPersonRow(person: RecentPerson, alreadyAdded: Bool) -> some View {
        HStack(spacing: 12) {
            AvatarView(
                imageData: person.imageData,
                initials: String(person.name.prefix(2).uppercased()),
                size: 40
            )
            .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)

                if let phone = person.phoneNumber, !phone.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "phone.fill").font(.system(size: 10))
                        Text(phone).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
            }

            Spacer()

            if alreadyAdded {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                    Text("Added").font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.1))
                .cornerRadius(10)
            } else {
                Button(action: {
                    HapticManager.impact(style: .medium)
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        let newPerson = Person(name: person.name, contactImage: person.imageData, phoneNumber: person.phoneNumber)
                        appState.addPerson(newPerson)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                        Text("Add").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .cornerRadius(10)
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.94))
                .disabled(tutorialManager.isActive)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Added People Section

    private var peopleListSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Added People", icon: "person.2.fill")

            VStack(spacing: 10) {
                ForEach(appState.people.filter { !$0.isCurrentUser }) { person in
                    personRow(person: person)
                }
            }
        }
        .tutorialSpotlight(isHighlighted: shouldHighlightPeopleList, cornerRadius: 16)
    }

    private func personRow(person: Person) -> some View {
        HStack(spacing: 14) {
            AvatarView(
                imageData: person.contactImage,
                initials: person.initials,
                size: 48
            )
            .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 2))

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)

                if let phone = person.phoneNumber, !phone.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "phone.fill").font(.system(size: 10))
                        Text("From contacts").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: {
                HapticManager.notification(type: .warning)
                withAnimation(.spring(response: 0.3)) { appState.removePerson(person) }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.9))
            .disabled(tutorialManager.isActive)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .shadow(color: Color.primary.opacity(0.04), radius: 6, y: 3)
    }

    // MARK: - Saved Groups Section (collapsible card)

    private var savedGroupsSection: some View {
        VStack(spacing: 0) {
            Button(action: {
                HapticManager.impact(style: .light)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    savedGroupsExpanded.toggle()
                }
            }) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 46, height: 46)
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 17))
                            .foregroundColor(.primary.opacity(0.6))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Quick Groups")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("\(savedGroups.count) \(savedGroups.count == 1 ? "group" : "groups") saved")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if let firstGroup = savedGroups.first {
                        HStack(spacing: -8) {
                            ForEach(Array(firstGroup.members.prefix(3).enumerated()), id: \.element.id) { index, member in
                                AvatarView(
                                    imageData: member.imageData,
                                    initials: String(member.name.prefix(2).uppercased()),
                                    size: 28
                                )
                                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                                .zIndex(Double(3 - index))
                            }
                        }
                    }

                    Image(systemName: savedGroupsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.99))
            .disabled(tutorialManager.isActive)

            if savedGroupsExpanded {
                VStack(spacing: 0) {
                    Divider().padding(.horizontal, 14)

                    // Swipe hint banner
                    HStack(spacing: 6) {
                        Image(systemName: "hand.point.left.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("Swipe left on a group to delete it")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    VStack(spacing: 10) {
                        ForEach(savedGroups.prefix(5)) { group in
                            GroupRow(
                                group: group,
                                onConfirm: { selectedNames in
                                    applySelectedMembers(selectedNames, from: group)
                                },
                                onDelete: {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                        storage.deleteGroup(id: group.id)
                                        savedGroups = storage.loadSavedGroups()
                                    }
                                }
                            )
                            .disabled(tutorialManager.isActive)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 14)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    savedGroupsExpanded ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.08),
                    lineWidth: savedGroupsExpanded ? 1.5 : 1
                )
        )
        .shadow(color: Color.primary.opacity(0.05), radius: 8, y: 3)
    }

    // MARK: - Bottom CTA

    private var bottomCTA: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)

            VStack(spacing: 12) {
                if addedPeopleCount > 0 {
                    Button(action: {
                        HapticManager.impact(style: .light)
                        showSaveGroupDialog = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "star.fill").font(.system(size: 13))
                            Text("Save as Quick Group").font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.primary.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.primary.opacity(0.15), lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .disabled(tutorialManager.isActive)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.9).combined(with: .opacity),
                        removal: .scale(scale: 0.9).combined(with: .opacity)
                    ))
                }

                Button(action: {
                    HapticManager.impact(style: .medium)
                    recordRecentPeople(from: appState.people.filter { !$0.isCurrentUser })
                    router.navigateToProcessing()
                }) {
                    HStack(spacing: 8) {
                        Text("Continue").font(.system(size: 17, weight: .semibold))
                        Image(systemName: "arrow.right").font(.system(size: 14, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(appState.people.count > 1 ? Color.accentColor : Color.primary.opacity(0.3))
                    .cornerRadius(16)
                    .shadow(
                        color: appState.people.count > 1 ? Color.accentColor.opacity(0.3) : Color.clear,
                        radius: 12, y: 4
                    )
                }
                .buttonStyle(ScaleButtonStyle())
                .tutorialSpotlight(isHighlighted: shouldHighlightContinue, cornerRadius: 16)
                .disabled(appState.people.count < 2 || tutorialManager.isActive)
                .id(appState.people.count)
            }
            .padding(20)
            .background(
                Color(.systemBackground)
                    .shadow(color: Color.primary.opacity(0.05), radius: 20, y: -5)
            )
        }
    }

    // MARK: - Helpers

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.primary)
        }
        .padding(.leading, 2)
    }

    private func addPerson() {
        guard !newPersonName.isEmpty else { return }
        let person = Person(name: newPersonName)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            appState.addPerson(person)
            storage.addRecentPerson(RecentPerson(name: newPersonName))
            recentPeople  = storage.loadRecentPeople()
            newPersonName = ""
        }
    }
}

// MARK: - Searchable Contact Picker

struct SearchableContactPickerView: View {
    let onContactsSelected: ([CNContact]) -> Void

    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State private var searchText               = ""
    @State private var allContacts: [CNContact] = []
    @State private var selectedContacts: Set<String> = []
    @State private var isLoading                = true

    var filteredContacts: [CNContact] {
        if searchText.isEmpty { return allContacts }
        return allContacts.filter {
            "\($0.givenName) \($0.familyName)".lowercased().contains(searchText.lowercased())
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    searchBar
                    if isLoading        { loadingView   }
                    else if allContacts.isEmpty { emptyStateView }
                    else                { contactsList  }
                }
            }
            .navigationTitle("Add from Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(.primary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        onContactsSelected(allContacts.filter { selectedContacts.contains($0.identifier) })
                        dismiss()
                    }
                    .foregroundColor(.accentColor)
                    .fontWeight(.semibold)
                    .disabled(selectedContacts.isEmpty)
                }
            }
        }
        .onAppear { loadContacts() }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)

            TextField("Search contacts...", text: $searchText)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.primary)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var contactsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredContacts, id: \.identifier) { contact in
                    contactRow(contact: contact)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleContact(contact) }
                    if contact.identifier != filteredContacts.last?.identifier {
                        Divider().padding(.leading, 72)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func contactRow(contact: CNContact) -> some View {
        let isSelected = selectedContacts.contains(contact.identifier)
        let fullName   = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)

        return HStack(spacing: 14) {
            if let imageData = contact.imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable().scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.1)).frame(width: 44, height: 44)
                    Text(String(contact.givenName.prefix(1)))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(fullName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                if let phone = contact.phoneNumbers.first?.value.stringValue {
                    Text(phone).font(.system(size: 14)).foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 24))
                .foregroundColor(isSelected ? .accentColor : .secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isSelected ? Color.accentColor.opacity(0.05) : Color.clear)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.2)
            Text("Loading contacts...")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Contacts Found")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
            Text("Make sure you've granted access to your contacts")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadContacts() {
        DispatchQueue.global(qos: .userInitiated).async {
            let store = CNContactStore()
            let keysToFetch: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactImageDataKey as CNKeyDescriptor
            ]
            store.requestAccess(for: .contacts) { granted, _ in
                guard granted else {
                    DispatchQueue.main.async { isLoading = false }
                    return
                }
                var contacts: [CNContact] = []
                let request = CNContactFetchRequest(keysToFetch: keysToFetch)
                do {
                    try store.enumerateContacts(with: request) { contact, _ in contacts.append(contact) }
                    DispatchQueue.main.async {
                        allContacts = contacts.sorted {
                            "\($0.givenName) \($0.familyName)" < "\($1.givenName) \($1.familyName)"
                        }
                        isLoading = false
                    }
                } catch {
                    print("Failed to fetch contacts: \(error)")
                    DispatchQueue.main.async { isLoading = false }
                }
            }
        }
    }

    private func toggleContact(_ contact: CNContact) {
        HapticManager.impact(style: .light)
        if selectedContacts.contains(contact.identifier) {
            selectedContacts.remove(contact.identifier)
        } else {
            selectedContacts.insert(contact.identifier)
        }
    }
}

// MARK: - System Contact Picker (UIKit wrapper)

struct ContactPickerView: UIViewControllerRepresentable {
    let onContactsSelected: ([CNContact]) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: ContactPickerView
        init(_ parent: ContactPickerView) { self.parent = parent }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            parent.onContactsSelected(contacts)
            parent.dismiss()
        }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { parent.dismiss() }
    }
}
