import Foundation

/// ImageCheck's rules without ImageIO: the photo's own structure is parsed
/// (PNG chunks with their CRCs, JPEG segments), its size is read from the
/// header, and any location data refuses it. Used off macOS.
///
/// What it does not do, unlike ImageIO on the Mac: decode the pixels. A file
/// whose header and structure are sound but whose compressed pixel data is
/// damaged passes here; Claude Code decodes the image itself and reports it.
/// Everything that protects the user (type by magic bytes, size bounds, no
/// GPS, private 0600 storage) applies unchanged.
struct HeaderImageSniffer: ImageSniffer {
    func check(_ data: Data) -> Result<ImageCheck.Kind, ImageCheck.Failure> {
        guard let kind = ImageCheck.sniff(data) else { return .failure(.init(detail: ImageCheck.notImageMessage)) }
        let bytes = [UInt8](data)
        let parsed = kind == .png ? Self.parsePNG(bytes) : Self.parseJPEG(bytes)
        guard let info = parsed, info.width > 0, info.height > 0, info.frames >= 1,
              info.frames <= ImageCheck.maxFrames else {
            return .failure(.init(detail: ImageCheck.unreadableMessage))
        }
        if info.hasLocation { return .failure(.init(detail: ImageCheck.locationMessage)) }
        guard max(info.width, info.height) <= ImageCheck.maxEdge, info.width * info.height <= ImageCheck.maxPixels else {
            return .failure(.init(detail: ImageCheck.tooLargeMessage))
        }
        return .success(kind)
    }

    struct Info: Equatable {
        var width = 0
        var height = 0
        var frames = 1
        var hasLocation = false
    }

    // MARK: PNG

    /// Pure. Every chunk's CRC must match; IHDR first, at least one IDAT, IEND last.
    static func parsePNG(_ b: [UInt8]) -> Info? {
        guard b.count >= 8 + 12 else { return nil }
        var info = Info()
        var i = 8
        var sawIHDR = false, sawIDAT = false, sawIEND = false
        while i + 12 <= b.count {
            let len = Int(be32(b, i))
            guard len <= b.count, i + 12 + len <= b.count else { return nil }
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            let body = Array(b[(i + 8)..<(i + 8 + len)])
            let crc = be32(b, i + 8 + len)
            guard QRRender.crc32(Data(b[(i + 4)..<(i + 8 + len)])) == crc else { return nil }
            if !sawIHDR {
                guard type == "IHDR", len == 13 else { return nil }
                sawIHDR = true
                info.width = Int(be32(body, 0))
                info.height = Int(be32(body, 4))
            }
            switch type {
            case "IDAT": sawIDAT = true
            case "acTL" where len >= 8: info.frames = max(1, Int(be32(body, 0)))
            case "eXIf": if exifHasGPS(body) { info.hasLocation = true }
            case "iTXt", "tEXt", "zTXt":
                if xmpHasLocation(body) { info.hasLocation = true }
            case "IEND": sawIEND = true
            default: break
            }
            i += 12 + len
            if sawIEND { break }
        }
        guard sawIHDR, sawIDAT, sawIEND else { return nil }
        return info
    }

    // MARK: JPEG

