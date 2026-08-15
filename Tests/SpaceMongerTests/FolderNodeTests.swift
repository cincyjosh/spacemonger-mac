import XCTest
@testable import Spacemonger_Mac

final class FolderNodeTests: XCTestCase {
    func testAddChildAccumulatesSize() {
        let root = FolderNode(name: "root", size: 0, isDirectory: true)
        root.addChild(FolderNode(name: "a", size: 100, isDirectory: false))
        root.addChild(FolderNode(name: "b", size: 250, isDirectory: false))
        XCTAssertEqual(root.size, 350)
    }

    func testFinalizeSortsChildrenDescendingBySize() {
        let root = FolderNode(name: "root", size: 0, isDirectory: true)
        root.addChild(FolderNode(name: "small", size: 10, isDirectory: false))
        root.addChild(FolderNode(name: "big", size: 1000, isDirectory: false))
        root.addChild(FolderNode(name: "medium", size: 100, isDirectory: false))
        root.finalize()
        XCTAssertEqual(root.children.map(\.name), ["big", "medium", "small"])
    }

    func testRemoveFromParentSubtractsSizeUpTheChain() {
        let grandparent = FolderNode(name: "grandparent", size: 0, isDirectory: true)
        let parent = FolderNode(name: "parent", size: 0, isDirectory: true)
        let child = FolderNode(name: "child", size: 500, isDirectory: false)
        parent.addChild(child)
        grandparent.addChild(parent)

        XCTAssertEqual(grandparent.size, 500)
        child.removeFromParent()
        XCTAssertEqual(parent.size, 0)
        XCTAssertEqual(grandparent.size, 0)
        XCTAssertTrue(parent.children.isEmpty)
        XCTAssertNil(child.parent)
    }

    func testPathWalksFromRootToNode() {
        let root = FolderNode(name: "root", size: 0, isDirectory: true)
        let mid = FolderNode(name: "mid", size: 0, isDirectory: true)
        let leaf = FolderNode(name: "leaf", size: 1, isDirectory: false)
        mid.addChild(leaf)
        root.addChild(mid)
        XCTAssertEqual(leaf.path, ["root", "mid", "leaf"])
    }
}
