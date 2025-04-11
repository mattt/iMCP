import MapKit

extension MKPointOfInterestCategory {
    static func from(string: String) -> MKPointOfInterestCategory? {
        switch string {
        case "airport": return .airport
        case "restaurant": return .restaurant
        case "gas": return .gasStation
        case "parking": return .parking
        case "hotel": return .hotel
        case "hospital": return .hospital
        case "police": return .police
        case "fire": return .fireStation
        case "store": return .store
        case "museum": return .museum
        case "park": return .park
        case "school": return .school
        case "library": return .library
        case "theater": return .theater
        case "bank": return .bank
        case "atm": return .atm
        case "cafe": return .cafe
        case "pharmacy": return .pharmacy
        case "gym": return .fitnessCenter
        case "laundry": return .laundry
        default: return nil
        }
    }

    static var allCases: [MKPointOfInterestCategory] {
        return [
            .airport, .restaurant, .gasStation, .parking, .hotel, .hospital,
            .police, .fireStation, .store, .museum, .park, .school,
            .library, .theater, .bank, .atm, .cafe, .pharmacy, .fitnessCenter, .laundry,
        ]
    }

    var stringValue: String {
        switch self {
        case .airport: return "airport"
        case .restaurant: return "restaurant"
        case .gasStation: return "gas"
        case .parking: return "parking"
        case .hotel: return "hotel"
        case .hospital: return "hospital"
        case .police: return "police"
        case .fireStation: return "fire"
        case .store: return "store"
        case .museum: return "museum"
        case .park: return "park"
        case .school: return "school"
        case .library: return "library"
        case .theater: return "theater"
        case .bank: return "bank"
        case .atm: return "atm"
        case .cafe: return "cafe"
        case .pharmacy: return "pharmacy"
        case .fitnessCenter: return "gym"
        case .laundry: return "laundry"
        default: return "unknown"
        }
    }
}
