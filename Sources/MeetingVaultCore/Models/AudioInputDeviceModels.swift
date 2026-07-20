import Foundation

public struct AudioInputDevice: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var transportLabel: String
    public var isDefault: Bool
    public var isConnected: Bool
    public var level: Double

    public init(
        id: String,
        displayName: String,
        transportLabel: String,
        isDefault: Bool = false,
        isConnected: Bool = true,
        level: Double = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.transportLabel = transportLabel
        self.isDefault = isDefault
        self.isConnected = isConnected
        self.level = level
    }
}
