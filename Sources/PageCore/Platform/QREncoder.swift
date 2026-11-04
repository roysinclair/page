import Foundation

/// A QR code's modules: `size` × `size`, true = dark. Row-major.
struct QRMatrix: Equatable {
    let size: Int
    var modules: [Bool]

    init(size: Int) {
        self.size = size
        modules = Array(repeating: false, count: size * size)
    }

    /// x is the column, y the row.
    subscript(x x: Int, y y: Int) -> Bool {
        get { modules[y * size + x] }
        set { modules[y * size + x] = newValue }
    }
}

/// A QR Code Model 2 encoder (ISO/IEC 18004), byte mode, versions 1–40. Pure
/// Swift so the pairing code can be drawn where CoreImage doesn't exist.
/// Error correction defaults to M, what the Mac app's CIQRCodeGenerator uses.
enum QREncoder {
    enum ErrorCorrection: Int {
        case low = 0, medium, quartile, high
        /// The two format bits.
        var formatBits: Int {
            switch self {
            case .low: return 1
            case .medium: return 0
            case .quartile: return 3
            case .high: return 2
            }
        }
    }

    static func encode(_ text: String, errorCorrection ecl: ErrorCorrection = .medium) -> QRMatrix? {
        encode(bytes: Array(text.utf8), errorCorrection: ecl)
    }

    static func encode(bytes: [UInt8], errorCorrection ecl: ErrorCorrection = .medium) -> QRMatrix? {
        // The smallest version that holds the data.
        var version = 0
        for v in 1...40 {
            let countBits = v <= 9 ? 8 : 16
            guard bytes.count < (1 << countBits) else { continue }
            let needed = 4 + countBits + bytes.count * 8
            if needed <= dataCodewords(version: v, ecl: ecl) * 8 { version = v; break }
        }
        guard version > 0 else { return nil }

        // Data bits: byte mode, count, the bytes, terminator, padding.
        var bits = BitBuffer()
        bits.append(0b0100, count: 4)
        bits.append(bytes.count, count: version <= 9 ? 8 : 16)
        for b in bytes { bits.append(Int(b), count: 8) }
        let capacity = dataCodewords(version: version, ecl: ecl) * 8
        bits.append(0, count: min(4, capacity - bits.count))
        bits.append(0, count: (8 - bits.count % 8) % 8)
        var pad = 0xEC
        while bits.count < capacity {
            bits.append(pad, count: 8)
            pad ^= 0xEC ^ 0x11
        }
        let codewords = addErrorCorrection(bits.bytes, version: version, ecl: ecl)

        var grid = Grid(version: version)
        grid.drawFunctionPatterns()
        grid.drawCodewords(codewords)
        var best = 0
        var bestScore = Int.max
        for mask in 0..<8 {
            var trial = grid
            trial.applyMask(mask)
            trial.drawFormatBits(ecl: ecl, mask: mask)
            let score = trial.penalty()
            if score < bestScore { bestScore = score; best = mask }
        }
        grid.applyMask(best)
        grid.drawFormatBits(ecl: ecl, mask: best)
        return grid.matrix
    }

    // MARK: tables (ISO/IEC 18004 Table 9), index 0 unused

