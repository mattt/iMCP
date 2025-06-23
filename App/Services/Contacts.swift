import Contacts
import Foundation
import JSONSchema
import OSLog
import Ontology
import OrderedCollections

private let log = Logger.service("contacts")

private let contactKeys =
    [
        CNContactTypeKey,
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactBirthdayKey,
        CNContactOrganizationNameKey,
        CNContactJobTitleKey,
        CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey,
        CNContactInstantMessageAddressesKey,
        CNContactSocialProfilesKey,
        CNContactUrlAddressesKey,
        CNContactPostalAddressesKey,
        CNContactRelationsKey,
    ] as [CNKeyDescriptor]

private let contactProperties: OrderedDictionary<String, JSONSchema> = [
    "givenName": .string(),
    "familyName": .string(),
    "organizationName": .string(),
    "jobTitle": .string(),
    "phoneNumbers": .object(
        properties: [
            "mobile": .string(),
            "work": .string(),
            "home": .string(),
        ],
        additionalProperties: true
    ),
    "emailAddresses": .object(
        properties: [
            "work": .string(),
            "home": .string(),
        ],
        additionalProperties: true
    ),
    "postalAddresses": .object(
        properties: [
            "work": .object(
                properties: [
                    "street": .string(),
                    "city": .string(),
                    "state": .string(),
                    "postalCode": .string(),
                    "country": .string(),
                ]
            ),
            "home": .object(
                properties: [
                    "street": .string(),
                    "city": .string(),
                    "state": .string(),
                    "postalCode": .string(),
                    "country": .string(),
                ]
            ),
        ],
        additionalProperties: true
    ),
    "birthday": .object(
        properties: [
            "day": .integer(minimum: 1, maximum: 31),
            "month": .integer(minimum: 1, maximum: 12),
            "year": .integer(),
        ],
        required: ["day", "month"]
    ),
]

final class ContactsService: Service {
    private let contactStore = CNContactStore()

    static let shared = ContactsService()

    var isActivated: Bool {
        get async {
            let status = CNContactStore.authorizationStatus(for: .contacts)
            return status == .authorized
        }
    }

    func activate() async throws {
        log.debug("Activating contacts service")
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            log.debug("Contacts access authorized")
            return
        case .denied:
            log.error("Contacts access denied")
            throw NSError(
                domain: "ContactsService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Contacts access denied"]
            )
        case .restricted:
            log.error("Contacts access restricted")
            throw NSError(
                domain: "ContactsService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Contacts access restricted"]
            )
        case .notDetermined:
            log.debug("Requesting contacts access")
            _ = try await contactStore.requestAccess(for: .contacts)
        @unknown default:
            log.error("Unknown contacts authorization status")
            throw NSError(
                domain: "ContactsService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unknown contacts authorization status"]
            )
        }
    }

    var tools: [Tool] {
        Tool(
            name: "contacts_me",
            description:
                "Get contact information about the user, including name, phone number, email, birthday, relations, address, online presence, and occupation. Always run this tool when the user asks a question that requires personal information about themselves.",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Who Am I?",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let contact = try self.contactStore.unifiedMeContactWithKeys(toFetch: contactKeys)
            return Person(contact)
        }

        Tool(
            name: "contacts_search",
            description:
                "Search contacts by name, phone number, and/or email",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "Name to search for"
                    ),
                    "phone": .string(
                        description: "Phone number to search for"
                    ),
                    "email": .string(
                        description: "Email address to search for"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Contacts",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            var predicates: [NSPredicate] = []

            if case let .string(name) = arguments["name"] {
                let normalizedName = name.trimmingCharacters(in: .whitespaces)
                if !normalizedName.isEmpty {
                    predicates.append(CNContact.predicateForContacts(matchingName: normalizedName))
                }
            }

            if case let .string(phone) = arguments["phone"] {
                let phoneNumber = CNPhoneNumber(stringValue: phone)
                predicates.append(CNContact.predicateForContacts(matching: phoneNumber))
            }

            if case let .string(email) = arguments["email"] {
                // Normalize email to lowercase
                let normalizedEmail = email.trimmingCharacters(in: .whitespaces).lowercased()
                if !normalizedEmail.isEmpty {
                    predicates.append(
                        CNContact.predicateForContacts(matchingEmailAddress: normalizedEmail))
                }
            }

            guard !predicates.isEmpty else {
                throw NSError(
                    domain: "ContactsService", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "At least one valid search parameter is required"
                    ]
                )
            }

            // Combine predicates with AND if multiple criteria are provided
            let finalPredicate =
                predicates.count == 1
                ? predicates[0]
                : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

            let contacts = try self.contactStore.unifiedContacts(
                matching: finalPredicate,
                keysToFetch: contactKeys
            )

            return contacts.compactMap { Person($0) }
        }

        Tool(
            name: "contacts_update",
            description:
                "Update an existing contact's information. Only provide values for properties that need to be changed; omit any properties that should remain unchanged.",
            inputSchema: .object(
                properties: ([
                    "identifier": .string(
                        description: "Unique identifier of the contact to update"
                    )
                ] as OrderedDictionary).merging(
                    contactProperties, uniquingKeysWith: { new, _ in new }),
                required: ["identifier"]
            ),
            annotations: .init(
                title: "Update Contact",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case let .string(identifier) = arguments["identifier"], !identifier.isEmpty else {
                throw NSError(
                    domain: "ContactsService", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Valid contact identifier required"]
                )
            }

            // Fetch the mutable copy of the contact
            let predicate = CNContact.predicateForContacts(withIdentifiers: [identifier])
            let contact =
                try self.contactStore.unifiedContacts(matching: predicate, keysToFetch: contactKeys)
                .first?
                .mutableCopy() as? CNMutableContact

            guard let updatedContact = contact else {
                throw NSError(
                    domain: "ContactsService", code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Contact not found with identifier: \(identifier)"
                    ]
                )
            }

            // Update all properties
            updatedContact.populate(from: arguments)

            // Create a save request
            let saveRequest = CNSaveRequest()
            saveRequest.update(updatedContact)

            // Save the changes
            try self.contactStore.execute(saveRequest)

            return Person(updatedContact)
        }

        Tool(
            name: "contacts_create",
            description:
                "Create a new contact with the specified information.",
            inputSchema: .object(
                properties: contactProperties,
                required: ["givenName"]
            ),
            annotations: .init(
                title: "Create Contact",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            // Create and populate a new contact
            let newContact = CNMutableContact()
            newContact.populate(from: arguments)

            // Validate that given name is provided and not empty
            if newContact.givenName.isEmpty {
                throw NSError(
                    domain: "ContactsService", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Given name is required"]
                )
            }

            // Create a save request
            let saveRequest = CNSaveRequest()
            saveRequest.add(newContact, toContainerWithIdentifier: nil)

            // Execute the save request
            try self.contactStore.execute(saveRequest)

            return Person(newContact)
        }
    }
}
