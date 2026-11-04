import XCTest
@testable import LipDictation

/// Runs on GitHub (macos-15, Xcode). Command Line Tools alone has no XCTest.
final class AppTests: XCTestCase {
    func testHoldKeysAreDistinct() {
        let codes = HoldKeyChoice.allCases.map(\.keyCode)
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertEqual(HoldKeyChoice.rightOption.keyCode, 61)
    }

    func testVersionOrdering() {
        XCTAssertTrue(Updater.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertFalse(Updater.isNewer("1.0.9", than: "1.0.9"))
        XCTAssertTrue(Updater.isNewer("1.0.1", than: "0.0.0"))
    }

    func testModelManifestIsComplete() {
        XCTAssertEqual(Installer.modelFiles.count, 5)
        XCTAssertTrue(Installer.modelFiles.allSatisfy { $0.sha256.count == 64 && $0.url.hasPrefix("https://") })
        XCTAssertGreaterThan(Installer.modelBytes, 1_200_000_000)
    }

    func testSHA256() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sha-test")
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try Installer.sha256(of: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testElapsed() {
        XCTAssertEqual(HUDPill.elapsed(65), "1:05")
    }

    func testLumaPacksRows() throws {
        var buf: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buf)
        let b = try XCTUnwrap(buf)
        CVPixelBufferLockBaseAddress(b, [])
        let base = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        for r in 0..<2 { for c in 0..<4 { base[r * stride + c] = UInt8(r * 10 + c) } }
        CVPixelBufferUnlockBaseAddress(b, [])
        let (w, h, data) = try XCTUnwrap(Camera.luma(b))
        XCTAssertEqual([w, h], [4, 2])
        XCTAssertEqual(Array(data), [0, 1, 2, 3, 10, 11, 12, 13])
    }
}