    private static let eccCodewordsPerBlock: [[Int]] = [
        [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
        [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    ]
    private static let errorCorrectionBlocks: [[Int]] = [
        [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
        [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
        [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
        [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
    ]

    /// Data and error-correction modules, without function patterns or format/version info.
    static func rawDataModules(version v: Int) -> Int {
        var result = (16 * v + 128) * v + 64
        if v >= 2 {
            let align = v / 7 + 2
            result -= (25 * align - 10) * align - 55
            if v >= 7 { result -= 36 }
        }
        return result
    }

    static func dataCodewords(version v: Int, ecl: ErrorCorrection) -> Int {
        rawDataModules(version: v) / 8
            - eccCodewordsPerBlock[ecl.rawValue][v] * errorCorrectionBlocks[ecl.rawValue][v]
    }

    // MARK: Reed–Solomon over GF(2^8), polynomial 0x11D

    private static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for i in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((Int(y) >> i) & 1) * Int(x)
        }
        return UInt8(z & 0xFF)
    }

    private static func divisor(degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for j in 0..<degree {
                result[j] = multiply(result[j], root)
                if j + 1 < degree { result[j] ^= result[j + 1] }
            }
            root = multiply(root, 0x02)
        }
        return result
    }

    private static func remainder(_ data: [UInt8], _ divisor: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: divisor.count)
        for b in data {
            let factor = b ^ result.removeFirst()
            result.append(0)
            for i in 0..<result.count { result[i] ^= multiply(divisor[i], factor) }
        }
        return result
    }

    /// Splits the data into blocks, appends each block's ECC, interleaves.
    static func addErrorCorrection(_ data: [UInt8], version v: Int, ecl: ErrorCorrection) -> [UInt8] {
        let blocks = errorCorrectionBlocks[ecl.rawValue][v]
        let eccLen = eccCodewordsPerBlock[ecl.rawValue][v]
        let raw = rawDataModules(version: v) / 8
        let shortBlocks = blocks - raw % blocks
        let shortLen = raw / blocks
        let div = divisor(degree: eccLen)
        var all: [[UInt8]] = []
        var k = 0
        for i in 0..<blocks {
            let dataLen = shortLen - eccLen + (i < shortBlocks ? 0 : 1)
            var block = Array(data[k..<k + dataLen])
            k += dataLen
            let ecc = remainder(block, div)
            if i < shortBlocks { block.append(0) }
            all.append(block + ecc)
        }
        var result: [UInt8] = []
        for i in 0..<all[0].count {
            for (j, block) in all.enumerated() where i != shortLen - eccLen || j >= shortBlocks {
                result.append(block[i])
            }
        }
        return result
    }

    // MARK: bits

    struct BitBuffer {
        private(set) var bits: [Bool] = []
        var count: Int { bits.count }
        mutating func append(_ value: Int, count: Int) {
            guard count > 0 else { return }
            for i in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> i) & 1 == 1) }
        }
        var bytes: [UInt8] {
            stride(from: 0, to: bits.count, by: 8).map { start in
                var b: UInt8 = 0
                for i in 0..<8 where start + i < bits.count && bits[start + i] { b |= 0x80 >> UInt8(i) }
                return b
            }
        }
    }

    // MARK: the grid

    struct Grid {
        let version: Int
        let size: Int
        var matrix: QRMatrix
        var isFunction: [Bool]

        init(version: Int) {
            self.version = version
            size = version * 4 + 17
            matrix = QRMatrix(size: size)
            isFunction = Array(repeating: false, count: size * size)
        }

        mutating func set(_ x: Int, _ y: Int, _ dark: Bool) {
            matrix[x: x, y: y] = dark
            isFunction[y * size + x] = true
        }

        func alignmentPositions() -> [Int] {
            guard version > 1 else { return [] }
            let count = version / 7 + 2
            let step = version == 32 ? 26 : (version * 4 + count * 2 + 1) / (count * 2 - 2) * 2
            var result = [6]
            var pos = size - 7
            for _ in 0..<(count - 1) {
                result.insert(pos, at: 1)
                pos -= step
            }
            return result
        }

        mutating func drawFunctionPatterns() {
            for i in 0..<size {
                set(6, i, i % 2 == 0)
                set(i, 6, i % 2 == 0)
            }
            for (cx, cy) in [(3, 3), (size - 4, 3), (3, size - 4)] {
                for dy in -4...4 {
                    for dx in -4...4 {
                        let x = cx + dx, y = cy + dy
                        guard x >= 0, x < size, y >= 0, y < size else { continue }
                        let d = max(abs(dx), abs(dy))
                        set(x, y, d != 2 && d != 4)
                    }
                }
            }
            let align = alignmentPositions()
            for (i, ax) in align.enumerated() {
                for (j, ay) in align.enumerated() {
                    let corner = (i == 0 && j == 0) || (i == 0 && j == align.count - 1) || (i == align.count - 1 && j == 0)
                    if corner { continue }
                    for dy in -2...2 {
                        for dx in -2...2 { set(ax + dx, ay + dy, max(abs(dx), abs(dy)) != 1) }
                    }
                }
            }
            drawFormatBits(ecl: .medium, mask: 0) // reserves the area; redrawn later
            if version >= 7 {
                var rem = version
                for _ in 0..<12 { rem = (rem << 1) ^ ((rem >> 11) * 0x1F25) }
                let bits = version << 12 | rem
                for i in 0..<18 {
                    let dark = (bits >> i) & 1 == 1
                    let a = size - 11 + i % 3, b = i / 3
                    set(a, b, dark)
                    set(b, a, dark)
                }
            }
        }

        mutating func drawFormatBits(ecl: ErrorCorrection, mask: Int) {
            let data = ecl.formatBits << 3 | mask
            var rem = data
            for _ in 0..<10 { rem = (rem << 1) ^ ((rem >> 9) * 0x537) }
            let bits = (data << 10 | rem) ^ 0x5412
            func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }
            for i in 0...5 { set(8, i, bit(i)) }
            set(8, 7, bit(6))
            set(8, 8, bit(7))
            set(7, 8, bit(8))
            for i in 9..<15 { set(14 - i, 8, bit(i)) }
            for i in 0..<8 { set(size - 1 - i, 8, bit(i)) }
            for i in 8..<15 { set(8, size - 15 + i, bit(i)) }
            set(8, size - 8, true)
        }

        mutating func drawCodewords(_ data: [UInt8]) {
            var i = 0
            var right = size - 1
            while right >= 1 {
                if right == 6 { right = 5 }
                for vert in 0..<size {
                    for j in 0..<2 {
                        let x = right - j
                        let upward = (right + 1) & 2 == 0
                        let y = upward ? size - 1 - vert : vert
                        if !isFunction[y * size + x] && i < data.count * 8 {
                            matrix[x: x, y: y] = (data[i >> 3] >> (7 - UInt8(i & 7))) & 1 == 1
                            i += 1
                        }
                    }
                }
                right -= 2
            }
        }

        mutating func applyMask(_ mask: Int) {
            for y in 0..<size {
                for x in 0..<size where !isFunction[y * size + x] {
                    let invert: Bool
                    switch mask {
                    case 0: invert = (x + y) % 2 == 0
                    case 1: invert = y % 2 == 0
                    case 2: invert = x % 3 == 0
                    case 3: invert = (x + y) % 3 == 0
                    case 4: invert = (x / 3 + y / 2) % 2 == 0
                    case 5: invert = x * y % 2 + x * y % 3 == 0
                    case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0
                    default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
                    }
                    if invert { matrix[x: x, y: y].toggle() }
                }
            }
        }

        /// The standard's four penalty rules (N1 runs, N2 blocks, N3
        /// finder-like patterns, N4 balance). Lower is better.
        func penalty() -> Int {
            var score = 0
            let m = matrix
            func line(_ i: Int, horizontal: Bool) -> [Bool] {
                (0..<size).map { horizontal ? m[x: $0, y: i] : m[x: i, y: $0] }
            }
            let finderA: [Bool] = [true, false, true, true, true, false, true, false, false, false, false]
            let finderB: [Bool] = Array(finderA.reversed())
            for i in 0..<size {
                for horizontal in [true, false] {
                    let l = line(i, horizontal: horizontal)
                    var run = 1
                    for k in 1..<size {
                        if l[k] == l[k - 1] {
                            run += 1
                        } else {
                            if run >= 5 { score += 3 + run - 5 }
                            run = 1
                        }
                    }
                    if run >= 5 { score += 3 + run - 5 }
                    if size >= 11 {
                        for k in 0...(size - 11) {
                            let slice = Array(l[k..<k + 11])
                            if slice == finderA || slice == finderB { score += 40 }
                        }
                    }
                }
            }
            for y in 0..<(size - 1) {
                for x in 0..<(size - 1) {
                    let c = m[x: x, y: y]
                    if c == m[x: x + 1, y: y] && c == m[x: x, y: y + 1] && c == m[x: x + 1, y: y + 1] { score += 3 }
                }
            }
            let dark = m.modules.filter { $0 }.count
            let total = size * size
            let k = (abs(dark * 20 - total * 10) + total - 1) / total - 1
            score += max(0, k) * 10
            return score
        }
    }
}

