import XCTest
import CoreGraphics
@testable import Spacemonger_Mac

final class TreemapLayoutTests: XCTestCase {
    func testEmptyFolderProducesNoRects() {
        let root = FolderNode(name: "root", size: 0, isDirectory: true)
        let rects = TreemapLayout.layout(root: root, in: CGRect(x: 0, y: 0, width: 200, height: 200),
                                          settings: LayoutSettings())
        XCTAssertTrue(rects.isEmpty)
    }

    func testSingleChildFillsEntireRect() {
        let root = FolderNode(name: "root", size: 0, isDirectory: true)
        root.addChild(FolderNode(name: "only", size: 100, isDirectory: false))
        root.finalize()

        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let rects = TreemapLayout.layout(root: root, in: bounds, settings: LayoutSettings())

        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].rect, bounds)
        XCTAssertTrue(rects[0].isSingleItem)
    }

    func testChildrenSplitProportionallyToSize() {
        let root = FolderNode(name: "root", size: 0, isDirectory: true)
        root.addChild(FolderNode(name: "big", size: 300, isDirectory: false))
        root.addChild(FolderNode(name: "small", size: 100, isDirectory: false))
        root.finalize()

        let bounds = CGRect(x: 0, y: 0, width: 400, height: 100)
        let rects = TreemapLayout.layout(root: root, in: bounds, settings: LayoutSettings())

        XCTAssertEqual(rects.count, 2)
        let totalArea = rects.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }
        XCTAssertEqual(totalArea, bounds.width * bounds.height, accuracy: 0.01)

        let bigRect = rects.first { $0.node.name == "big" }
        let smallRect = rects.first { $0.node.name == "small" }
        XCTAssertNotNil(bigRect)
        XCTAssertNotNil(smallRect)
        // "big" is 3x the size of "small", so its area should be roughly 3x too.
        if let bigRect, let smallRect {
            let bigArea = bigRect.rect.width * bigRect.rect.height
            let smallArea = smallRect.rect.width * smallRect.rect.height
            XCTAssertEqual(bigArea / smallArea, 3.0, accuracy: 0.1)
        }
    }

    func testTinyBoxesAggregateRatherThanMisidentifyASingleSibling() {
        let root = FolderNode(name: "root", size: 0, isDirectory: true)
        for i in 0..<5 {
            root.addChild(FolderNode(name: "file\(i)", size: 1, isDirectory: false))
        }
        root.finalize()

        // A box far too small to subdivide five 1-byte files individually.
        // The recursive split still happens before each half's size is
        // checked, so this can produce more than one collapsed box rather
        // than a single one — what matters is that every box's
        // representedCount/representedSize accounts for everyone it covers,
        // and nothing claims to be a single identified item when it isn't.
        let bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
        let rects = TreemapLayout.layout(root: root, in: bounds, settings: LayoutSettings())

        XCTAssertFalse(rects.isEmpty)
        XCTAssertEqual(rects.reduce(0) { $0 + $1.representedCount }, 5)
        XCTAssertEqual(rects.reduce(UInt64(0)) { $0 + $1.representedSize }, 5)
        for rect in rects {
            XCTAssertEqual(rect.isSingleItem, rect.representedCount == 1)
            if rect.representedCount > 1 {
                XCTAssertFalse(rect.isSingleItem, "a box covering multiple siblings must not claim to be a single item")
            }
        }
    }

    func testFreeSpaceExcludedFromSplitWhenToggledOff() {
        let root = FolderNode(name: "root", size: 0, isDirectory: true)
        root.addChild(FolderNode(name: "used", size: 100, isDirectory: false))
        root.addChild(FolderNode(name: "Free Space", size: 900, isDirectory: false, isFreeSpaceMarker: true))
        root.finalize()

        var settings = LayoutSettings()
        settings.showFreeSpace = false
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let rects = TreemapLayout.layout(root: root, in: bounds, settings: settings)

        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].node.name, "used")
        XCTAssertEqual(rects[0].rect, bounds)
    }
}
