import XCTest
@testable import TrackerProtocol

final class SmokeTests: XCTestCase {
    func testSchemaResourceBundled() {
        XCTAssertNotNil(TrackerProtocolInfo.schemaResourceURL(),
                        "tracker_protocol.json must be bundled in the TrackerProtocol target")
    }
}
