import SwiftUI
import Contacts

struct PeopleView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    
    @State private var newPersonName = ""
    @State private var showContactPicker = false
    @State private var showSaveGroupDialog = false
    @State private var groupName = ""
    
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
                VStack(alignment: .leading, spacing: 24) {
                    // Title
                    Text("Who's Splitting?")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.black)
                    
                    // Add People Section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Add People")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.black)
                        
                        // Current user (pre-filled)
                        HStack {
                            Text(appState.profile.name)
                                .font(.system(size: 16))
                                .foregroundColor(.gray)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                                )
                        }
                        
                        // Add new person
                        HStack(spacing: 8) {
                            TextField("Add a person", text: $newPersonName)
                                .font(.system(size: 16))
                                .padding(12)
                                .background(Color.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.black, lineWidth: 1)
                                )
                            
                            Button(action: addPerson) {
                                Text("Add")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 12)
                                    .background(Color.black)
                                    .cornerRadius(8)
                            }
                            .disabled(newPersonName.isEmpty)
                        }
                        
                        // Add from Contacts
                        Button(action: {
                            requestContactsAccess()
                        }) {
                            HStack {
                                Image(systemName: "person.crop.circle.badge.plus")
                                    .font(.system(size: 16))
                                
                                Text("Add from Contacts")
                                    .font(.system(size: 16, weight: .medium))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.black, lineWidth: 1)
                            )
                        }
                    }
                    
                    // People List
                    if appState.people.count > 1 {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("People")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.black)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(appState.people.filter { !$0.isCurrentUser }) { person in
                                        ChipView(
                                            person: person,
                                            onRemove: {
                                                appState.removePerson(person)
                                            }
                                        )
                                    }
                                }
                            }
                        }
                    }
                    
                    // Saved Groups
                    if !appState.savedGroups.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Recent Groups")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.black)
                            
                            ForEach(appState.savedGroups.sorted(by: { $0.lastUsed > $1.lastUsed }).prefix(3)) { group in
                                Button(action: {
                                    loadGroup(group)
                                }) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(group.name)
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundColor(.black)
                                            
                                            Text("\(group.members.count) people")
                                                .font(.system(size: 12))
                                                .foregroundColor(.gray)
                                        }
                                        
                                        Spacer()
                                        
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12))
                                            .foregroundColor(.gray)
                                    }
                                    .padding(12)
                                    .background(Color.white)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.black, lineWidth: 1)
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGray6))
            
            // Bottom CTA
            VStack(spacing: 12) {
                if appState.people.count > 1 {
                    Button(action: {
                        showSaveGroupDialog = true
                    }) {
                        Text("Save this group?")
                            .font(.system(size: 14))
                            .foregroundColor(.black)
                    }
                }
                
                Button(action: {
                    router.navigateToProcessing()
                }) {
                    Text("Next")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(appState.people.count > 1 ? Color.black : Color.gray)
                        .cornerRadius(12)
                }
                .disabled(appState.people.count <= 1)
            }
            .padding(20)
            .background(Color.white)
        }
        .navigationBarBackButtonHidden(true)
        .alert("Save Group", isPresented: $showSaveGroupDialog) {
            TextField("Group name (e.g., Chicago crew)", text: $groupName)
            Button("Save") {
                if !groupName.isEmpty {
                    appState.saveGroup(name: groupName)
                    groupName = ""
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    
    private func addPerson() {
        guard !newPersonName.isEmpty else { return }
        
        let person = Person(name: newPersonName)
        appState.addPerson(person)
        newPersonName = ""
    }
    
    private func loadGroup(_ group: Group) {
        // Keep current user, add group members
        let currentUser = appState.people.first(where: { $0.isCurrentUser })
        appState.people = [currentUser].compactMap { $0 } + group.members.filter { !$0.isCurrentUser }
    }
    
    private func requestContactsAccess() {
        let store = CNContactStore()
        
        store.requestAccess(for: .contacts) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    fetchContacts()
                }
            }
        }
    }
    
    private func fetchContacts() {
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactImageDataKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        
        var contacts: [Person] = []
        
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = "\(contact.givenName) \(contact.familyName)"
                let person = Person(name: name, contactImage: contact.imageData)
                contacts.append(person)
            }
            
            // For simplicity, add first 5 contacts
            for contact in contacts.prefix(5) {
                if !appState.people.contains(where: { $0.name == contact.name }) {
                    appState.addPerson(contact)
                }
            }
        } catch {
            print("Failed to fetch contacts: \(error)")
        }
    }
}