    /// Pure. Walks the segments to the start of scan; needs a frame header,
    /// and an end-of-image marker after the scan.
    static func parseJPEG(_ b: [UInt8]) -> Info? {
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var info = Info()
        var sawFrame = false
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            var marker = b[i + 1]
            var j = i + 1
            while marker == 0xFF, j + 1 < b.count { j += 1; marker = b[j] } // fill bytes
            i = j + 1
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
            if marker == 0xD9 { return nil } // end before any scan
            guard i + 2 <= b.count else { return nil }
            let len = Int(b[i]) << 8 | Int(b[i + 1])
            guard len >= 2, i + len <= b.count else { return nil }
            let body = Array(b[(i + 2)..<(i + len)])
            switch marker {
            case 0xC0...0xCF where marker != 0xC4 && marker != 0xC8 && marker != 0xCC:
                guard body.count >= 5 else { return nil }
                info.height = Int(body[1]) << 8 | Int(body[2])
                info.width = Int(body[3]) << 8 | Int(body[4])
                sawFrame = true
            case 0xE1:
                if body.starts(with: Array("Exif\0\0".utf8)), exifHasGPS(Array(body.dropFirst(6))) { info.hasLocation = true }
                if body.starts(with: Array("http://ns.adobe.com/xap/1.0/".utf8)), xmpHasLocation(body) { info.hasLocation = true }
                if body.starts(with: Array("http://ns.adobe.com/xmp/extension/".utf8)), xmpHasLocation(body) { info.hasLocation = true }
            case 0xE2:
                if body.starts(with: Array("MPF\0".utf8)), let n = mpfImageCount(Array(body.dropFirst(4))) {
                    info.frames = max(1, n)
                }
            case 0xDA:
                guard sawFrame else { return nil }
                // The entropy-coded scan follows; the file must end the image.
                let rest = b[(i + len)...]
                guard rest.count >= 2 else { return nil }
                var k = rest.endIndex - 1
                // Tolerate trailing padding after EOI (some encoders add zeros).
                while k > rest.startIndex, b[k] == 0x00 { k -= 1 }
                guard k > rest.startIndex, b[k - 1] == 0xFF, b[k] == 0xD9 else { return nil }
                return info
            default: break
            }
            i += len
        }
        return nil
    }

    // MARK: metadata

    /// Pure. A TIFF (Exif) block whose IFD0 points at a GPS IFD (tag 0x8825).
    static func exifHasGPS(_ t: [UInt8]) -> Bool {
        guard t.count >= 8 else { return false }
        let little: Bool
        switch (t[0], t[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return false
        }
        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= t.count else { return nil }
            return little ? Int(t[o]) | Int(t[o + 1]) << 8 : Int(t[o]) << 8 | Int(t[o + 1])
        }
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= t.count else { return nil }
            let v = little
                ? UInt32(t[o]) | UInt32(t[o + 1]) << 8 | UInt32(t[o + 2]) << 16 | UInt32(t[o + 3]) << 24
                : UInt32(t[o]) << 24 | UInt32(t[o + 1]) << 16 | UInt32(t[o + 2]) << 8 | UInt32(t[o + 3])
            return Int(v)
        }
        guard let ifd0 = u32(4), let count = u16(ifd0), count < 1000 else { return false }
        for e in 0..<count {
            guard let tag = u16(ifd0 + 2 + e * 12) else { return false }
            if tag == 0x8825 { return true }
        }
        return false
    }

    /// Pure. XMP (or a PNG text chunk carrying it) that names a GPS position.
    static func xmpHasLocation(_ body: [UInt8]) -> Bool {
        let text = String(decoding: body, as: UTF8.self)
        return text.contains("GPSLatitude") || text.contains("GPSLongitude")
    }

    /// Pure. NumberOfImages (tag 0xB001) from a CIPA MP Index IFD.
    static func mpfImageCount(_ t: [UInt8]) -> Int? {
        guard t.count >= 8 else { return nil }
        let little = t[0] == 0x49
        func u16(_ o: Int) -> Int? {
            guard o + 2 <= t.count else { return nil }
            return little ? Int(t[o]) | Int(t[o + 1]) << 8 : Int(t[o]) << 8 | Int(t[o + 1])
        }
        func u32(_ o: Int) -> Int? {
            guard o + 4 <= t.count else { return nil }
            return little
                ? Int(t[o]) | Int(t[o + 1]) << 8 | Int(t[o + 2]) << 16 | Int(t[o + 3]) << 24
                : Int(t[o]) << 24 | Int(t[o + 1]) << 16 | Int(t[o + 2]) << 8 | Int(t[o + 3])
        }
        guard let ifd = u32(4), let count = u16(ifd), count < 1000 else { return nil }
        for e in 0..<count {
            let o = ifd + 2 + e * 12
            guard let tag = u16(o) else { return nil }
            if tag == 0xB001 { return u32(o + 8) }
        }
        return nil
    }

    private static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        return UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
}
