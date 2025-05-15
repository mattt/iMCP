import Contacts
import Foundation
import OSLog
import Ontology

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
                properties: [
                    "identifier": .string(
                        description: "Unique identifier of the contact to update"
                    ),
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
                        required: ["mobile", "work", "home"]
                    ),
                    "emailAddresses": .object(
                        properties: [
                            "work": .string(),
                            "home": .string(),
                        ],
                        required: ["work", "home"]
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
                                ],
                                required: ["street", "city", "state", "postalCode", "country"]
                            ),
                            "home": .object(
                                properties: [
                                    "street": .string(),
                                    "city": .string(),
                                    "state": .string(),
                                    "postalCode": .string(),
                                    "country": .string(),
                                ],
                                required: ["street", "city", "state", "postalCode", "country"]
                            ),
                        ],
                        required: ["work", "home"]
                    ),
                    "birthday": .object(
                        properties: [
                            "day": .integer(),
                            "month": .integer(),
                            "year": .integer(),
                        ],
                        required: ["day", "month"]
                    ),
                ],
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

            guard let mutableContact = contact else {
                throw NSError(
                    domain: "ContactsService", code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Contact not found with identifier: \(identifier)"
                    ]
                )
            }

            // Update basic properties
            if case let .string(givenName) = arguments["givenName"] {
                mutableContact.givenName = givenName
            }

            if case let .string(familyName) = arguments["familyName"] {
                mutableContact.familyName = familyName
            }

            if case let .string(organizationName) = arguments["organizationName"] {
                mutableContact.organizationName = organizationName
            }

            if case let .string(jobTitle) = arguments["jobTitle"] {
                mutableContact.jobTitle = jobTitle
            }

            // Update phone numbers
            if case let .object(phoneNumbers) = arguments["phoneNumbers"] {
                mutableContact.phoneNumbers = phoneNumbers.compactMap { entry in
                    guard case let .string(value) = entry.value, !value.isEmpty
                    else {
                        return nil
                    }

                    let labelValue =
                        entry.key == "mobile"
                        ? CNLabelPhoneNumberMobile
                        : entry.key == "work"
                            ? CNLabelWork : entry.key == "home" ? CNLabelHome : entry.key

                    return CNLabeledValue(
                        label: labelValue,
                        value: CNPhoneNumber(stringValue: value)
                    )
                }
            }

            // Update email addresses
            if case let .object(emailAddresses) = arguments["emailAddresses"] {
                mutableContact.emailAddresses = emailAddresses.compactMap { entry in
                    guard case let .string(value) = entry.value, !value.isEmpty
                    else {
                        return nil
                    }

                    let labelValue =
                        entry.key == "work"
                        ? CNLabelWork : entry.key == "home" ? CNLabelHome : entry.key

                    return CNLabeledValue(
                        label: labelValue,
                        value: value as NSString
                    )
                }
            }

            // Update postal addresses
            if case let .object(postalAddresses) = arguments["postalAddresses"] {
                mutableContact.postalAddresses = postalAddresses.compactMap { entry in
                    guard case let .object(addressData) = entry.value
                    else {
                        return nil
                    }

                    let labelValue =
                        entry.key == "work"
                        ? CNLabelWork : entry.key == "home" ? CNLabelHome : entry.key

                    let postalAddress = CNMutablePostalAddress()

                    if case let .string(street) = addressData["street"] {
                        postalAddress.street = street
                    }
                    if case let .string(city) = addressData["city"] {
                        postalAddress.city = city
                    }
                    if case let .string(state) = addressData["state"] {
                        postalAddress.state = state
                    }
                    if case let .string(postalCode) = addressData["postalCode"] {
                        postalAddress.postalCode = postalCode
                    }
                    if case let .string(country) = addressData["country"] {
                        postalAddress.country = country
                    }

                    return CNLabeledValue(
                        label: labelValue,
                        value: postalAddress
                    )
                }
            }

            // Update birthday
            if case let .object(birthdayData) = arguments["birthday"],
                case let .int(day) = birthdayData["day"],
                case let .int(month) = birthdayData["month"]
            {
                var dateComponents = DateComponents()
                dateComponents.day = day
                dateComponents.month = month
                if case let .int(year) = birthdayData["year"] {
                    dateComponents.year = year
                }
                mutableContact.birthday = dateComponents
            }

            // Create a save request
            let saveRequest = CNSaveRequest()
            saveRequest.update(mutableContact)

            // Save the changes
            try self.contactStore.execute(saveRequest)

            return true
        }

        Tool(
            name: "contacts_create",
            description:
                "Create a new contact with the specified information.",
            inputSchema: .object(
                properties: [
                    "givenName": .string(
                        description: "First name of the contact"
                    ),
                    "familyName": .string(
                        description: "Last name of the contact"
                    ),
                    "organizationName": .string(
                        description: "Organization or company name"
                    ),
                    "jobTitle": .string(
                        description: "Job title or position"
                    ),
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
                            "day": .integer(
                                description: "Day of birth (1-31)"
                            ),
                            "month": .integer(
                                description: "Month of birth (1-12)"
                            ),
                            "year": .integer(
                                description: "Year of birth (optional)"
                            ),
                        ],
                        required: ["day", "month"]
                    ),
                ],
                required: ["givenName"]
            ),
            annotations: .init(
                title: "Create Contact",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            // Create a new contact
            let newContact = CNMutableContact()

            // Set basic properties
            if case let .string(givenName) = arguments["givenName"] {
                newContact.givenName = givenName
            } else {
                throw NSError(
                    domain: "ContactsService", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Given name is required"]
                )
            }

            if case let .string(familyName) = arguments["familyName"] {
                newContact.familyName = familyName
            }

            if case let .string(organizationName) = arguments["organizationName"] {
                newContact.organizationName = organizationName
            }

            if case let .string(jobTitle) = arguments["jobTitle"] {
                newContact.jobTitle = jobTitle
            }

            // Set phone numbers
            if case let .object(phoneNumbers) = arguments["phoneNumbers"] {
                newContact.phoneNumbers = phoneNumbers.compactMap { entry in
                    guard case let .string(value) = entry.value, !value.isEmpty
                    else {
                        return nil
                    }

                    let labelValue =
                        entry.key == "mobile"
                        ? CNLabelPhoneNumberMobile
                        : entry.key == "work"
                            ? CNLabelWork : entry.key == "home" ? CNLabelHome : entry.key

                    return CNLabeledValue(
                        label: labelValue,
                        value: CNPhoneNumber(stringValue: value)
                    )
                }
            }

            // Set email addresses
            if case let .object(emailAddresses) = arguments["emailAddresses"] {
                newContact.emailAddresses = emailAddresses.compactMap { entry in
                    guard case let .string(value) = entry.value, !value.isEmpty
                    else {
                        return nil
                    }

                    let labelValue =
                        entry.key == "work"
                        ? CNLabelWork : entry.key == "home" ? CNLabelHome : entry.key

                    return CNLabeledValue(
                        label: labelValue,
                        value: value as NSString
                    )
                }
            }

            // Set postal addresses
            if case let .object(postalAddresses) = arguments["postalAddresses"] {
                newContact.postalAddresses = postalAddresses.compactMap { entry in
                    guard case let .object(addressData) = entry.value
                    else {
                        return nil
                    }

                    let labelValue =
                        entry.key == "work"
                        ? CNLabelWork : entry.key == "home" ? CNLabelHome : entry.key

                    let postalAddress = CNMutablePostalAddress()

                    if case let .string(street) = addressData["street"] {
                        postalAddress.street = street
                    }
                    if case let .string(city) = addressData["city"] {
                        postalAddress.city = city
                    }
                    if case let .string(state) = addressData["state"] {
                        postalAddress.state = state
                    }
                    if case let .string(postalCode) = addressData["postalCode"] {
                        postalAddress.postalCode = postalCode
                    }
                    if case let .string(country) = addressData["country"] {
                        postalAddress.country = country
                    }

                    return CNLabeledValue(
                        label: labelValue,
                        value: postalAddress
                    )
                }
            }

            // Set birthday
            if case let .object(birthdayData) = arguments["birthday"],
                case let .int(day) = birthdayData["day"],
                case let .int(month) = birthdayData["month"]
            {
                let dateComponents = NSDateComponents()
                dateComponents.day = day
                dateComponents.month = month

                if case let .int(year) = birthdayData["year"] {
                    dateComponents.year = year
                }

                newContact.birthday = dateComponents as DateComponents
            }

            // Create a save request
            let saveRequest = CNSaveRequest()
            saveRequest.add(newContact, toContainerWithIdentifier: nil)

            // Execute the save request
            try self.contactStore.execute(saveRequest)

            // Return the identifier of the newly created contact
            return ["identifier": newContact.identifier]
        }
    }
}
