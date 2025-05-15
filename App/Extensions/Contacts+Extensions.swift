import Contacts
import Ontology

/// Helper for working with contact label constants
enum CNContactLabel {
    static func from(string: String) -> String {
        switch string.lowercased() {
        case "mobile": return CNLabelPhoneNumberMobile
        case "work": return CNLabelWork
        case "home": return CNLabelHome
        default: return string
        }
    }

    static var allPhoneLabels: [String] {
        return [CNLabelPhoneNumberMobile, CNLabelWork, CNLabelHome]
    }

    static var allEmailLabels: [String] {
        return [CNLabelWork, CNLabelHome]
    }

    static var allAddressLabels: [String] {
        return [CNLabelWork, CNLabelHome]
    }
}

extension CNMutableContact {
    /// Populate a contact from provided arguments dictionary
    func populate(from arguments: [String: Value]) {
        // Set given name
        if case let .string(givenName) = arguments["givenName"] {
            self.givenName = givenName
        }

        // Set family name
        if case let .string(familyName) = arguments["familyName"] {
            self.familyName = familyName
        }

        // Set organization name
        if case let .string(organizationName) = arguments["organizationName"] {
            self.organizationName = organizationName
        }

        // Set job title
        if case let .string(jobTitle) = arguments["jobTitle"] {
            self.jobTitle = jobTitle
        }

        // Set phone numbers
        if case let .object(phoneNumbers) = arguments["phoneNumbers"] {
            self.phoneNumbers = phoneNumbers.compactMap { entry in
                guard case let .string(value) = entry.value, !value.isEmpty else { return nil }
                return CNLabeledValue(
                    label: CNContactLabel.from(string: entry.key),
                    value: CNPhoneNumber(stringValue: value)
                )
            }
        }

        // Set email addresses
        if case let .object(emailAddresses) = arguments["emailAddresses"] {
            self.emailAddresses = emailAddresses.compactMap { entry in
                guard case let .string(value) = entry.value, !value.isEmpty else { return nil }
                return CNLabeledValue(
                    label: CNContactLabel.from(string: entry.key),
                    value: value as NSString
                )
            }
        }

        // Set postal addresses
        if case let .object(postalAddresses) = arguments["postalAddresses"] {
            self.postalAddresses = postalAddresses.compactMap { entry in
                guard case let .object(addressData) = entry.value else { return nil }

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
                    label: CNContactLabel.from(string: entry.key),
                    value: postalAddress
                )
            }
        }

        // Set birthday
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

            self.birthday = dateComponents
        }
    }
}