// MARK: - drawing

enum QRRender {
    /// The code in a terminal, two rows per line with Unicode half blocks.
    /// `ansi`: paint black on white with SGR colours, which reads on any
    /// terminal theme. Plain: dark modules are drawn (suits a light background).
    static func terminal(_ m: QRMatrix, quietZone: Int = 2, ansi: Bool) -> String {
        let n = m.size + quietZone * 2
        func dark(_ x: Int, _ y: Int) -> Bool {
            let mx = x - quietZone, my = y - quietZone
            guard mx >= 0, my >= 0, mx < m.size, my < m.size else { return false }
            return m[x: mx, y: my]
        }
        var out = ""
        for y in stride(from: 0, to: n, by: 2) {
            for x in 0..<n {
                let top = dark(x, y)
                let bottom = y + 1 < n ? dark(x, y + 1) : false
                if ansi {
                    out += "\u{1B}[\(top ? 30 : 97);\(bottom ? 40 : 107)m▀"
                } else {
                    switch (top, bottom) {
                    case (true, true): out += "█"
                    case (true, false): out += "▀"
                    case (false, true): out += "▄"
                    case (false, false): out += " "
                    }
                }
            }
            out += ansi ? "\u{1B}[0m\n" : "\n"
        }
        return out
    }

    /// A greyscale PNG, `scale` pixels per module, 4-module quiet zone.
    static func png(_ m: QRMatrix, scale: Int = 8, quietZone: Int = 4) -> Data {
        let side = (m.size + quietZone * 2) * scale
        var raw = [UInt8]()
        raw.reserveCapacity((side + 1) * side)
        for py in 0..<side {
            raw.append(0) // filter: none
            let my = py / scale - quietZone
            for px in 0..<side {
                let mx = px / scale - quietZone
                let isDark = mx >= 0 && my >= 0 && mx < m.size && my < m.size && m[x: mx, y: my]
                raw.append(isDark ? 0 : 255)
            }
        }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.appendBigEndian(UInt32(side))
        ihdr.appendBigEndian(UInt32(side))
        ihdr.append(contentsOf: [8, 0, 0, 0, 0]) // 8-bit greyscale, deflate, no filter, no interlace
        png.appendChunk("IHDR", ihdr)
        png.appendChunk("IDAT", zlibStored(raw))
        png.appendChunk("IEND", Data())
        return png
    }

    /// zlib stream of uncompressed (stored) deflate blocks: no compressor
    /// needed, and a QR code is small.
    static func zlibStored(_ bytes: [UInt8]) -> Data {
        var out = Data([0x78, 0x01])
        var offset = 0
        repeat {
            let len = min(65_535, bytes.count - offset)
            let final: UInt8 = offset + len >= bytes.count ? 1 : 0
            out.append(final)
            out.append(UInt8(len & 0xFF)); out.append(UInt8(len >> 8))
            out.append(UInt8(~len & 0xFF)); out.append(UInt8((~len >> 8) & 0xFF))
            out.append(contentsOf: bytes[offset..<offset + len])
            offset += len
        } while offset < bytes.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        out.appendBigEndian(b << 16 | a)
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendBigEndian(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    mutating func appendChunk(_ type: String, _ body: Data) {
        appendBigEndian(UInt32(body.count))
        let typed = Data(type.utf8) + body
        append(typed)
        appendBigEndian(QRRender.crc32(typed))
    }
}
