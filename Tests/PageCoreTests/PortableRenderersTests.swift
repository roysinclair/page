import XCTest
@testable import PageCore

/// The pure-Swift QR encoder (used by `paged pair`) and the header-level
/// photo check (used off macOS). Both run on every platform.
final class QREncoderTests: XCTestCase {
    func testVersionGrowsWithTheData() throws {
        XCTAssertEqual(try XCTUnwrap(QREncoder.encode("a")).size, 21, "version 1")
        // A pairing payload (~160 bytes) at level M fits version 9 or 10.
        let payload = #"{"host":"build-box","relay":"https://page-relay.example.workers.dev","sk":"\#(String(repeating: "k", count: 43))","token":"\#(String(repeating: "t", count: 43))","v":1}"#
        let m = try XCTUnwrap(QREncoder.encode(payload))
        XCTAssertTrue((53...57).contains(m.size), "\(m.size)")
        XCTAssertNil(QREncoder.encode(String(repeating: "x", count: 3000)), "beyond version 40")
    }

    func testCapacityTable() {
        // ISO/IEC 18004 Table 7, byte mode data codewords.
        XCTAssertEqual(QREncoder.dataCodewords(version: 1, ecl: .medium), 16)
        XCTAssertEqual(QREncoder.dataCodewords(version: 10, ecl: .medium), 216)
        XCTAssertEqual(QREncoder.dataCodewords(version: 40, ecl: .low), 2956)
        XCTAssertEqual(QREncoder.dataCodewords(version: 40, ecl: .high), 1276)
    }

    func testFinderPatternsAndTiming() throws {
        let m = try XCTUnwrap(QREncoder.encode("page"))
        for (cx, cy) in [(3, 3), (m.size - 4, 3), (3, m.size - 4)] {
            XCTAssertTrue(m[x: cx, y: cy], "finder centre")
            XCTAssertFalse(m[x: cx + 2, y: cy], "finder ring gap")
            XCTAssertTrue(m[x: cx + 3, y: cy], "finder outer ring")
        }
        for i in 8..<(m.size - 8) { XCTAssertEqual(m[x: i, y: 6], i % 2 == 0, "timing row") }
        XCTAssertTrue(m[x: 8, y: m.size - 8], "the dark module")
    }

    func testTerminalAndPNGRendering() throws {
        let m = try XCTUnwrap(QREncoder.encode("page"))
        let plain = QRRender.terminal(m, quietZone: 2, ansi: false)
        let lines = plain.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        XCTAssertEqual(lines.count, (m.size + 4 + 1) / 2, "two rows a line")
        XCTAssertTrue(lines.allSatisfy { $0.count == m.size + 4 })
        XCTAssertTrue(QRRender.terminal(m, ansi: true).contains("\u{1B}[30;107m▀"), "black on white whatever the theme")
        let png = QRRender.png(m, scale: 2)
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // Our own PNG passes the header check, with the right size.
        let info = try XCTUnwrap(HeaderImageSniffer.parsePNG([UInt8](png)))
        XCTAssertEqual(info.width, (m.size + 8) * 2)
        XCTAssertEqual(QRRender.crc32(Data("IEND".utf8)), 0xAE42_6082)
    }
}

final class HeaderImageSnifferTests: XCTestCase {
    let sniffer = HeaderImageSniffer()

    func testCleanPhotosPass() {
        XCTAssertEqual(sniffer.check(TestImages.png()), .success(.png))
        XCTAssertEqual(sniffer.check(TestImages.jpeg()), .success(.jpeg))
        XCTAssertEqual(sniffer.check(TestImages.jpeg(mpfImages: 2)), .success(.jpeg), "an MPO with two pictures")
        XCTAssertEqual(sniffer.check(TestImages.png(frames: 3)), .success(.png), "a short APNG")
    }

    func testLocationIsRefusedWhereverItIs() {
        let refused = Result<ImageCheck.Kind, ImageCheck.Failure>.failure(.init(detail: ImageCheck.locationMessage))
        XCTAssertEqual(sniffer.check(TestImages.jpeg(gps: true)), refused, "Exif GPS IFD")
        XCTAssertEqual(sniffer.check(TestImages.png(gps: true)), refused, "PNG eXIf")
        XCTAssertEqual(sniffer.check(TestImages.png(xmpGPS: true)), refused, "XMP in iTXt")
    }

    func testBrokenOversizedAndForeignFilesAreRefused() {
        let unreadable = Result<ImageCheck.Kind, ImageCheck.Failure>.failure(.init(detail: ImageCheck.unreadableMessage))
        let png = TestImages.png()
        XCTAssertEqual(sniffer.check(png.prefix(40)), unreadable, "truncated")
        var corrupt = [UInt8](png)
        corrupt[20] ^= 0xFF // inside IHDR: its CRC no longer matches
        XCTAssertEqual(sniffer.check(Data(corrupt)), unreadable)
        let jpeg = TestImages.jpeg()
        XCTAssertEqual(sniffer.check(jpeg.dropLast(2)), unreadable, "no end of image")
        XCTAssertEqual(sniffer.check(TestImages.jpeg(mpfImages: 20)), unreadable, "too many pictures")
        XCTAssertEqual(sniffer.check(TestImages.png(width: 4097, height: 2)), .failure(.init(detail: ImageCheck.tooLargeMessage)))
        XCTAssertEqual(sniffer.check(TestImages.png(width: 7000, height: 7000)), .failure(.init(detail: ImageCheck.tooLargeMessage)))
        XCTAssertEqual(sniffer.check(Data("GIF89a".utf8) + Data(count: 20)), .failure(.init(detail: ImageCheck.notImageMessage)))
    }

    func testExifParsingBothByteOrders() {
        XCTAssertTrue(HeaderImageSniffer.exifHasGPS(TestImages.exif(gps: true)))
        XCTAssertFalse(HeaderImageSniffer.exifHasGPS(TestImages.exif(gps: false)))
        // Little endian, IFD0 with the GPS pointer.
        let le: [UInt8] = [0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0, 1, 0, 0x25, 0x88, 4, 0, 1, 0, 0, 0, 26, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertTrue(HeaderImageSniffer.exifHasGPS(le))
        XCTAssertFalse(HeaderImageSniffer.exifHasGPS([0x49, 0x49, 0x2A, 0x00, 0xFF, 0xFF, 0, 0]), "IFD past the end")
    }
}

final class PortableHelpersTests: XCTestCase {
    func testWholeStringMatchRejectsATrailingNewline() {
        XCTAssertTrue("%12".matchesEntirely(#"^%[0-9]+$"#))
        XCTAssertFalse("%12\n".matchesEntirely(#"^%[0-9]+$"#))
        XCTAssertFalse("x%12".matchesEntirely(#"%[0-9]+"#))
        XCTAssertFalse(TerminalFocus.isSafePane("%12\n"))
        XCTAssertFalse(TerminalFocus.isSafeTTY("/dev/ttys003\n"))
    }

    func testJSONBooleansAreToldFromNumbers() throws {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"b":true,"n":1,"z":0,"f":false}"#.utf8)) as? [String: Any])
        XCTAssertTrue((obj["b"] as? NSNumber)?.isJSONBool == true)
        XCTAssertTrue((obj["f"] as? NSNumber)?.isJSONBool == true)
        XCTAssertFalse((obj["n"] as? NSNumber)?.isJSONBool == true)
        XCTAssertFalse((obj["z"] as? NSNumber)?.isJSONBool == true)
    }

    func testTestsKnowTheyAreTests() {
        XCTAssertTrue(RuntimeEnvironment.isUnderXCTest)
    }
}
