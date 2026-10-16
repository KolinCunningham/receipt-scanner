import Foundation

/// Minimal .xlsx writer: inline strings, a few cell styles, stored (uncompressed) zip.
/// Opens in Excel, Numbers and Google Sheets without any third party library.
struct XLSXWriter {

    enum Cell {
        case text(String)
        case number(Double)
        case money(Double)
        case date(Date)
        case header(String)
        case boldText(String)
        case sumFormula(column: Int, fromRow: Int, toRow: Int)
        case empty
    }

    struct Sheet {
        var name: String
        var columnWidths: [Double]
        var rows: [[Cell]]
        var freezeHeader = true
    }

    static func makeWorkbook(_ sheets: [Sheet]) -> Data {
        var usedNames = Set<String>()
        let names = sheets.map { uniqueSheetName($0.name, used: &usedNames) }

        var files: [(String, Data)] = []
        files.append(("[Content_Types].xml", Data(contentTypes(sheetCount: sheets.count).utf8)))
        files.append(("_rels/.rels", Data(rootRels.utf8)))
        files.append(("xl/workbook.xml", Data(workbook(names: names).utf8)))
        files.append(("xl/_rels/workbook.xml.rels", Data(workbookRels(sheetCount: sheets.count).utf8)))
        files.append(("xl/styles.xml", Data(styles.utf8)))
        for (i, sheet) in sheets.enumerated() {
            files.append(("xl/worksheets/sheet\(i + 1).xml", Data(worksheet(sheet).utf8)))
        }
        return StoredZip.make(files)
    }

    // MARK: Parts

