import CoreLocation
import Foundation
import OSLog
import Ontology
import WeatherKit

private let log = Logger.service("weather")

final class WeatherService: Service {
    static let shared = WeatherService()

    private let weatherService = WeatherKit.WeatherService.shared

    var tools: [Tool] {
        Tool(
            name: "getCurrentWeatherForLocation",
            description:
                "Get current weather for a location, including temperature, conditions, humidity, and wind speed",
            inputSchema: .object(
                properties: [
                    "latitude": .number(
                        description: "The latitude of the location"
                    ),
                    "longitude": .number(
                        description: "The longitude of the location"
                    ),
                ],
                additionalProperties: false
            )
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

            let location = CLLocation(latitude: latitude, longitude: longitude)
            let currentWeather = try await self.weatherService.weather(
                for: location, including: .current)

            return WeatherConditions(currentWeather)
        }

        Tool(
            name: "getHourlyForecastForLocation",
            description: "Get hourly weather forecast for a location",
            inputSchema: .object(
                properties: [
                    "latitude": .number(
                        description: "The latitude of the location"
                    ),
                    "longitude": .number(
                        description: "The longitude of the location"
                    ),
                    "hours": .integer(
                        description: "Number of hours to forecast",
                        default: 24,
                        minimum: 1,
                        maximum: 240
                    ),
                ],
                additionalProperties: false
            )
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

            let hours: Int
            switch arguments["hours"] {
            case let .int(hoursRequested):
                hours = min(240, max(1, hoursRequested))
            case let .double(hoursRequested):
                hours = Int(min(240, max(1, hoursRequested)))
            default:
                hours = 24
            }

            let location = CLLocation(latitude: latitude, longitude: longitude)
            let hourlyForecasts = try await self.weatherService.weather(
                for: location, including: .hourly)

            return hourlyForecasts.prefix(hours).map { WeatherForecast($0) }
        }

        Tool(
            name: "getDailyForecastForLocation",
            description: "Get daily weather forecast for a location",
            inputSchema: .object(
                properties: [
                    "latitude": .number(
                        description: "The latitude of the location"
                    ),
                    "longitude": .number(
                        description: "The longitude of the location"
                    ),
                    "days": .integer(
                        description: "Number of days to forecast (default 7, max 10)",
                        default: 7,
                        minimum: 1,
                        maximum: 10
                    ),
                ],
                additionalProperties: false
            )
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

            var days: Int = 7
            if case let .int(daysRequested) = arguments["days"] {
                days = daysRequested
            } else if case let .double(daysRequested) = arguments["days"] {
                days = Int(daysRequested)
            }
            days = days.clamped(to: 1...10)

            let location = CLLocation(latitude: latitude, longitude: longitude)
            let dailyForecast = try await self.weatherService.weather(
                for: location, including: .daily)

            return dailyForecast.prefix(days).map { WeatherForecast($0) }
        }

        Tool(
            name: "getMinuteByMinuteForecastForLocation",
            description: "Get minute-by-minute weather forecast for a location",
            inputSchema: .object(
                properties: [
                    "latitude": .number(
                        description: "The latitude of the location"
                    ),
                    "longitude": .number(
                        description: "The longitude of the location"
                    ),
                    "minutes": .integer(
                        description: "Number of minutes to forecast (default 60)",
                        default: 60,
                        minimum: 1,
                        maximum: 120
                    ),
                ],
                additionalProperties: false
            )
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

            var minutes: Int = 60
            if case let .int(minutesRequested) = arguments["minutes"] {
                minutes = minutesRequested
            } else if case let .double(minutesRequested) = arguments["minutes"] {
                minutes = Int(minutesRequested)
            }
            minutes = minutes.clamped(to: 1...120)

            let location = CLLocation(latitude: latitude, longitude: longitude)
            guard
                let minuteByMinuteForecast = try await self.weatherService.weather(
                    for: location, including: .minute)
            else {
                throw NSError(
                    domain: "WeatherServiceError", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No minute-by-minute forecast available"]
                )
            }

            return minuteByMinuteForecast.prefix(minutes).map { WeatherForecast($0) }
        }
    }
}

extension Int {
    fileprivate func clamped(to range: ClosedRange<Int>) -> Int {
        return Swift.max(range.lowerBound, Swift.min(self, range.upperBound))
    }
}
