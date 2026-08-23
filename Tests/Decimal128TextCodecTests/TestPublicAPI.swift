// SPDX-License-Identifier: MIT
import Testing

@testable import Decimal128TextCodec

/// The properties the four public functions promise, as properties rather than
/// as tables — so the two formats and the two spellings of a NaN payload cannot
/// drift apart the way two hand-maintained tables would.
@Suite
struct TestPublicAPI {

    /// The NaN payload rules live in the shared parser, so both formats must
    /// apply them identically — parenthesis handling and the written-digit limit
    /// alike.
    @Test("both formats apply the NaN payload rules identically")
    func nanPayloadRulesAreSharedByBothFormats() {
        for str in [
            "NaN(1)", "NaN[1]", "sNaN(5)", "NaN)1(",
            "NaN(123)", "NaN()", "NaN(1", "NaN(1)2(3)",
            "NaN1", "NaN0001",
            "NaN" + String(repeating: "0", count: 32) + "1",
            "NaN" + String(repeating: "9", count: 33),
            "NaN" + String(repeating: "9", count: 34),
            "NaN" + String(repeating: "0", count: 40) + "1",
        ] {
            let b = bidParse(str)
            let d = dpdParse(str)
            #expect(b.error == d.error, "the formats disagree on <\(str)>")
            // payloads below 10 encode the same either way, so those cases must
            // produce identical bits in both formats
            if b.error == nil && loWord(b.bits) <= 9 && hiWord(b.bits) == 0x7C00_0000_0000_0000 {
                #expect(b.bits == d.bits, "<\(str)>")
            }
        }
    }

    /// The parenthesised spelling is exactly the bare spelling: same bits, in
    /// both encodings. Asserting the equivalence rather than a second table of
    /// hex means the two forms cannot drift apart.
    @Test("a parenthesised payload equals the bare payload")
    func parenthesisedPayloadEqualsBarePayload() {
        for payload in [
            "0", "1", "5", "9", "10", "0001", "12345", "999999999999999999",
            "1000000000000000000", "999999999999999999999999999999999",
            "9999999999999999999999999999999999",
            String(repeating: "0", count: 40) + "1",
        ] {
            for prefix in ["NaN", "sNaN", "qNaN", "-NaN", "-sNaN"] {
                let bare = bidParse(prefix + payload)
                let paren = bidParse("\(prefix)(\(payload))")
                #expect(bare.error == nil)
                #expect(paren.error == nil)
                #expect(bare.bits == paren.bits, "bid for \(prefix)(\(payload))")

                let bareD = dpdParse(prefix + payload)
                let parenD = dpdParse("\(prefix)(\(payload))")
                #expect(bareD.error == nil)
                #expect(parenD.error == nil)
                #expect(bareD.bits == parenD.bits, "dpd for \(prefix)(\(payload))")
            }
        }
    }

    /// Rendering never emits parentheses, whichever spelling was parsed.
    @Test("rendering is always the bare form")
    func renderingIsAlwaysTheBareForm() {
        let b = bidParse("NaN(123)")
        #expect(b.error == nil)
        #expect(Decimal128TextCodec.bid128ToString(b.bits) == "NaN123")
        let d = dpdParse("-sNaN(45)")
        #expect(d.error == nil)
        #expect(Decimal128TextCodec.dpd128ToString(d.bits) == "-sNaN45")
    }

    /// On failure the out-parameter is written, not left alone: the caller sees
    /// a legal IEEE 754-2019 datum rather than whatever was there before.
    @Test("a rejected parse still writes the canonical quiet NaN")
    func failureAlwaysWritesTheOutParameter() {
        for bad in ["", " ", "+", "-", ".", "1.2.3", "abc", "1E", "1E+", "1_",
                    "_1", "1__2", "NaNx", "Infi", "NaN()", "NaN[1]", "qq"] {
            var bits: UInt128 = .max
            let bErr = Decimal128TextCodec.bid128Parse(&bits, bad)
            #expect(bErr != nil, "accepted <\(bad)>")
            #expect(bits == canonicalQuietNaN, "<\(bad)> left \(Hex.format32(bits))")

            bits = .max
            let dErr = Decimal128TextCodec.dpd128Parse(&bits, bad)
            #expect(dErr != nil, "accepted <\(bad)>")
            #expect(bits == canonicalQuietNaN, "<\(bad)> left \(Hex.format32(bits))")
        }
    }

    /// Rendering cannot fail. Every 128-bit pattern is a legal input, including
    /// the ones no encoder would emit.
    @Test("every bit pattern renders, and re-parses to something that renders the same")
    func renderingIsTotal() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        for _ in 0..<20000 {
            let bits = (UInt128(next()) << 64) | UInt128(next())

            let bidText = Decimal128TextCodec.bid128ToString(bits)
            let b = bidParse(bidText)
            #expect(b.error == nil, "bid \(Hex.format32(bits)) rendered <\(bidText)>, which will not re-parse")
            if b.error == nil {
                #expect(Decimal128TextCodec.bid128ToString(b.bits) == bidText,
                        "bid \(Hex.format32(bits)) is not stable under render/parse/render")
            }

            let dpdText = Decimal128TextCodec.dpd128ToString(bits)
            let d = dpdParse(dpdText)
            #expect(d.error == nil, "dpd \(Hex.format32(bits)) rendered <\(dpdText)>, which will not re-parse")
            if d.error == nil {
                #expect(Decimal128TextCodec.dpd128ToString(d.bits) == dpdText,
                        "dpd \(Hex.format32(bits)) is not stable under render/parse/render")
            }
        }
    }

    /// A parse followed by a render followed by a parse reaches a fixed point,
    /// for the whole accepted grammar rather than only for canonical text.
    @Test("parse is idempotent through a render")
    func parseRenderParseIsAFixedPoint() {
        for text in [
            "0", "-0", "0.00", "1", "-1.5", "6.02E+23", "1e1_0", "1_2_3",
            "0.0000000000000000000000000000000001",
            "12345678901234567890123456789012349",
            "9.999999999999999999999999999999999E+6144",
            "1E6145", "1E-6300", "15E-6177", "1E-6176", "-1E-6176",
            "Infinity", "-inf", "NaN", "qNaN(7)", "-sNaN12345",
            "NaN" + String(repeating: "9", count: 33),
        ] {
            for isBid in [true, false] {
                let parse = isBid ? bidParse : dpdParse
                let render = isBid
                    ? Decimal128TextCodec.bid128ToString
                    : Decimal128TextCodec.dpd128ToString
                let first = parse(text)
                #expect(first.error == nil, "rejected <\(text)>: \(first.error ?? "")")
                let rendered = render(first.bits)
                let second = parse(rendered)
                #expect(second.error == nil, "rejected <\(rendered)>: \(second.error ?? "")")
                #expect(second.bits == first.bits, "<\(text)> -> <\(rendered)> is not a fixed point")
            }
        }
    }

    /// The `UInt128` boundary: the sign is the top bit of the value, which is
    /// what makes a one-value boundary equivalent to the reference's word pair.
    @Test("the sign bit is the top bit of the UInt128")
    func signBitIsTheTopBit() {
        for text in ["1", "0", "1.5E+300", "Infinity", "NaN", "sNaN9"] {
            let positive = bidParse(text).bits
            let negative = bidParse("-" + text).bits
            #expect(positive >> 127 == 0, "<\(text)>")
            #expect(negative >> 127 == 1, "<-\(text)>")
            #expect(negative == positive | (UInt128(1) << 127), "<-\(text)> is not <\(text)> plus the sign bit")
        }
    }
}
