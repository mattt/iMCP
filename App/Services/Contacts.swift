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
    private let contactStoreQueue = DispatchQueue(label: "iMCP.contacts", qos: .utility)

    static let shared = ContactsService()

    private func runContactStore<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            contactStoreQueue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

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
                domain: "ContactsService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Contacts access denied"]
            )
        case .restricted:
            log.error("Contacts access restricted")
            throw NSError(
                domain: "ContactsService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Contacts access restricted"]
            )
        case .notDetermined:
            log.debug("Requesting contacts access")
            _ = try await contactStore.requestAccess(for: .contacts)
        @unknown default:
            log.error("Unknown contacts authorization status")
            throw NSError(
                domain: "ContactsService",
                code: 1,
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
            let contact = try await self.runContactStore {
                try self.contactStore.unifiedMeContactWithKeys(toFetch: contactKeys)
            }
            return listedPerson(from: contact)
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
                let normalizedEmail = email.trimmingCharacters(in: .whitespaces).lowercased()
                if !normalizedEmail.isEmpty {
                    predicates.append(
                        CNContact.predicateForContacts(matchingEmailAddress: normalizedEmail)
                    )
                }
            }

            guard !predicates.isEmpty else {
                throw NSError(
                    domain: "ContactsService",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "At least one valid search parameter is required"
                    ]
                )
            }

            let finalPredicate =
                predicates.count == 1
                ? predicates[0]
                : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

            let contacts = try await self.runContactStore {
                try self.contactStore.unifiedContacts(
                    matching: finalPredicate,
                    keysToFetch: contactKeys
                )
            }

            return contacts.compactMap { listedPerson(from: $0) }
        }

        Tool(
            name: "contacts_list",
            description:
                "List contacts in a stable order. Returns every contact by default; use limit and offset to page through large address books.",
            inputSchema: .object(
                properties: [
                    "limit": .integer(
                        description: "Maximum number of contacts to return",
                        minimum: 1
                    ),
                    "offset": .integer(
                        description: "Number of contacts to skip, in the same stable order",
                        default: .int(0),
                        minimum: 0
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Contacts",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            var limit = Int.max
            if case .int(let value) = arguments["limit"], value > 0 {
                limit = value
            }
            var offset = 0
            if case .int(let value) = arguments["offset"], value > 0 {
                offset = value
            }

            let contacts = try await self.runContactStore {
                var results: [CNContact] = []
                let request = CNContactFetchRequest(keysToFetch: contactKeys)
                request.unifyResults = true
                request.sortOrder = .userDefault
                try self.contactStore.enumerateContacts(with: request) { contact, _ in
                    results.append(contact)
                }
                return results
            }

            // Filter before paging so skipped organizations do not shorten pages.
            let people = contacts.compactMap { listedPerson(from: $0) }
            return Array(people.dropFirst(offset).prefix(limit))
        }

        Tool(
            name: "contacts_update",
            description:
                "Update an existing contact's information. Only provide values for properties that need to be changed; omit any properties that should remain unchanged. Reading or changing contact notes is not supported.",
            inputSchema: .object(
                properties: ([
                    "identifier": .string(
                        description: "Unique identifier of the contact to update"
                    )
                ] as OrderedDictionary).merging(
                    contactProperties,
                    uniquingKeysWith: { new, _ in new }
                ),
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
                    domain: "ContactsService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Valid contact identifier required"]
                )
            }

            // Serialize the fetch, edit, and save together
            // so later updates use the latest contact.
            return try await self.runContactStore {
                // Preserve the stored identity and leave unfetched fields untouched.
                let request = CNContactFetchRequest(keysToFetch: contactKeys)
                request.predicate = CNContact.predicateForContacts(withIdentifiers: [identifier])
                request.mutableObjects = true
                request.unifyResults = true

                var contact: CNMutableContact?
                try self.contactStore.enumerateContacts(with: request) { fetchedContact, stop in
                    contact = fetchedContact as? CNMutableContact
                    stop.pointee = true
                }

                guard let updatedContact = contact else {
                    throw NSError(
                        domain: "ContactsService",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Contact not found with identifier: \(identifier)"
                        ]
                    )
                }

                updatedContact.populate(from: arguments)

                let saveRequest = CNSaveRequest()
                saveRequest.update(updatedContact)

                try self.contactStore.execute(saveRequest)
                return Person(updatedContact)
            }
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
            return try await self.runContactStore {
                let newContact = CNMutableContact()
                newContact.populate(from: arguments)

                if newContact.givenName.isEmpty {
                    throw NSError(
                        domain: "ContactsService",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Given name is required"]
                    )
                }

                let saveRequest = CNSaveRequest()
                saveRequest.add(newContact, toContainerWithIdentifier: nil)

                try self.contactStore.execute(saveRequest)
                return Person(newContact)
            }
        }
    }
}

/// Includes people marked as companies in Contacts.
/// Excludes organization cards without a given or family name.
private func listedPerson(from contact: CNContact) -> Person? {
    if let person = Person(contact) {
        return person
    }
    guard contact.contactType == .organization,
        !contact.givenName.isEmpty || !contact.familyName.isEmpty,
        let copy = contact.mutableCopy() as? CNMutableContact
    else { return nil }

    copy.contactType = .person
    return Person(copy)
}
