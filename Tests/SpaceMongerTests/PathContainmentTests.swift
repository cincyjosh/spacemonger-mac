import XCTest
@testable import Spacemonger_Mac

final class PathContainmentTests: XCTestCase {
    func testChildPathIsContainedWithinParent() {
        XCTAssertTrue(PathContainment.isContained(["/", "Users", "josh", "Documents"], within: ["/", "Users", "josh"]))
    }

    func testRootItselfIsContainedWithinRoot() {
        XCTAssertTrue(PathContainment.isContained(["/", "Users", "josh"], within: ["/", "Users", "josh"]))
    }

    func testSiblingPathIsNotContained() {
        XCTAssertFalse(PathContainment.isContained(["/", "Users", "jane"], within: ["/", "Users", "josh"]))
    }

    /// The bug this exists to prevent: naively comparing via
    /// `path.hasPrefix(root + "/")` produces "//" for the volume root,
    /// rejecting every real child. Component-wise comparison must not have
    /// the same failure at the root.
    func testVolumeRootContainsItsChildren() {
        XCTAssertTrue(PathContainment.isContained(["/", "Applications"], within: ["/"]))
        XCTAssertTrue(PathContainment.isContained(["/", "Users", "josh"], within: ["/"]))
    }

    func testUnrelatedPathIsNotContained() {
        XCTAssertFalse(PathContainment.isContained(["/", "Volumes", "External"], within: ["/", "Users", "josh"]))
    }
}
