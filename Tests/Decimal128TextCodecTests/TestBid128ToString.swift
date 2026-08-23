// SPDX-License-Identifier: MIT
import Testing

@testable import Decimal128TextCodec

/// Render vectors for ``Decimal128TextCodec/bid128ToString(_:)``, spelled as
/// `[hi,lo]` the way the reference's own tables are.
///
/// The reference drives the same table through the `decimal128-kotlin` engine as
/// an oracle. There is no such dependency here — the expected text is written
/// out, and the independent oracle is the `decimal128-c`-generated corpus in
/// `TestCorpusVectors`, which covers 86,069 rows. This table is the hand-chosen
/// discriminating cases: every exponent digit length, both combination-field
/// forms, the cohort members of 1, the non-canonical coefficient rule, and the
/// four corners of the representable range.
@Suite
struct TestBid128ToString {

    static let vectors: [(hex: String, expected: String)] = [
        ("[7E00000000000000,8000000000000000]", "sNaN9223372036854775808"),

// === Zero with various exponents ===
        ("[0000000000000000,0000000000000000]", "0E-6176"),       // smallest exponent zero
        ("[3040000000000000,0000000000000000]", "0"),              // exponent 0 zero (canonical "0")
        ("[5FFE000000000000,0000000000000000]", "0E+6111"),        // largest exponent zero
        ("[B040000000000000,0000000000000000]", "-0"),             // negative zero, exponent 0

// === Small integers ===
        ("[3040000000000000,0000000000000001]", "1"),
        ("[3040000000000000,000000000000000A]", "10"),
        ("[3040000000000000,0000000000000064]", "100"),
        ("[B040000000000000,0000000000000001]", "-1"),

// === Cohort members of "1" (same numerical value, different bit patterns) ===
        ("[303E000000000000,000000000000000A]", "1.0"),            // coefficient 10, exponent -1
        ("[303C000000000000,0000000000000064]", "1.00"),           // coefficient 100, exponent -2
        ("[303A000000000000,00000000000003E8]", "1.000"),          // coefficient 1000, exponent -3

        ("[3040314DC6448D93,38C15B0A00000000]", "1000000000000000000000000000000000"),
// === Maximum coefficient at exponent 0 ===
        ("[3041ED09BEAD87C0,378D8E63FFFFFFFF]", "9999999999999999999999999999999999"),  // 34 nines

// === Non-canonical coefficient (≥ 10^34) — IEEE 754 says coefficient becomes zero ===
        ("[6C7B86F26FC10000,0000000000000000]", "0E+215"),
        ("[7800000000000000,0000000000000000]", "Infinity"),
        ("[F800000000000000,0000000000000000]", "-Infinity"),
        ("[7800000000000000,0000000000000001]", "Infinity"),

// === Positive exponents: the '+' must be emitted at every exponent digit length ===
        ("[304A000000000000,0000000000000001]", "1E+5"),          // 1-digit exponent
        ("[304C000000000000,000000000000000F]", "1.5E+7"),        // decimal point + 1-digit exponent
        ("[3052000000000000,0000000000000001]", "1E+9"),          // last 1-digit
        ("[3054000000000000,0000000000000001]", "1E+10"),         // first 2-digit
        ("[3106000000000000,0000000000000001]", "1E+99"),         // last 2-digit
        ("[3108000000000000,0000000000000001]", "1E+100"),        // first 3-digit
        ("[380E000000000000,0000000000000001]", "1E+999"),        // last 3-digit
        ("[3810000000000000,0000000000000001]", "1E+1000"),       // first 4-digit

// === Zeros just past the plain-form fast path (which covers qExp -6..0) ===
        ("[3042000000000000,0000000000000000]", "0E+1"),
        ("[B042000000000000,0000000000000000]", "-0E+1"),
        ("[3052000000000000,0000000000000000]", "0E+9"),
        ("[3054000000000000,0000000000000000]", "0E+10"),

// === Powers of 10 ===
        ("[3040000000000000,0000000000000001]", "1"),              // 10^0
        ("[30C6000000000000,0000000000000001]", "1E+67"),
        ("[2FB0000000000000,0000000000000001]", "1E-72"),

// === Largest finite values ===
        ("[5FFFED09BEAD87C0,378D8E63FFFFFFFF]", "9.999999999999999999999999999999999E+6144"),
        ("[DFFFED09BEAD87C0,378D8E63FFFFFFFF]", "-9.999999999999999999999999999999999E+6144"),
        // roll over
        ("[5FFFED09BEAD87C1,0000000000000000]", "0E+6111"),
        ("[5FFFED09BEAD87C0,378D8E6400000000]", "0E+6111"),

// === Smallest positive normal: 1E-6143 ===
        ("[0042000000000000,0000000000000001]", "1E-6143"),

// === Smallest positive subnormal: 1E-6176 ===
        ("[0000000000000000,0000000000000001]", "1E-6176"),
        ("[8000000000000000,0000000000000001]", "-1E-6176"),

// === Mid-range subnormals ===
        ("[0020000000000000,0000000000000001]", "1E-6160"),
        ("[003E000000000000,000000000000000A]", "1.0E-6144"),

// === Specials: Infinity ===
        ("[7800000000000000,0000000000000000]", "Infinity"),       // +Inf, canonical
        ("[F800000000000000,0000000000000000]", "-Infinity"),      // -Inf

// === Specials: NaN ===
        ("[7C00000000000000,0000000000000000]", "NaN"),            // quiet NaN, no payload
        ("[FC00000000000000,0000000000000000]", "-NaN"),           // negative quiet NaN (sign bit set)
        ("[7C00000000000000,0000000000000001]", "NaN1"),           // payload = 1
        ("[7E00000000000000,0000000000000000]", "sNaN"),           // signaling NaN
        ("[7E00000000000000,0000000000000001]", "sNaN1"),
        ("[7E00000000000000,7FFFFFFFFFFFFFFF]", "sNaN9223372036854775807"),
        ("[7E00000000000000,8000000000000000]", "sNaN9223372036854775808"),
        ("[7E00000000000000,FFFFFFFFFFFFFFFF]", "sNaN18446744073709551615"),
        ("[7C00314DC6448D93,38C15B09FFFFFFFF]", "NaN999999999999999999999999999999999"), // max payload
        ("[7C00314DC6448D94,38C15B09FFFFFFFF]", "NaN"),            // non-canonical ... c == 0
        ("[7C00314DC6448D93,38C15B0A00000000]", "NaN"),            // non-canonical ... c == 0

        ("[20491165061C532A,535089A5C8F9DA39]", "5.545101757363565785893501553728057E-2011"),
        ("[812C000000000000,0000000000000000]", "-0E-6026"),
        ("[2FFCA45894E48295,67D9DA2155555555]", "0.3333333333333333333333333333333333"),
        ("[a9481e81f1ac7df5,96dcd9baa6738f4a]", "-6.18767515491324263605526166998858E-860"),
        ("[AFFDB28CFC8BFD25,2B61B866EF8F5F22]", "-0.8813735870195430252326093249797922"),
    ]

    @Test("hand-chosen render vectors")
    func renderVectors() {
        for v in Self.vectors {
            let bits = Hex.parseBracketed(v.hex)
            #expect(Decimal128TextCodec.bid128ToString(bits) == v.expected, "for \(v.hex)")
        }
    }

    /// Everything the table renders must parse back to the same bits, except
    /// the deliberately non-canonical patterns, which render as something the
    /// encoder would never have emitted.
    @Test("render then parse returns the canonical encoding")
    func renderRoundTrips() {
        for v in Self.vectors {
            let bits = Hex.parseBracketed(v.hex)
            let text = Decimal128TextCodec.bid128ToString(bits)
            let b = bidParse(text)
            #expect(b.error == nil, "reparse <\(text)>: \(b.error ?? "")")
            #expect(Decimal128TextCodec.bid128ToString(b.bits) == text,
                    "reparse of <\(text)> renders differently")
        }
    }
}
