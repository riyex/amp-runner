public struct AmpUpdatePreferences: Codable, Equatable, Sendable {
    public var automaticallyChecksForUpdates: Bool
    public var sendsUpdateNotifications: Bool
    public var automaticallyInstallsUpdates: Bool
    public var restartsUpdatedRunnersWhenIdle: Bool

    public init(
        automaticallyChecksForUpdates: Bool = true,
        sendsUpdateNotifications: Bool = true,
        automaticallyInstallsUpdates: Bool = false,
        restartsUpdatedRunnersWhenIdle: Bool = false
    ) {
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.sendsUpdateNotifications = sendsUpdateNotifications
        self.automaticallyInstallsUpdates = automaticallyInstallsUpdates
        self.restartsUpdatedRunnersWhenIdle = restartsUpdatedRunnersWhenIdle
    }
}
