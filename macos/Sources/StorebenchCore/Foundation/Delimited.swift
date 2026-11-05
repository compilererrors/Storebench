import Foundation

public enum Delimited {
    public struct Table: Equatable, Sendable { public var columns: [String]; public var rows: [[String]] }
    public enum Failure: Error, Equatable {
        case invalid(String)
        public var message: String { if case .invalid(let text) = self { text } else { "" } }
    }

    public static func parse(_ input: String, delimiter: Character = ",") throws -> Table {
        var text = input
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard text.utf16.count <= 8_000_000, !text.contains("\0") else { throw Failure.invalid("The file is too large or contains invalid text.") }
        let scalars = Array(text.unicodeScalars), separator = delimiter.unicodeScalars.first!
        var records: [[String]] = [], row: [String] = [], cell = "", quoted = false, closed = false
        func field() throws { row.append(cell); cell = ""; closed = false; if row.count > 100 { throw Failure.invalid("Too many columns.") } }
        func record() throws { try field(); if row.contains(where: { !$0.isEmpty }) { records.append(row) }; row = []; if records.count > 100_000 { throw Failure.invalid("Too many rows.") } }
        var i = 0
        while i < scalars.count {
            let char = scalars[i]
            if quoted {
                if char == "\"" { if i + 1 < scalars.count && scalars[i + 1] == "\"" { cell.unicodeScalars.append("\""); i += 1 } else { quoted = false; closed = true } }
                else { cell.unicodeScalars.append(char) }
            } else if char == separator { try field() }
            else if char == "\n" || char == "\r" { if char == "\r" && i + 1 < scalars.count && scalars[i + 1] == "\n" { i += 1 }; try record() }
            else if char == "\"" && cell.isEmpty && !closed { quoted = true }
            else { if closed || char == "\"" { throw Failure.invalid("Invalid quoted field. Use doubled quotes inside quoted values.") }; cell.unicodeScalars.append(char) }
            i += 1
        }
        if quoted { throw Failure.invalid("A quoted field is not closed.") }
        if !cell.isEmpty || !row.isEmpty || closed { try record() }
        guard !records.isEmpty else { throw Failure.invalid("The file needs unique, nonempty column names.") }
        let columns = records.removeFirst()
        guard !columns.isEmpty, columns.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 200 }), Set(columns.map { Array($0.utf16) }).count == columns.count else { throw Failure.invalid("The file needs unique, nonempty column names.") }
        guard records.allSatisfy({ $0.count == columns.count }) else { throw Failure.invalid("A row has a different number of values from the header.") }
        return Table(columns: columns, rows: records)
    }

    public static func write(_ table: Table, delimiter: Character = ",") -> String {
        func quote(_ value: String) -> String {
            value.unicodeScalars.contains { $0 == "\"" || $0 == "\r" || $0 == "\n" || $0 == delimiter.unicodeScalars.first! } ? "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" : value
        }
        return ([table.columns] + table.rows).map { $0.map(quote).joined(separator: String(delimiter)) }.joined(separator: "\r\n") + "\r\n"
    }

    /// Reversible escaping that keeps listing text from being read as spreadsheet formulas.
    public static func spreadsheetCell(_ value: String) -> String { value.range(of: #"^\s*[=+@-]"#, options: .regularExpression) != nil || value.hasPrefix("'") ? "'" + value : value }
    public static func unspreadsheetCell(_ value: String) -> String {
        guard value.hasPrefix("'") else { return value }
        let rest = String(value.dropFirst())
        return rest.hasPrefix("'") || rest.range(of: #"^\s*[=+@-]"#, options: .regularExpression) != nil ? rest : value
    }

    public static func records(_ table: Table, expected: [String], optional: [String] = []) throws -> [[String: String]] {
        guard expected.allSatisfy(table.columns.contains), table.columns.allSatisfy({ expected.contains($0) || optional.contains($0) }) else {
            throw Failure.invalid("Use these columns: \(expected.joined(separator: ", ")). Download a template to start.")
        }
        guard !table.rows.isEmpty else { throw Failure.invalid("The file contains no data rows.") }
        return table.rows.map { row in Dictionary(uniqueKeysWithValues: zip(table.columns, row)) }
    }
}
