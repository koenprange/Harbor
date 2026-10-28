import Foundation

/// Validates the bencoded container before handing an Archive download to another app.
/// It deliberately never interprets paths or extracts payload files.
public enum TorrentValidator {
    public static func isTorrent(_ data: Data) -> Bool {
        var parser = Parser(bytes: Array(data))
        return parser.parseTorrent()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func parseTorrent() -> Bool {
            guard take(100) else { return false } // dictionary
            var hasInfo = false
            while peek != 101 {
                guard let key = string() else { return false }
                if key == Array("info".utf8) {
                    guard !hasInfo, peek == 100 else { return false }
                    hasInfo = true
                }
                guard value(depth: 0) else { return false }
            }
            return take(101) && hasInfo && index == bytes.count
        }

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func take(_ byte: UInt8) -> Bool {
            guard peek == byte else { return false }
            index += 1
            return true
        }
        mutating func string() -> [UInt8]? {
            var length = 0
            let start = index
            while let byte = peek, (48...57).contains(byte) {
                guard index - start < 9 else { return nil }
                length = length * 10 + Int(byte - 48)
                index += 1
            }
            guard index > start, take(58), length <= bytes.count - index else { return nil }
            let result = Array(bytes[index..<(index + length)])
            index += length
            return result
        }
        mutating func value(depth: Int) -> Bool {
            guard depth < 40, let byte = peek else { return false }
            if (48...57).contains(byte) { return string() != nil }
            if take(105) { // integer
                _ = take(45)
                let start = index
                while let digit = peek, (48...57).contains(digit) { index += 1 }
                return index > start && take(101)
            }
            if take(108) { // list
                while peek != 101 { guard value(depth: depth + 1) else { return false } }
                return take(101)
            }
            if take(100) {
                while peek != 101 {
                    guard string() != nil, value(depth: depth + 1) else { return false }
                }
                return take(101)
            }
            return false
        }
    }
}
