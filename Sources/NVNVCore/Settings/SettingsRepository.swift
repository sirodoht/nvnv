import Foundation

public actor SettingsRepository {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) { self.url = url }

    public func load() -> LibrarySettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? decoder.decode(LibrarySettings.self, from: data),
              (1...LibrarySettings().schemaVersion).contains(settings.schemaVersion) else {
            return LibrarySettings()
        }
        return settings
    }

    public func save(_ settings: LibrarySettings) throws {
        let data = try encoder.encode(settings)
        try data.write(to: url, options: [.atomic])
    }
}
