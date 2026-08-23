// SPDX-License-Identifier: MIT
import Foundation

@testable import Decimal128TextCodec

// ---------------------------------------------------------------------------
// Hex, in the corpus column form: 32 uppercase digits, most-significant first.
// ---------------------------------------------------------------------------

enum Hex {

    /// Parse 32 hex digits, with or without a leading `0x`.
    static func parse32(_ s: String) -> UInt128? {
        var body = Substring(s)
        if body.hasPrefix("0x") || body.hasPrefix("0X") {
            body = body.dropFirst(2)
        }
        guard body.count == 32 else { return nil }
        return UInt128(body, radix: 16)
    }

    /// Render an encoding as 32 uppercase hex digits.
    static func format32(_ v: UInt128) -> String {
        let s = String(v, radix: 16, uppercase: true)
        return String(repeating: "0", count: 32 - s.count) + s
    }

    /// Parse the `[hi,lo]` spelling the reference's own vector tables use.
    static func parseBracketed(_ s: String) -> UInt128 {
        let inner = s.dropFirst().dropLast()
        let parts = inner.split(separator: ",")
        precondition(parts.count == 2, "bad bracketed hex: \(s)")
        let hi = UInt64(parts[0], radix: 16)!
        let lo = UInt64(parts[1], radix: 16)!
        return (UInt128(hi) << 64) | UInt128(lo)
    }
}

// ---------------------------------------------------------------------------
// The vendored conformance corpus.
// ---------------------------------------------------------------------------

/// One row of a `string_bid_dpd` table.
struct CorpusRow {
    let text: String
    let bid: UInt128
    let dpd: UInt128
    /// The `status` column, present only in the input-driven tables.
    let status: String
    let lineNumber: Int
}

enum Corpus {

    /// The four tables vendored under `Tests/.../vectors`, and their row counts.
    ///
    /// The counts are asserted by the tests. That is not ceremony: the text
    /// column of `parse` and `error` is double-quoted with `\\` and `\"`
    /// escapes, because those tables must carry the empty string, a leading and
    /// a trailing space, an embedded comma, an embedded quote and an embedded
    /// backslash. A naive comma split silently corrupts four rows and still
    /// passes, since a mangled malformed input fails to parse either way. The
    /// row count is what catches it.
    static let hundred = "string_bid128_dpd128_100"
    static let nonCanonical = "string_bid128_dpd128_noncanonical"
    static let parse = "string_bid128_dpd128_parse"
    static let error = "string_bid128_dpd128_error"

    /// A vendored table, read out of the test bundle.
    static func load(_ name: String) throws -> [CorpusRow] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "csv.txt",
                                          subdirectory: "vectors") else {
            throw CorpusError.missing(name)
        }
        return try parse(String(contentsOf: url, encoding: .utf8), name)
    }

    /// A table at an arbitrary path — the un-vendored canonical file.
    static func loadFile(_ path: String) throws -> [CorpusRow] {
        let url = URL(fileURLWithPath: path)
        return try parse(String(contentsOf: url, encoding: .utf8), url.lastPathComponent)
    }

    private static func parse(_ contents: String, _ name: String) throws -> [CorpusRow] {
        var rows: [CorpusRow] = []
        for (index, rawLine) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = Substring(rawLine)
            while line.hasSuffix("\r") {
                line = line.dropLast()
            }
            line = skipSpace(line)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            let text: String
            if line.hasPrefix("\"") {
                (text, line) = readQuoted(line)
            } else {
                (text, line) = readField(line)
            }
            var bidHex = ""
            var dpdHex = ""
            var status = ""
            (bidHex, line) = readNextField(line)
            (dpdHex, line) = readNextField(line)
            (status, line) = readNextField(line)

            guard let bid = Hex.parse32(bidHex), let dpd = Hex.parse32(dpdHex) else {
                throw CorpusError.malformed(name, index + 1, bidHex, dpdHex)
            }
            rows.append(CorpusRow(text: text, bid: bid, dpd: dpd,
                                  status: status, lineNumber: index + 1))
        }
        return rows
    }

    // -- the reader, matching the C port's byte for byte ----------------------

    private static func skipSpace(_ s: Substring) -> Substring {
        var t = s
        while let c = t.first, c == " " || c == "\t" {
            t = t.dropFirst()
        }
        return t
    }

    /// One comma-delimited field, stopping at `,` or `#` or end of line, with
    /// surrounding whitespace trimmed.
    private static func readField(_ s: Substring) -> (String, Substring) {
        let start = skipSpace(s)
        var end = start
        while let c = end.first, c != ",", c != "#" {
            end = end.dropFirst()
        }
        var value = start[start.startIndex..<end.startIndex]
        while let c = value.last, c == " " || c == "\t" {
            value = value.dropLast()
        }
        return (String(value), end)
    }

    /// Step over a field separator, then read the next field. Yields the empty
    /// string when the row has no further column.
    private static func readNextField(_ s: Substring) -> (String, Substring) {
        var rest = skipSpace(s)
        guard rest.hasPrefix(",") else { return ("", rest) }
        rest = rest.dropFirst()
        return readField(rest)
    }

    /// The quoted text column, honouring `\\` and `\"` escapes.
    private static func readQuoted(_ s: Substring) -> (String, Substring) {
        var rest = s.dropFirst() // opening quote
        var out = ""
        while let c = rest.first, c != "\"" {
            rest = rest.dropFirst()
            var ch = c
            if ch == "\\", let next = rest.first {
                ch = next
                rest = rest.dropFirst()
            }
            out.append(ch)
        }
        if rest.hasPrefix("\"") {
            rest = rest.dropFirst()
        }
        return (out, rest)
    }
}

enum CorpusError: Error, CustomStringConvertible {
    case missing(String)
    case malformed(String, Int, String, String)

    var description: String {
        switch self {
        case .missing(let name):
            return "vector file \(name).csv.txt is not in the test bundle"
        case .malformed(let name, let line, let bid, let dpd):
            return "\(name).csv.txt line \(line): malformed hex columns <\(bid)> <\(dpd)>"
        }
    }
}

// ---------------------------------------------------------------------------
// Thin wrappers so the tests read the way the codec's own API does.
// ---------------------------------------------------------------------------

func bidParse(_ text: String) -> (bits: UInt128, error: String?) {
    var bits: UInt128 = (UInt128(0xFEED) << 64) | UInt128(0xFACE)
    let err = Decimal128TextCodec.bid128Parse(&bits, text)
    return (bits, err)
}

func dpdParse(_ text: String) -> (bits: UInt128, error: String?) {
    var bits: UInt128 = (UInt128(0xFEED) << 64) | UInt128(0xFACE)
    let err = Decimal128TextCodec.dpd128Parse(&bits, text)
    return (bits, err)
}

/// The canonical positive quiet NaN, which is what both parse functions write
/// on failure and the same bit pattern in both formats.
let canonicalQuietNaN: UInt128 = UInt128(0x7C00_0000_0000_0000) << 64

/// Assemble an encoding from its two words, the way the reference's tables
/// spell one.
func words(_ hi: UInt64, _ lo: UInt64) -> UInt128 {
    return (UInt128(hi) << 64) | UInt128(lo)
}

func hiWord(_ v: UInt128) -> UInt64 { UInt64(truncatingIfNeeded: v >> 64) }
func loWord(_ v: UInt128) -> UInt64 { UInt64(truncatingIfNeeded: v) }
