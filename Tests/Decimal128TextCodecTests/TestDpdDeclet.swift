// SPDX-License-Identifier: MIT
import Testing

@testable import Decimal128TextCodec

// This file used to also carry DPD render and parse vector tables, and the
// non-canonical declet suite. All of it is gone: the vectors were a hand-copied
// sample of the shared `text_bid_dpd` corpus, which `TestCorpusVectors` and
// `TestCanonicalCorpus` now read in full, and the non-canonical behaviour is
// covered there too -- the `noncanonical` table carries 462 DPD-declet rows
// asserting that each renders as its canonical spelling, 96 NaN don't-care rows,
// and 12 infinity-with-junk rows. Every one of the 24 redundant declets appears
// in it. The two remaining claims of that suite -- that the 24 are genuinely
// non-canonical, and that encoding never emits one -- are proved exhaustively
// below rather than over a sample.
//
// What is left needs no corpus at all.

/// Exhaustive tests for the DPD declet primitives.
///
/// A declet is 10 bits, so the entire input domain is 1024 values for decode and
/// 1000 for encode. These enumerate both completely: no sampling, and no oracle
/// needed beyond the format's own definition.
@Suite
struct TestDpdDeclet {

    @Test("every declet decodes into 0...999")
    func everyDecletDecodesInRange() {
        for declet in UInt64(0)...1023 {
            let v = Decimal128TextCodec.dpdDecodeDeclet(declet)
            #expect(v <= 999, "declet \(declet) decoded to \(v), out of 0...999")
        }
    }

    @Test("every value encodes into ten bits")
    func everyValueEncodesToTenBits() {
        for n in UInt64(0)...999 {
            let d = Decimal128TextCodec.dpdEncodeDeclet(n)
            #expect(d <= 1023, "value \(n) encoded to \(d), wider than 10 bits")
        }
    }

    /// encode is a right inverse of decode over the whole value domain.
    @Test("decode(encode(n)) == n")
    func encodeThenDecodeIsIdentity() {
        for n in UInt64(0)...999 {
            #expect(Decimal128TextCodec.dpdDecodeDeclet(Decimal128TextCodec.dpdEncodeDeclet(n)) == n)
        }
    }

    /// Every value 0..999 is reachable, and exactly 1000 of the 1024 declets are
    /// canonical. The other 24 are the non-canonical encodings: they decode to a
    /// legal value, but re-encoding yields the canonical declet instead.
    @Test("1000 canonical declets, 24 non-canonical, every value reachable")
    func canonicalAndNonCanonicalDecletsAreAccountedFor() {
        var seen = Set<UInt64>()
        var canonical = 0
        var nonCanonical = 0
        for declet in UInt64(0)...1023 {
            let v = Decimal128TextCodec.dpdDecodeDeclet(declet)
            seen.insert(v)
            if Decimal128TextCodec.dpdEncodeDeclet(v) == declet {
                canonical += 1
            } else {
                nonCanonical += 1
            }
        }
        #expect(seen.count == 1000, "not every value in 0...999 is reachable")
        #expect(canonical == 1000)
        #expect(nonCanonical == 24)
    }

    /// Zero must round-trip as the all-zero declet, not merely as some encoding
    /// of 0.
    @Test("zero is the all-zero declet")
    func zeroIsTheAllZeroDeclet() {
        #expect(Decimal128TextCodec.dpdEncodeDeclet(0) == 0)
        #expect(Decimal128TextCodec.dpdDecodeDeclet(0) == 0)
    }

    /// Regression pins on specific encodings.
    ///
    /// `9` and `999` were derived by hand from Cowlishaw's bcd2dpd equations to
    /// confirm the rest: for 999 all three digits are 1001, giving
    /// `pqrstuvwxy = 0011111111` = 0x0FF; for 9 only `v` and `y` are set, giving
    /// 0x009. The remainder are here to catch drift, not to independently prove
    /// the equations — the exhaustive properties above do that.
    @Test("known declet encodings")
    func knownDecletEncodings() {
        #expect(Decimal128TextCodec.dpdEncodeDeclet(9) == 0x009)     // hand-derived
        #expect(Decimal128TextCodec.dpdEncodeDeclet(999) == 0x0FF)   // hand-derived
        #expect(Decimal128TextCodec.dpdEncodeDeclet(5) == 0x005)
        #expect(Decimal128TextCodec.dpdEncodeDeclet(8) == 0x008)
        #expect(Decimal128TextCodec.dpdEncodeDeclet(57) == 0x057)
        #expect(Decimal128TextCodec.dpdEncodeDeclet(98) == 0x05E)
        #expect(Decimal128TextCodec.dpdEncodeDeclet(198) == 0x0DE)
        #expect(Decimal128TextCodec.dpdEncodeDeclet(321) == 0x1A1)
        #expect(Decimal128TextCodec.dpdEncodeDeclet(399) == 0x1DF)
    }
}

/// Non-canonical DPD128 encodings.
///
