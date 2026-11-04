import Foundation
@testable import PageCore

/// Image files built byte by byte, for the header-level checker
/// (`HeaderImageSniffer`) and for the photo tests where ImageIO isn't there.
/// Structure is real (chunks with CRCs, JPEG segments, Exif); pixels are not
/// meant to decode.
enum TestImages {
    /// A TIFF (Exif) block whose IFD0 has one entry; `gps` makes it the GPS IFD pointer.
    static func exif(gps: Bool) -> [UInt8] {
        var t: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8] // big endian, IFD0 at 8
        t += [0x00, 0x01] // one entry
        t += gps ? [0x88, 0x25] : [0x01, 0x12] // GPS IFD pointer, or Orientation
        t += [0x00, 0x04, 0, 0, 0, 1, 0, 0, 0, 26] // LONG, count 1, value
        t += [0, 0, 0, 0] // no next IFD
        return t
    }

    static func png(width: Int = 16, height: Int = 16, gps: Bool = false, frames: Int = 1, xmpGPS: Bool = false) -> Data {
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            return be32(body.count) + typed + be32(Int(QRRender.crc32(Data(typed))))
        }
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        out += chunk("IHDR", be32(width) + be32(height) + [8, 0, 0, 0, 0])
        if frames > 1 { out += chunk("acTL", be32(frames) + be32(0)) }
        if gps { out += chunk("eXIf", exif(gps: true)) }
        if xmpGPS { out += chunk("iTXt", Array("XML:com.adobe.xmp\0\0\0\0\0<x:xmpmeta><exif:GPSLatitude>51,30N</exif:GPSLatitude></x:xmpmeta>".utf8)) }
        let rows = [UInt8](repeating: 0, count: min(height, 4) * (width + 1))
        out += chunk("IDAT", [UInt8](QRRender.zlibStored(rows)))
        out += chunk("IEND", [])
        return Data(out)
    }

    static func jpeg(width: Int = 16, height: Int = 16, gps: Bool = false, mpfImages: Int? = nil) -> Data {
        var out: [UInt8] = [0xFF, 0xD8]
        func segment(_ marker: UInt8, _ body: [UInt8]) -> [UInt8] {
            [0xFF, marker] + be16(body.count + 2) + body
        }
        out += segment(0xE0, Array("JFIF\0".utf8) + [1, 1, 0, 0, 1, 0, 1, 0, 0])
        out += segment(0xE1, Array("Exif\0\0".utf8) + exif(gps: gps))
        if let n = mpfImages {
            // MP Index IFD: version entry is skipped by the parser; NumberOfImages (0xB001).
            let ifd: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8, 0x00, 0x01,
                                0xB0, 0x01, 0x00, 0x04, 0, 0, 0, 1] + be32(n) + [0, 0, 0, 0]
            out += segment(0xE2, Array("MPF\0".utf8) + ifd)
        }
        out += segment(0xDB, [0x00] + [UInt8](repeating: 1, count: 64))
        out += segment(0xC0, [8] + be16(height) + be16(width) + [3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0])
        out += segment(0xC4, [0x00] + [UInt8](repeating: 0, count: 16))
        out += segment(0xDA, [3, 1, 0x00, 2, 0x00, 3, 0x00, 0, 63, 0])
        out += [0x12, 0x34, 0xFF, 0x00, 0x56] // entropy-coded bytes (FF stuffed)
        out += [0xFF, 0xD9]
        return Data(out)
    }

    private static func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
}
