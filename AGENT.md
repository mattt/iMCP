# Agent Guidelines for iMCP

## Build Commands
- Build: `xcodebuild -project iMCP.xcodeproj -scheme iMCP build`
- Build CLI: `xcodebuild -project iMCP.xcodeproj -scheme imcp-server build`
- Run app: `xcodebuild -project iMCP.xcodeproj -scheme iMCP run`
- Clean: `xcodebuild -project iMCP.xcodeproj clean`

## Code Style Guidelines

### Imports
- Group imports alphabetically within categories (Foundation, Apple frameworks, third-party)
- Use specific imports when possible (e.g., `import struct Foundation.Data`)

### Naming Conventions
- Use camelCase for variables and functions
- Use PascalCase for types and classes
- Prefer descriptive names (e.g., `CalendarService`, `eventStore`)
- Private functions use underscore prefix sparingly

### Types & Architecture
- Use `final class` for services that shouldn't be subclassed
- Use `static let shared` for singletons
- Prefer `async/await` over completion handlers
- Use computed properties for simple accessors

### Error Handling
- Use `throws` for recoverable errors
- Create descriptive NSError objects with localized descriptions
- Use `guard` statements for early returns
- Log errors using OSLog with appropriate levels

### Special Rules
- Ignore SourceKit warnings about missing types/modules (per .cursor/rules)
- Don't install new Swift packages - assume they exist
- Use OSLog for logging with service-specific loggers
- Follow Apple's sandboxing and permission patterns
