public protocol VaultFinder: Sendable {
    func discoverVaults() -> [ObsidianVault]
}
