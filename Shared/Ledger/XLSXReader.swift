import Foundation
import Compression

/// Reads the first worksheet of an .xlsx file into rows of cell values. Enough for Xero report
/// exports: shared strings, inline strings and numbers. No third party library.
enum XLSXReader {

    enum Value: Equatable {
        case text(String)
        case number(Double)
        case empty

        var string: String {
            switch self {
            case .text(let s): s
            case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
            case .empty: ""
            }
        }

        var double: Double? {
            switch self {
            case .number(let n): n
            case .text(let s): Double(s.replacingOccurrences(of: ",", with: ""))
            case .empty: nil
            }
        }

        /// Excel stores dates as days since 30 December 1899.
        var date: Date? {
            guard case .number(let n) = self, n > 20000, n < 80000 else { return nil }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            let base = cal.date(from: DateComponents(year: 1899, month: 12, day: 30))!
            return cal.date(byAdding: .day, value: Int(n.rounded(.down)), to: base)
        }
    }

    enum ReadError: LocalizedError {
        case notXLSX
        var errorDescription: String? { "That file is not an Excel workbook (.xlsx)." }
    }

    static func rows(of url: URL) throws -> [[Value]] {
        let files = try Zip.entries(Data(contentsOf: url))
        let shared = files["xl/sharedStrings.xml"].map(SharedStringsParser.parse) ?? []
        guard let sheetPath = files.keys.filter({ $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }).sorted().first,
              let sheet = files[sheetPath] else { throw ReadError.notXLSX }
        return SheetParser.parse(sheet, shared: shared)
    }

    // MARK: Zip

    enum Zip {
        static func entries(_ data: Data) throws -> [String: Data] {
            let bytes = [UInt8](data)
            func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
            func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
            // End of central directory record, searched from the end.
            guard bytes.count > 22, let eocd = stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1)
                .first(where: { u32($0) == 0x06054b50 }) else { throw ReadError.notXLSX }
            let count = u16(eocd + 10)
            var p = u32(eocd + 16)
            var out: [String: Data] = [:]
            for _ in 0..<count {
                guard p + 46 <= bytes.count, u32(p) == 0x02014b50 else { throw ReadError.notXLSX }
                let method = u16(p + 10)
                let compSize = u32(p + 20)
                let size = u32(p + 24)
                let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
                let localOffset = u32(p + 42)
                let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
                p += 46 + nameLen + extraLen + commentLen

                let lh = localOffset
                let start = lh + 30 + u16(lh + 26) + u16(lh + 28)
                guard start + compSize <= bytes.count else { continue }
                let raw = Data(bytes[start..<(start + compSize)])
                if method == 0 {
                    out[name] = raw
                } else if method == 8, let inflated = inflate(raw, expected: size) {
                    out[name] = inflated
                }
            }
            return out
        }

        /// Raw DEFLATE, which is what Apple's COMPRESSION_ZLIB decodes.
        static func inflate(_ data: Data, expected: Int) -> Data? {
            let capacity = max(expected, 64)
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0 else { return nil }
            out.count = written
            return out
        }
    }

    // MARK: XML

    final class SharedStringsParser: NSObject, XMLParserDelegate {
        private var strings: [String] = []
        private var current = ""
        private var inItem = false
        private var inText = false

        static func parse(_ data: Data) -> [String] {
            let p = SharedStringsParser()
            let parser = XMLParser(data: data)
            parser.delegate = p
            parser.parse()
            return p.strings
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "si" { inItem = true; current = "" }
            if name == "t" && inItem { inText = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "t" { inText = false }
            if name == "si" { strings.append(current); inItem = false }
        }
    }

    final class SheetParser: NSObject, XMLParserDelegate {
        private let shared: [String]
        private var rows: [[Value]] = []
        private var row: [Value] = []
        private var cellRef = ""
        private var cellType = ""
        private var text = ""
        private var capturing = false

        init(shared: [String]) { self.shared = shared }

        static func parse(_ data: Data, shared: [String]) -> [[Value]] {
            let p = SheetParser(shared: shared)
            let parser = XMLParser(data: data)
            parser.delegate = p
            parser.parse()
            return p.rows
        }

        private static func column(_ ref: String) -> Int {
            var n = 0
            for ch in ref.unicodeScalars {
                guard ch.value >= 65 && ch.value <= 90 else { break }
                n = n * 26 + Int(ch.value - 64)
            }
            return max(n - 1, 0)
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "row": row = []
            case "c":
                cellRef = attributes["r"] ?? ""
                cellType = attributes["t"] ?? ""
                text = ""
            case "v", "t": capturing = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturing { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t": capturing = false
            case "c":
                let value: Value
                switch cellType {
                case "s": value = Int(text).flatMap { $0 < shared.count ? .text(shared[$0]) : nil } ?? .empty
                case "inlineStr", "str": value = .text(text)
                case "b": value = .number(Double(text) ?? 0)
                default: value = text.isEmpty ? .empty : Double(text).map(Value.number) ?? .text(text)
                }
                let col = cellRef.isEmpty ? row.count : Self.column(cellRef)
                while row.count < col { row.append(.empty) }
                if row.count == col { row.append(value) } else { row[col] = value }
            case "row": rows.append(row)
            default: break
            }
        }
    }
}
