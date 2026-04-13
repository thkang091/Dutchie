import Foundation
import Contacts

class ContactsService {
    static func requestAccess(completion: @escaping (Bool) -> Void) {
        let store = CNContactStore()
        
        store.requestAccess(for: .contacts) { granted, error in
            DispatchQueue.main.async {
                completion(granted && error == nil)
            }
        }
    }
    
    static func fetchContacts(limit: Int = 50) -> [Person] {
        let store = CNContactStore()
        let keys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactImageDataKey
        ] as [CNKeyDescriptor]
        
        let request = CNContactFetchRequest(keysToFetch: keys)
        var people: [Person] = []
        
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                
                if !fullName.isEmpty {
                    let person = Person(
                        name: fullName,
                        contactImage: contact.imageData
                    )
                    people.append(person)
                }
                
                if people.count >= limit {
                    stop.pointee = true
                }
            }
        } catch {
            print("Failed to fetch contacts: \(error)")
        }
        
        return people
    }
    
    static func searchContacts(query: String, limit: Int = 10) -> [Person] {
        let store = CNContactStore()
        let keys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactImageDataKey
        ] as [CNKeyDescriptor]
        
        let predicate = CNContact.predicateForContacts(matchingName: query)
        var people: [Person] = []
        
        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            
            for contact in contacts.prefix(limit) {
                let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                
                if !fullName.isEmpty {
                    let person = Person(
                        name: fullName,
                        contactImage: contact.imageData
                    )
                    people.append(person)
                }
            }
        } catch {
            print("Failed to search contacts: \(error)")
        }
        
        return people
    }
}
