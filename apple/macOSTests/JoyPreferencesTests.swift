import Foundation
import Testing

@Suite(.serialized) struct JoyPreferencesTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "JoyPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        defer {
            defaults.removePersistentDomain(forName: name)
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        }
        try body(defaults)
    }

    @Test func missingValuesDefaultToOn() throws {
        try withDefaults { defaults in
            for preference in JoyPreference.allCases {
                #expect(defaults.object(forKey: preference.key) == nil)
                #expect(JoyPreferences.isOn(preference, defaults: defaults))
            }
        }
    }

    @Test(arguments: [false, true])
    func storedBooleansAreHonored(value: Bool) throws {
        try withDefaults { defaults in
            defaults.set(value, forKey: JoyPreference.ghosts.key)
            #expect(JoyPreferences.isOn(.ghosts, defaults: defaults) == value)
        }
    }

    @Test(arguments: ["NO", "YES", "0", "1"])
    func argumentDomainStringsOverrideStoredBooleans(value: String) throws {
        try withDefaults { defaults in
            let expected = value == "YES" || value == "1"
            defaults.set(!expected, forKey: JoyPreference.ghosts.key)
            defaults.setVolatileDomain([JoyPreference.ghosts.key: value], forName: UserDefaults.argumentDomain)
            #expect(defaults.object(forKey: JoyPreference.ghosts.key) as? String == value)
            #expect(JoyPreferences.isOn(.ghosts, defaults: defaults) == expected)
        }
    }
}
