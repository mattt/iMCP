import Foundation
import MapKit
import OSLog
import Ontology

private let log = Logger.service("maps")

private let defaultSearchRadius: CLLocationDistance = 5000  // Default 5km
private let defaultSearchLimit: Int = 10
private let defaultMapImageSize: CGSize = CGSize(width: 1024, height: 1024)

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
            name: "maps_search",
            description: "Search for places, addresses, points of interest by text query",
            inputSchema: .object(
                properties: [
                    "query": .string(
                        description: "Search text (place name, address, etc.)"
                    ),
                    "region": .object(
                        description: "Region to bias search results",
                        properties: [
                            "latitude": .number(),
                            "longitude": .number(),
                            "radius": .number(
                                description: "Search radius in meters",
                                default: .double(defaultSearchRadius)
                            ),
                        ],
                        required: ["latitude", "longitude"],
                        additionalProperties: false
                    ),
                ],
                required: ["query"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Places",
                readOnlyHint: true,
                openWorldHint: true
            )
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
                let radius = regionArg["radius"]?.doubleValue ?? defaultSearchRadius
                let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                let region = MKCoordinateRegion(
                    center: center,
                    latitudinalMeters: radius,
                    longitudinalMeters: radius
                )
                searchRequest.region = region
            }

            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[Place], Error>) in

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

                    // Convert MKMapItems to Ontology Place objects
                    let places = response.mapItems.map { item -> Place in
                        return Place(item)
                    }

                    continuation.resume(returning: places)
                }
            }
        }

        Tool(
            name: "maps_directions",
            description: "Get directions between two locations with optional transport type",
            inputSchema: .object(
                properties: [
                    "originAddress": .string(
                        description: "Origin address"
                    ),
                    "originCoordinates": .object(
                        description: "Origin coordinates",
                        properties: [
                            "latitude": .number(),
                            "longitude": .number(),
                        ],
                        required: ["latitude", "longitude"],
                        additionalProperties: false
                    ),
                    "destinationAddress": .string(
                        description: "Destination address"
                    ),
                    "destinationCoordinates": .object(
                        description: "Destination coordinates",
                        properties: [
                            "latitude": .number(),
                            "longitude": .number(),
                        ],
                        required: ["latitude", "longitude"],
                        additionalProperties: false
                    ),
                    "transportType": .string(
                        description: "Transport type",
                        default: "automobile",
                        enum: ["automobile", "walking", "transit", "any"]
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Directions",
                readOnlyHint: true,
                openWorldHint: true
            )
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
                (continuation: CheckedContinuation<Trip, Error>) in

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

                    let trip = Trip(response)

                    continuation.resume(returning: trip)
                }
            }
        }

        Tool(
            name: "maps_explore",
            description: "Find points of interest near a location",
            inputSchema: .object(
                properties: [
                    "category": .string(
                        description: "POI category",
                        enum: MKPointOfInterestCategory.allCases.map { .string($0.stringValue) }
                    ),
                    "latitude": .number(),
                    "longitude": .number(),
                    "radius": .number(
                        description: "Search radius in meters",
                        default: .double(defaultSearchRadius)
                    ),
                    "limit": .integer(
                        description: "Maximum results to return",
                        default: .int(defaultSearchLimit)
                    ),
                ],
                required: ["category", "latitude", "longitude"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Find Nearby Points of Interest",
                readOnlyHint: true,
                openWorldHint: true
            )
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

            let radius = arguments["radius"]?.doubleValue ?? defaultSearchRadius
            let limit = arguments["limit"]?.intValue ?? defaultSearchLimit

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
                (continuation: CheckedContinuation<[Place], Error>) in

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
                    let places = response.mapItems.prefix(limit).map { item -> Place in
                        return Place(item)
                    }

                    continuation.resume(returning: places)
                }
            }
        }

        Tool(
            name: "maps_eta",
            description: "Calculate estimated travel time between two locations",
            inputSchema: .object(
                properties: [
                    "originLatitude": .number(),
                    "originLongitude": .number(),
                    "destinationLatitude": .number(),
                    "destinationLongitude": .number(),
                    "transportType": .string(
                        description: "Transport type",
                        default: "automobile",
                        enum: ["automobile", "walking", "transit"]
                    ),
                ],
                required: [
                    "originLatitude", "originLongitude", "destinationLatitude",
                    "destinationLongitude",
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Estimated Travel Time",
                readOnlyHint: true,
                openWorldHint: true
            )
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
                (continuation: CheckedContinuation<Trip, Error>) in

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

                    let trip = Trip(response)

                    continuation.resume(returning: trip)
                }
            }
        }

        Tool(
            name: "maps_generate",
            description: "Generate a static map image for given coordinates and parameters",
            inputSchema: .object(
                properties: [
                    "latitude": .number(),
                    "longitude": .number(),
                    "latitudeDelta": .number(
                        description: "Latitude degrees visible on map"
                    ),
                    "longitudeDelta": .number(
                        description: "Longitude degrees visible on map"
                    ),
                    "width": .integer(
                        description: "Image width in pixels",
                        default: .int(Int(defaultMapImageSize.width))
                    ),
                    "height": .integer(
                        description: "Image height in pixels",
                        default: .int(Int(defaultMapImageSize.height))
                    ),
                    "mapType": .string(
                        description: "Map type",
                        default: "standard",
                        enum: ["standard", "satellite", "hybrid", "mutedStandard"]
                    ),
                    "showPointsOfInterest": .oneOf(
                        [
                            .boolean(
                                description: "Show all (true) or no (false) POIs",
                                default: false
                            ),
                            .array(
                                description: "Specific POI types to show",
                                items: .anyOf(
                                    MKPointOfInterestCategory.allCases.map {
                                        .string(const: .string($0.stringValue))
                                    }
                                ),
                                minItems: 1
                            ),
                        ]
                    ),
                    "showBuildings": .boolean(
                        description: "Whether to show buildings",
                        default: false
                    ),
                ],
                required: ["latitude", "longitude", "latitudeDelta", "longitudeDelta"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Generate Map Image",
                readOnlyHint: true,
                openWorldHint: true
            )
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

            let width = arguments["width"]?.intValue ?? Int(defaultMapImageSize.width)
            let height = arguments["height"]?.intValue ?? Int(defaultMapImageSize.height)
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
            case .bool(true), .string("true"):
                filter = .includingAll
            case .bool(false), .string("false"):
                filter = .excludingAll
            case let .string(string):
                do {
                    let jsonData = string.data(using: .utf8)!
                    let poiStrings = try JSONDecoder().decode([String].self, from: jsonData)
                    let categories = poiStrings.compactMap {
                        MKPointOfInterestCategory.from(string: $0)
                    }
                    filter = categories.isEmpty ? .excludingAll : .init(including: categories)
                } catch {
                    filter = .excludingAll
                }
            case let .array(poiTypes):
                let categories = poiTypes.compactMap { $0.stringValue }.compactMap {
                    MKPointOfInterestCategory.from(string: $0)
                }
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

                    continuation.resume(
                        returning: .data(mimeType: "image/png", pngData)
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
