import CoreLocation
import Foundation
import Ontology
import OSLog
import WeatherKit

private let log = Logger.service("weather")

final class WeatherService: Service {
    static let shared = WeatherService()

    var tools: [Tool] {
        Tool(
            name: "getCurrentWeatherForLocation",
            description: "Get current weather for a location",
            inputSchema: [
                "type": "object",
                "properties": [
                    "latitude": [
                        "type": "number",
                        "description": "The latitude of the location",
                    ],
                    "longitude": [
                        "type": "number",
                        "description": "The longitude of the location",
                    ],
                ],
            ]
        ) { arguments in
            guard case let .double(latitude) = arguments["latitude"],
                case let .double(longitude) = arguments["longitude"]
            else {
                log.error("Invalid coordinates")
                throw NSError(
                    domain: "WeatherServiceError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid coordinates"]
                )
            }

            // Create a location from the coordinates
            let location = CLLocation(latitude: latitude, longitude: longitude)

            // Get the weather for the location
            let weatherService = WeatherKit.WeatherService.shared
            let currentWeather = try await weatherService.weather(
                for: location, including: .current)

            return WeatherConditions(currentWeather)
        }
    }
}
