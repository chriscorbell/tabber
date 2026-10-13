import CoreGraphics
import Foundation
import TabberCore
import Testing
@testable import TabberContext

@Suite struct ScreenContextProviderTests {
    private func snapshot(bundleID: String = "com.example.mail", pid: Int32 = 999_999, secure: Bool = false,
                          frame: CGRect? = CGRect(x: 100, y: 500, width: 600, height: 80)) -> FieldSnapshot {
        FieldSnapshot(
            app: AppIdentity(bundleID: bundleID, name: "Mail", pid: pid),
            field: FieldIdentity(pid: pid, elementHash: 42, role: "AXTextArea"),
            role: "AXTextArea",
            textBeforeCaret: "Hi",
            isSecure: secure,
            fieldFrame: frame
        )
    }

    @Test func neverCapturesSecureFieldsExcludedAppsOrItself() async {
        let provider = ScreenContextProvider()
        #expect(!provider.isEligible(snapshot(secure: true)))
        #expect(!provider.isEligible(snapshot(bundleID: "com.1password.1password")))
        #expect(!provider.isEligible(snapshot(bundleID: "com.apple.keychainaccess")))
        #expect(!provider.isEligible(snapshot(pid: ProcessInfo.processInfo.processIdentifier)))
        #expect(!provider.isEligible(snapshot(frame: nil)))
        #expect(await provider.screenText(for: snapshot(secure: true)) == nil)
    }

    @Test func excludedAppsAreConfigurable() {
        var config = ScreenContextProvider.Configuration()
        config.excludedBundleIDs.insert("com.example.mail")
        #expect(!ScreenContextProvider(configuration: config).isEligible(snapshot()))
    }
}