    private static func contentTypes(sheetCount: Int) -> String {
        let sheets = (1...max(sheetCount, 1)).map {
            #"<Override PartName="/xl/worksheets/sheet\#($0).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \(sheets)</Types>
        """
    }

    private static let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """

    private static func workbook(names: [String]) -> String {
        let sheets = names.enumerated().map { i, name in
            #"<sheet name="\#(escape(name))" sheetId="\#(i + 1)" r:id="rId\#(i + 1)"/>"#
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets>\(sheets)</sheets><calcPr fullCalcOnLoad="1"/></workbook>
        """
    }

    private static func workbookRels(sheetCount: Int) -> String {
        let sheets = (1...max(sheetCount, 1)).map {
            #"<Relationship Id="rId\#($0)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#($0).xml"/>"#
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(sheets)<Relationship Id="rId\(sheetCount + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        </Relationships>
        """
    }

    // Style indexes: 0 normal, 1 date, 2 money, 3 bold, 4 bold money, 5 header (bold, shaded)
    private static let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <numFmts count="1"><numFmt numFmtId="164" formatCode="dd/mm/yyyy"/></numFmts>\
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>\
        <fill><patternFill patternType="solid"><fgColor rgb="FFE8EEF4"/><bgColor indexed="64"/></patternFill></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="6">\
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="4" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
        <xf numFmtId="4" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>\
        <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>\
        </cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        </styleSheet>
        """

    private static func worksheet(_ sheet: Sheet) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        xml += #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        if sheet.freezeHeader {
            xml += #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
        }
        if !sheet.columnWidths.isEmpty {
            xml += "<cols>"
            for (i, w) in sheet.columnWidths.enumerated() {
                xml += #"<col min="\#(i + 1)" max="\#(i + 1)" width="\#(w)" customWidth="1"/>"#
            }
            xml += "</cols>"
        }
        xml += "<sheetData>"
        for (r, row) in sheet.rows.enumerated() {
            let rowNumber = r + 1
            xml += #"<row r="\#(rowNumber)">"#
            for (c, cell) in row.enumerated() {
                xml += cellXML(cell, ref: "\(columnLetter(c))\(rowNumber)")
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    private static func cellXML(_ cell: Cell, ref: String) -> String {
        switch cell {
        case .empty:
            return ""
        case .text(let s):
            return #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(escape(s))</t></is></c>"#
        case .boldText(let s):
            return #"<c r="\#(ref)" s="3" t="inlineStr"><is><t xml:space="preserve">\#(escape(s))</t></is></c>"#
        case .header(let s):
            return #"<c r="\#(ref)" s="5" t="inlineStr"><is><t xml:space="preserve">\#(escape(s))</t></is></c>"#
        case .number(let n):
            return #"<c r="\#(ref)"><v>\#(n)</v></c>"#
        case .money(let n):
            return #"<c r="\#(ref)" s="2"><v>\#(n)</v></c>"#
        case .date(let d):
            return #"<c r="\#(ref)" s="1"><v>\#(excelSerial(d))</v></c>"#
        case .sumFormula(let column, let from, let to):
            let col = columnLetter(column)
            guard to >= from else { return #"<c r="\#(ref)" s="4"><v>0</v></c>"# }
            return #"<c r="\#(ref)" s="4"><f>SUM(\#(col)\#(from):\#(col)\#(to))</f></c>"#
        }
    }

    // MARK: Helpers

    static func columnLetter(_ index: Int) -> String {
        var n = index + 1
        var s = ""
        while n > 0 {
            let rem = (n - 1) % 26
            s = String(UnicodeScalar(65 + rem)!) + s
            n = (n - 1) / 26
        }
        return s
    }

    /// Days since 30 Dec 1899 in the local calendar, which is how Excel stores dates.
    static func excelSerial(_ date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let start = cal.date(from: DateComponents(year: 1899, month: 12, day: 30))!
        return cal.dateComponents([.day], from: start, to: cal.startOfDay(for: date)).day ?? 0
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                // XML 1.0 forbids other control characters.
                if scalar.value >= 0x20 { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    private static func uniqueSheetName(_ raw: String, used: inout Set<String>) -> String {
        let banned = CharacterSet(charactersIn: "[]:*?/\\")
        var base = String(raw.unicodeScalars.filter { !banned.contains($0) })
            .trimmingCharacters(in: CharacterSet(charactersIn: "' "))
        if base.isEmpty { base = "Sheet" }
        base = String(base.prefix(31))
        var name = base
        var n = 2
        while used.contains(name.lowercased()) {
            let suffix = " (\(n))"
            name = String(base.prefix(31 - suffix.count)) + suffix
            n += 1
        }
        used.insert(name.lowercased())
        return name
    }
}

/// Zip archive with no compression. Enough for an .xlsx package.
enum StoredZip {

    static func make(_ files: [(path: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        let (dosTime, dosDate) = dosDateTime(Date())

        for file in files {
            let name = Data(file.path.utf8)
            let crc = CRC32.checksum(file.data)
            let offset = UInt32(out.count)

            out.append(le32(0x04034b50))
            out.append(le16(20)); out.append(le16(0)); out.append(le16(0))
            out.append(le16(dosTime)); out.append(le16(dosDate))
            out.append(le32(crc))
            out.append(le32(UInt32(file.data.count))); out.append(le32(UInt32(file.data.count)))
            out.append(le16(UInt16(name.count))); out.append(le16(0))
            out.append(name)
            out.append(file.data)

            central.append(le32(0x02014b50))
            central.append(le16(20)); central.append(le16(20)); central.append(le16(0)); central.append(le16(0))
            central.append(le16(dosTime)); central.append(le16(dosDate))
            central.append(le32(crc))
            central.append(le32(UInt32(file.data.count))); central.append(le32(UInt32(file.data.count)))
            central.append(le16(UInt16(name.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0))
            central.append(le32(offset))
            central.append(name)
        }

        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32(0x06054b50))
        out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(files.count))); out.append(le16(UInt16(files.count)))
        out.append(le32(UInt32(central.count)))
        out.append(le32(centralOffset))
        out.append(le16(0))
        return out
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(max((c.year ?? 1980) - 1980, 0) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
