import UIKit
import XCTest
@testable import Strongroom

final class AppConfigTests: XCTestCase {
    func testAlternateIconsAreRegisteredAndPreviewsLoad() throws {
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
        for choice in AppIconPicker.choices {
            if let name = choice.id { XCTAssertNotNil(alternates[name], "\(name) missing from the built app") }
            XCTAssertNotNil(UIImage(named: choice.preview), "\(choice.preview) preview missing")
        }
    }

    func testPrivacyStringsAndCloudKitFlag() {
        for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSPhotoLibraryUsageDescription"] {
            XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: key), key)
        }
        XCTAssertTrue(CloudKitBackupStore.isConfigured)
    }
}
