import Foundation
import MapKit
import OSLog
import Ontology

private let log = Logger.service("maps")

final class MapsService: NSObject, Service {
    private let searchCompleter = MKLocalSearchCompleter()
    private var searchResults: [MKLocalSearchCompletion] = []
    private var searchContinuation: CheckedContinuation<[MKLocalSearchCompletion], Error>?

    static let shared = MapsService()

    override init() {
        log.debug("Initializing maps service")
        super.init()
        self.searchCompleter.delegate = self
    }

    var isActivated: Bool {
        get async {
            // MapKit doesn't require explicit permission, but we rely on location
            return await LocationService.shared.isActivated
        }
    }

    func activate() async throws {
        log.debug("Activating maps service")
        // Maps service depends on location service being active
        try await LocationService.shared.activate()
    }

    var tools: [Tool] {
        Tool(
            name: "searchPlaces",
            description: "Search for places, addresses, points of interest by text query",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "The search text (place name, address, etc.)",
                    ],
                    "region": [
                        "type": "object",
                        "description": "Optional region to bias search results",
                        "properties": [
                            "latitude": ["type": "number"],
                            "longitude": ["type": "number"],
                            "radius": ["type": "number", "description": "Search radius in meters"],
                        ],
                    ],
                ],
                "required": ["query"],
            ]
        ) { arguments in
            guard let query = arguments["query"]?.stringValue else {
                throw NSError(
                    domain: "MapsServiceError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Search query is required"]
                )
            }

            // Set up search request
            let searchRequest = MKLocalSearch.Request()
            searchRequest.naturalLanguageQuery = query

            // Configure region if provided
            if let regionArg = arguments["region"]?.objectValue,
                let lat = regionArg["latitude"]?.doubleValue,
                let lon = regionArg["longitude"]?.doubleValue
            {
                let radius = regionArg["radius"]?.doubleValue ?? 5000  // Default 5km
                let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                let region = MKCoordinateRegion(
                    center: center,
                    latitudinalMeters: radius,
                    longitudinalMeters: radius
                )
                searchRequest.region = region
            }

            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Value, Error>) in

                let search = MKLocalSearch(request: searchRequest)
                search.start { response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let response = response else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "MapsServiceError", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "No search results"]
                            )
                        )
                        return
                    }

                    // Convert MKMapItems to Value objects
                    let results = response.mapItems.map { item -> [String: Value] in
                        var result: [String: Value] = [
                            "@type": .string("Place"),
                            "name": .string(item.name ?? "Unknown Place"),
                        ]

                        // Add coordinates
                        let coord = item.placemark.coordinate
                        result["geo"] = .object([
                            "@type": .string("GeoCoordinates"),
                            "latitude": .double(coord.latitude),
                            "longitude": .double(coord.longitude),
                        ])

                        // Add address if available
                        if let postalAddress = item.placemark.postalAddress {
                            var address: [String: Value] = [
                                "@type": .string("PostalAddress")
                            ]

                            if !postalAddress.street.isEmpty {
                                address["streetAddress"] = .string(postalAddress.street)
                            }
                            if !postalAddress.city.isEmpty {
                                address["addressLocality"] = .string(postalAddress.city)
                            }
                            if !postalAddress.state.isEmpty {
                                address["addressRegion"] = .string(postalAddress.state)
                            }
                            if !postalAddress.postalCode.isEmpty {
                                address["postalCode"] = .string(postalAddress.postalCode)
                            }
                            if !postalAddress.country.isEmpty {
                                address["addressCountry"] = .string(postalAddress.country)
                            }

                            if address.count > 1 {  // More than just @type
                                result["address"] = .object(address)
                            }
                        }

                        // Add phone number if available
                        if let phoneNumber = item.phoneNumber, !phoneNumber.isEmpty {
                            result["telephone"] = .string(phoneNumber)
                        }

                        // Add URL if available
                        if let url = item.url?.absoluteString, !url.isEmpty {
                            result["url"] = .string(url)
                        }

                        return result
                    }

                    continuation.resume(returning: .array(results.map { .object($0) }))
                }
            }
        }

        Tool(
            name: "getDirections",
            description: "Get directions between two locations with optional transport type",
            inputSchema: [
                "type": "object",
                "properties": [
                    "originAddress": [
                        "type": "string",
                        "description": "Origin address as text",
                    ],
                    "originCoordinates": [
                        "type": "object",
                        "description": "Origin coordinates",
                        "properties": [
                            "latitude": ["type": "number"],
                            "longitude": ["type": "number"],
                        ],
                        "required": ["latitude", "longitude"],
                    ],
                    "destinationAddress": [
                        "type": "string",
                        "description": "Destination address as text",
                    ],
                    "destinationCoordinates": [
                        "type": "object",
                        "description": "Destination coordinates",
                        "properties": [
                            "latitude": ["type": "number"],
                            "longitude": ["type": "number"],
                        ],
                        "required": ["latitude", "longitude"],
                    ],
                    "transportType": [
                        "type": "string",
                        "description": "Type of transportation (automobile, walking, transit, any)",
                        "enum": ["automobile", "walking", "transit", "any"],
                        "default": "automobile",
                    ],
                ],
            ]
        ) { arguments in
            // Need either origin address or coordinates
            guard
                arguments["originAddress"]?.stringValue != nil
                    || (arguments["originCoordinates"]?.objectValue?["latitude"]?.doubleValue != nil
                        && arguments["originCoordinates"]?.objectValue?["longitude"]?.doubleValue
                            != nil)
            else {
                throw NSError(
                    domain: "MapsServiceError", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Origin address or coordinates required"]
                )
            }

            // Need either destination address or coordinates
            guard
                arguments["destinationAddress"]?.stringValue != nil
                    || (arguments["destinationCoordinates"]?.objectValue?["latitude"]?.doubleValue
                        != nil
                        && arguments["destinationCoordinates"]?.objectValue?["longitude"]?
                            .doubleValue != nil)
            else {
                throw NSError(
                    domain: "MapsServiceError", code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Destination address or coordinates required"
                    ]
                )
            }

            // Get origin and destination
            let originItem = try await self.getMapItem(
                address: arguments["originAddress"]?.stringValue,
                coordinates: arguments["originCoordinates"]?.objectValue
            )

            let destinationItem = try await self.getMapItem(
                address: arguments["destinationAddress"]?.stringValue,
                coordinates: arguments["destinationCoordinates"]?.objectValue
            )

            // Set up directions request
            let directionsRequest = MKDirections.Request()
            directionsRequest.source = originItem
            directionsRequest.destination = destinationItem

            // Set transport type
            switch arguments["transportType"]?.stringValue {
            case "automobile":
                directionsRequest.transportType = .automobile
            case "walking":
                directionsRequest.transportType = .walking
            case "transit":
                directionsRequest.transportType = .transit
            default:
                directionsRequest.transportType = .any
            }

            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Value, Error>) in

                let directions = MKDirections(request: directionsRequest)
                directions.calculate { response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let response = response, !response.routes.isEmpty else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "MapsServiceError", code: 5,
                                userInfo: [NSLocalizedDescriptionKey: "No routes found"]
                            )
                        )
                        return
                    }

                    // Convert routes to Value objects
                    let routes = response.routes.map { route -> [String: Value] in
                        var routeInfo: [String: Value] = [
                            "@type": .string("Route"),
                            "distance": .double(route.distance),
                            "expectedTravelTime": .double(route.expectedTravelTime),
                            "name": .string(route.name),
                        ]

                        // Add steps if available
                        if !route.steps.isEmpty {
                            let steps = route.steps.map { step -> [String: Value] in
                                var stepInfo: [String: Value] = [
                                    "instructions": .string(step.instructions),
                                    "distance": .double(step.distance),
                                ]

                                if let notice = step.notice {
                                    stepInfo["notice"] = .string(notice)
                                }

                                return stepInfo
                            }

                            routeInfo["steps"] = .array(steps.map { .object($0) })
                        }

                        // Add warnings if any
                        if !route.advisoryNotices.isEmpty {
                            routeInfo["advisoryNotices"] = .array(
                                route.advisoryNotices.map { .string($0) }
                            )
                        }

                        return routeInfo
                    }

                    continuation.resume(returning: .array(routes.map { .object($0) }))
                }
            }
        }

        Tool(
            name: "findNearbyPointsOfInterest",
            description: "Find points of interest near a location",
            inputSchema: [
                "type": "object",
                "properties": [
                    "category": [
                        "type": "string",
                        "description": "Category of points of interest",
                        "enum": Value.array(MKPointOfInterestCategory.allCases.map { Value.string($0.stringValue) }),
                    ],
                    "latitude": ["type": "number"],
                    "longitude": ["type": "number"],
                    "radius": [
                        "type": "number",
                        "description": "Search radius in meters, default 1000m",
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Maximum number of results to return",
                        "default": 10,
                    ],
                ],
                "required": ["category", "latitude", "longitude"],
            ]
        ) { arguments in
            guard let categoryString = arguments["category"]?.stringValue,
                let latitude = arguments["latitude"]?.doubleValue,
                let longitude = arguments["longitude"]?.doubleValue
            else {
                throw NSError(
                    domain: "MapsServiceError", code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Category and coordinates are required"]
                )
            }

            let radius = arguments["radius"]?.doubleValue ?? 1000
            let limit = arguments["limit"]?.intValue ?? 10

            guard let category = MKPointOfInterestCategory.from(string: categoryString) else {
                throw NSError(
                    domain: "MapsServiceError", code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid POI category"]
                )
            }

            // Create search request
            let request = MKLocalPointsOfInterestRequest(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                radius: radius
            )
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [category])

            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Value, Error>) in

                let search = MKLocalSearch(request: request)
                search.start { response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let response = response else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "MapsServiceError", code: 8,
                                userInfo: [NSLocalizedDescriptionKey: "No POI results found"]
                            )
                        )
                        return
                    }

                    // Convert MKMapItems to Value objects
                    let results = response.mapItems.prefix(limit).map { item -> [String: Value] in
                        var result: [String: Value] = [
                            "@type": .string("Place"),
                            "name": .string(item.name ?? "Unknown Place"),
                        ]

                        // Add coordinates
                        let coord = item.placemark.coordinate
                        result["geo"] = .object([
                            "@type": .string("GeoCoordinates"),
                            "latitude": .double(coord.latitude),
                            "longitude": .double(coord.longitude),
                        ])

                        // Add category
                        result["category"] = .string(categoryString)

                        // Add address if available
                        if let postalAddress = item.placemark.postalAddress {
                            var address: [String: Value] = [
                                "@type": .string("PostalAddress")
                            ]

                            if !postalAddress.street.isEmpty {
                                address["streetAddress"] = .string(postalAddress.street)
                            }
                            if !postalAddress.city.isEmpty {
                                address["addressLocality"] = .string(postalAddress.city)
                            }
                            if !postalAddress.state.isEmpty {
                                address["addressRegion"] = .string(postalAddress.state)
                            }
                            if !postalAddress.postalCode.isEmpty {
                                address["postalCode"] = .string(postalAddress.postalCode)
                            }
                            if !postalAddress.country.isEmpty {
                                address["addressCountry"] = .string(postalAddress.country)
                            }

                            if address.count > 1 {  // More than just @type
                                result["address"] = .object(address)
                            }
                        }

                        // Add phone number if available
                        if let phoneNumber = item.phoneNumber, !phoneNumber.isEmpty {
                            result["telephone"] = .string(phoneNumber)
                        }

                        // Add URL if available
                        if let url = item.url?.absoluteString, !url.isEmpty {
                            result["url"] = .string(url)
                        }

                        return result
                    }

                    continuation.resume(returning: .array(results.map { .object($0) }))
                }
            }
        }

        Tool(
            name: "getETABetweenLocations",
            description: "Calculate estimated travel time between two locations",
            inputSchema: [
                "type": "object",
                "properties": [
                    "originLatitude": ["type": "number"],
                    "originLongitude": ["type": "number"],
                    "destinationLatitude": ["type": "number"],
                    "destinationLongitude": ["type": "number"],
                    "transportType": [
                        "type": "string",
                        "description": "Type of transportation (automobile, walking, transit)",
                        "enum": ["automobile", "walking", "transit"],
                        "default": "automobile",
                    ],
                ],
                "required": [
                    "originLatitude", "originLongitude", "destinationLatitude",
                    "destinationLongitude",
                ],
            ]
        ) { arguments in
            guard let originLat = arguments["originLatitude"]?.doubleValue,
                let originLng = arguments["originLongitude"]?.doubleValue,
                let destLat = arguments["destinationLatitude"]?.doubleValue,
                let destLng = arguments["destinationLongitude"]?.doubleValue
            else {
                throw NSError(
                    domain: "MapsServiceError", code: 9,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Origin and destination coordinates required"
                    ]
                )
            }

            // Create origin and destination placemarks
            let originPlacemark = MKPlacemark(
                coordinate: CLLocationCoordinate2D(latitude: originLat, longitude: originLng)
            )
            let destPlacemark = MKPlacemark(
                coordinate: CLLocationCoordinate2D(latitude: destLat, longitude: destLng)
            )

            // Create map items from placemarks
            let originItem = MKMapItem(placemark: originPlacemark)
            let destinationItem = MKMapItem(placemark: destPlacemark)

            // Set up directions request
            let directionsRequest = MKDirections.Request()
            directionsRequest.source = originItem
            directionsRequest.destination = destinationItem

            // Set transport type
            if let transportTypeStr = arguments["transportType"]?.stringValue {
                switch transportTypeStr {
                case "automobile":
                    directionsRequest.transportType = .automobile
                case "walking":
                    directionsRequest.transportType = .walking
                case "transit":
                    directionsRequest.transportType = .transit
                default:
                    directionsRequest.transportType = .automobile
                }
            } else {
                directionsRequest.transportType = .automobile
            }

            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Value, Error>) in

                let directions = MKDirections(request: directionsRequest)
                directions.calculateETA { response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let response = response else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "MapsServiceError", code: 10,
                                userInfo: [NSLocalizedDescriptionKey: "Could not calculate ETA"]
                            )
                        )
                        return
                    }

                    var result: [String: Value] = [
                        "expectedTravelTime": .double(response.expectedTravelTime),
                        "distance": .double(response.distance),
                    ]

                    let arrival = response.expectedArrivalDate
                    let formatter = ISO8601DateFormatter()
                    result["expectedArrivalTime"] = .string(formatter.string(from: arrival))

                    continuation.resume(returning: .object(result))
                }
            }
        }

        Tool(
            name: "generateMapImage",
            description: "Generate a static map image for given coordinates and parameters",
            inputSchema: [
                "type": "object",
                "properties": [
                    "latitude": ["type": "number"],
                    "longitude": ["type": "number"],
                    "latitudeDelta": [
                        "type": "number",
                        "description": "Amount of latitude degrees to be visible on the map",
                    ],
                    "longitudeDelta": [
                        "type": "number",
                        "description": "Amount of longitude degrees to be visible on the map",
                    ],
                    "width": [
                        "type": "integer",
                        "description": "Width of the desired map image in pixels",
                        "default": 512,
                    ],
                    "height": [
                        "type": "integer",
                        "description": "Height of the desired map image in pixels",
                        "default": 512,
                    ],
                    "mapType": [
                        "type": "string",
                        "description": "Type of map (standard, satellite, hybrid, mutedStandard)",
                        "enum": ["standard", "satellite", "hybrid", "mutedStandard"],
                        "default": "standard",
                    ],
                    "showPointsOfInterest": [
                        "oneOf": [
                            [
                                "type": "boolean",
                                "description": "Whether to show points of interest on the map",
                            ],
                            [
                                "type": "array",
                                "description":
                                    "Multiple specific types of points of interest to show",
                                "items": [
                                    "type": "string",
                                    "enum": Value.array(MKPointOfInterestCategory.allCases.map { Value.string($0.stringValue) }),
                                ],
                                "minItems": 1,
                            ],
                        ],
                        "default": false,
                    ],
                    "showBuildings": [
                        "type": "boolean",
                        "description": "Whether to show buildings on the map",
                        "default": false,
                    ],
                ],
                "required": ["latitude", "longitude", "latitudeDelta", "longitudeDelta"],
            ]
        ) { arguments in
            guard let latitude = arguments["latitude"]?.doubleValue,
                let longitude = arguments["longitude"]?.doubleValue,
                let latitudeDelta = arguments["latitudeDelta"]?.doubleValue,
                let longitudeDelta = arguments["longitudeDelta"]?.doubleValue
            else {
                throw NSError(
                    domain: "MapsServiceError", code: 13,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Latitude, longitude, latitudeDelta, and longitudeDelta are required"
                    ]
                )
            }

            let width = arguments["width"]?.intValue ?? 512
            let height = arguments["height"]?.intValue ?? 512
            let mapTypeString = arguments["mapType"]?.stringValue ?? "standard"

            let options = MKMapSnapshotter.Options()

            let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            let span = MKCoordinateSpan(
                latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
            options.region = MKCoordinateRegion(center: center, span: span)

            switch mapTypeString {
            case "satellite":
                options.mapType = .satellite
            case "hybrid":
                options.mapType = .hybrid
            case "mutedStandard":
                options.mapType = .mutedStandard
            default:
                options.mapType = .standard
            }

            options.size = CGSize(width: width, height: height)

            let filter: MKPointOfInterestFilter
            switch arguments["showPointsOfInterest"] {
            case .bool(true):
                filter = .includingAll
            case .bool(false):
                filter = .excludingAll
            case let .array(poiTypes):
                let categories = poiTypes.compactMap { $0.stringValue }.compactMap { MKPointOfInterestCategory.from(string: $0) }
                filter = categories.isEmpty ? .excludingAll : .init(including: categories)
            default:
                filter = .excludingAll
            }
            options.pointOfInterestFilter = filter
                
            options.showsBuildings = arguments["showBuildings"]?.boolValue == true

            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Value, Error>) in

                let snapshotter = MKMapSnapshotter(options: options)
                snapshotter.start { snapshot, error in
                    if let error = error {
                        log.error("Map snapshot failed: \(error.localizedDescription)")
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let snapshot = snapshot else {
                        log.error("Map snapshot failed: No snapshot data")
                        continuation.resume(
                            throwing: NSError(
                                domain: "MapsServiceError", code: 14,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "Failed to generate map snapshot"
                                ]
                            )
                        )
                        return
                    }

                    // Get image representation (e.g., PNG)
                    guard let imageData = snapshot.image.tiffRepresentation,
                        let bitmap = NSBitmapImageRep(data: imageData),
                        let pngData = bitmap.representation(using: .png, properties: [:])
                    else {
                        log.error("Map snapshot failed: Could not convert image to PNG")
                        continuation.resume(
                            throwing: NSError(
                                domain: "MapsServiceError", code: 15,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "Failed to convert snapshot to PNG format"
                                ]
                            )
                        )
                        return
                    }

                    let base64String = pngData.base64EncodedString()
                    let mimeType = "image/png"

                    log.info("Successfully generated map snapshot (\(pngData.count) bytes)")

                    // Return as a Value object containing base64 data and mime type
                    // Client will need to decode this.
                    continuation.resume(
                        returning: .object([
                            "@type": .string("ImageObject"),  // Schema.org type
                            "contentUrl": .string("data:\(mimeType);base64,\(base64String)"),
                            "encodingFormat": .string(mimeType),
                        ])
                    )
                }
            }
        }
    }

    // MARK: - Helper methods

    private func getMapItem(address: String?, coordinates: [String: Value]?) async throws
        -> MKMapItem
    {
        if let address = address {
            // Use geocoding to get location from address
            let searchRequest = MKLocalSearch.Request()
            searchRequest.naturalLanguageQuery = address

            let search = MKLocalSearch(request: searchRequest)
            let response = try await search.start()

            guard let mapItem = response.mapItems.first else {
                throw NSError(
                    domain: "MapsServiceError", code: 11,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Could not find location for address: \(address)"
                    ]
                )
            }

            return mapItem
        } else if let coordinates = coordinates,
            let lat = coordinates["latitude"]?.doubleValue,
            let lng = coordinates["longitude"]?.doubleValue
        {

            // Create placemark and map item from coordinates
            let placemark = MKPlacemark(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng)
            )
            return MKMapItem(placemark: placemark)
        } else {
            throw NSError(
                domain: "MapsServiceError", code: 12,
                userInfo: [
                    NSLocalizedDescriptionKey: "Either address or coordinates must be provided"
                ]
            )
        }
    }
}

// MARK: - MKLocalSearchCompleterDelegate
extension MapsService: MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        self.searchResults = completer.results
        self.searchContinuation?.resume(returning: completer.results)
        self.searchContinuation = nil
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        self.searchContinuation?.resume(throwing: error)
        self.searchContinuation = nil
    }
}
