import Testing
@testable import Sieve

struct AppThemeTests {
    @Test func everyThemeRoundTrips() {
        for theme in AppTheme.allCases {
            #expect(AppTheme(rawValue: theme.rawValue) == theme)
            #expect(AppTheme.current(theme.rawValue) == theme)
        }
        #expect(AppTheme.current("nonsense") == .system)
        #expect(AppTheme.system.accent == nil)
        #expect(AppTheme.purple.accent != nil)
    }

    @Test func appearanceRoundTrips() {
        for a in AppAppearance.allCases {
            #expect(AppAppearance(rawValue: a.rawValue) == a)
        }
        #expect(AppAppearance.system.colorScheme == nil)
    }
}
