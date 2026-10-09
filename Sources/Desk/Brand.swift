/// Product naming in one place. `scripts/brand.env` holds the same name and bundle id for packaging.
enum Brand {
    static let name = "irori"
    static let repository = "https://github.com/tofuchick3n/irori"
    static let takibiSite = "https://takibibase.com"
    static let slug = "irori"
    /// The Application Support folder. Kept separate from `name` so a rename doesn't strand
    /// existing threads; add the old folder to `LegacyData` when changing it.
    static let supportFolder = "Irori"
}
