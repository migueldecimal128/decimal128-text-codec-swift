// SPDX-License-Identifier: MIT
//
// Every arithmetic operator in this file is wrapping -- `&+` / `&-` / `&*`.
// Swift traps on overflow, and this codec's arithmetic is modular by design;
// the sites where a value is allowed to wrap and then be discarded carry a note
// saying why the wrapped value is harmless. Division stays checked: Swift has no
// wrapping `/`, and no divisor reachable here is zero.
//
// Everything reachable from outside is the functions on the type below;
// the rest is `private`.

/// Thin codec between the two IEEE 754-2019 decimal128 interchange encodings —
/// BID (Binary Integer Decimal) and DPD (Densely Packed Decimal) — and decimal
/// character sequences.
///
/// A decimal128 encoding is 128 bits: a sign bit, a combination field and a
/// trailing significand field, laid out per IEEE 754-2019 §3.5.2. It crosses
/// this API as a `UInt128`. That is the entire boundary; there is no value
/// type, no context, no status flags.
///
/// This codec provides no arithmetic, no comparison and no field extraction.
/// For the full IEEE 754-2019 decimal128 implementation — arithmetic,
/// comparison, every rounding-direction attribute, IEEE status flags — see
/// https://decimal128.com.
///
/// ## Rounding
///
/// Rounding, where the text → bits direction requires it, is the IEEE 754-2019
/// `roundTiesToEven` attribute and is not configurable. IEEE 754-2019 §5.4.2
/// places `convertFromDecimalCharacter` under the applicable
/// rounding-direction attribute; this codec deliberately implements only the
/// ties-to-even case and is therefore a conforming subset of that operation.
/// Callers needing another rounding direction want the full library.
///
/// Output form is the GDAS `to-scientific-string` form and is not
/// configurable. Cohort information is preserved: `"1.00"` and `"1.0"` are
/// distinct outputs from distinct encodings of the same numerical value.
///
/// ## Round-trip behavior
///
/// The renderer's output round-trips exactly: parsing rendered text and
/// rendering it again reproduces that text, and rendering a canonical encoding
/// and parsing the result reproduces the original bits. Three classes of input
/// do not round-trip:
///
/// - **More than 34 significant digits** are accepted and rounded to 34 with
///   `roundTiesToEven`. The rounded value is encoded; the input text is not
///   preserved.
/// - **Magnitudes outside the representable range** overflow to `Infinity` or
///   underflow to a subnormal or zero, per IEEE 754-2019.
/// - **Non-canonical bit patterns** render as something the encoder would
///   never have emitted, so re-parsing yields the canonical pattern instead.
///
/// ## Non-canonical bit patterns
///
/// Not every 128-bit pattern is canonical. Each encoding has its own
/// non-canonical forms — patterns the encoder would never emit — and what
/// makes a pattern non-canonical is a property of that encoding, documented
/// where that encoding is decoded.
///
/// Neither renderer can fail on one: every 128-bit pattern renders as the
/// value IEEE 754-2019 assigns it. Decoding is one-way for such a pattern,
/// because the parsers emit only canonical encodings, so re-parsing the
/// rendered text yields bits that differ from the original. Non-canonical
/// patterns never arise from this codec's own parsers; they appear only when
/// encodings come from outside, such as network or file data.
///
/// ## Thread safety
///
/// All functions are pure and safe for concurrent use.
///
/// ## In this port
///
/// The renderers return a `String`; their `bid128ToAscii(_:_:)` and
/// `dpd128ToAscii(_:_:)` peers write into a caller-owned `[UInt8]` and return
/// a length, for callers who want no allocation. The parsers write through an
/// `inout` encoding and return `nil` on success, or a message on failure. The
/// implementation is one file with no dependency beyond the standard library.
public enum Decimal128TextCodec {

    // ------------------------------------------------------------------
    // Public API
    // ------------------------------------------------------------------

    /// Render a BID128 encoding as a decimal character sequence.
    ///
    /// The output is the GDAS `to-scientific-string` form: integer notation
    /// when the quantum exponent is zero (e.g. `"123"`), plain notation when
    /// the adjusted exponent is in the range -6 to 0 (e.g. `"123.45"`),
    /// normalized scientific notation otherwise (e.g. `"1.234E+5"`). The
    /// exponent sign is always written, as in `"6.02E+23"`. Cohort information
    /// is preserved: `"1.00"` and `"1.0"` are distinct outputs from distinct
    /// encodings of the same numerical value.
    ///
    /// Special values render as `"Infinity"`, `"-Infinity"`, `"NaN"` and
    /// `"sNaN"`, each with an optional sign and an optional payload suffix
    /// such as `"NaN123"`.
    ///
    /// The two interchange encodings differ only in how the coefficient is
    /// stored: BID128 as a binary integer, DPD128 as a leading digit plus
    /// eleven 10-bit declets. The sign and the 14-bit biased exponent are the
    /// same in both, and peer encodings of the same value render to identical
    /// text.
    ///
    /// This cannot fail. Every 128-bit pattern renders: a non-canonical BID128
    /// coefficient (≥ 10^34) renders as zero at the encoded exponent, and a
    /// NaN payload ≥ 10^33 renders as no payload, both per IEEE 754-2019
    /// §3.5.2.
    ///
    /// - Parameter bits: the BID128 encoding.
    /// - Returns: the decimal character sequence for `bits`.
    public static func bid128ToString(_ bits: UInt128) -> String {
        return String(unsafeUninitializedCapacity: MAX_LEN) { buf in
            decodeBid128toAscii(buf, hiWord(bits), loWord(bits))
        }
    }

    /// Render a DPD128 encoding as a decimal character sequence.
    ///
    /// The output is the GDAS `to-scientific-string` form: integer notation
    /// when the quantum exponent is zero (e.g. `"123"`), plain notation when
    /// the adjusted exponent is in the range -6 to 0 (e.g. `"123.45"`),
    /// normalized scientific notation otherwise (e.g. `"1.234E+5"`). The
    /// exponent sign is always written, as in `"6.02E+23"`. Cohort information
    /// is preserved: `"1.00"` and `"1.0"` are distinct outputs from distinct
    /// encodings of the same numerical value.
    ///
    /// Special values render as `"Infinity"`, `"-Infinity"`, `"NaN"` and
    /// `"sNaN"`, each with an optional sign and an optional payload suffix
    /// such as `"NaN123"`.
    ///
    /// The two interchange encodings differ only in how the coefficient is
    /// stored: BID128 as a binary integer, DPD128 as a leading digit plus
    /// eleven 10-bit declets. The sign and the 14-bit biased exponent are the
    /// same in both, and peer encodings of the same value render to identical
    /// text.
    ///
    /// This cannot fail. Every 128-bit pattern renders: a DPD128 coefficient
    /// is always in range, since a leading digit of at most 9 followed by
    /// eleven declets cannot reach 10^34; a NaN payload, carried in those same
    /// declets, is likewise always in range; and non-canonical declets decode
    /// to their value, per IEEE 754-2019 §3.5.2.
    ///
    /// - Parameter bits: the DPD128 encoding.
    /// - Returns: the decimal character sequence for `bits`.
    public static func dpd128ToString(_ bits: UInt128) -> String {
        return String(unsafeUninitializedCapacity: MAX_LEN) { buf in
            decodeDpd128toAscii(buf, hiWord(bits), loWord(bits))
        }
    }

    /// The exact bound on a rendered decimal128, in ASCII character bytes.
    ///
    /// The widest scientific form `-9.999...E-6143` is 1 sign, 1 digit, 1
    /// radix point, 33 digits, 1 `E`, 1 sign and 4 exponent digits; the widest
    /// plain form `-0.00000999...` is 1 sign, 1 zero, 1 radix point, 5 leading
    /// zeros and 34 digits. Each form reaches exactly 42.
    ///
    /// The plain form's five leading zeros are pinned by the GDAS rule that
    /// selects it only when the adjusted exponent is at least -6, which puts
    /// five zeros between the radix point and the first significant digit. The
    /// exponent field cannot exceed four digits inside decimal128's range, so
    /// neither number can drift without the format itself changing.
    ///
    /// Every write in the renderers is guarded against this bound. Sizing it
    /// exactly rather than generously is what turns those guards into real
    /// checks: with slack, an error in the arithmetic above would quietly
    /// consume the slack instead of firing.
    ///
    /// A buffer passed to `bid128ToAscii(_:_:)` must be at least this long.
    /// The C port's `D128TEXT_MAX_LEN` is one larger, because it writes a NUL
    /// and this does not.
    public static let MAX_LEN = 42

    /// Render a BID128 encoding into a caller-supplied buffer, allocating
    /// nothing.
    ///
    /// Writes the ASCII text into `out` starting at index 0 and returns its
    /// length; the text is `out[0..<n]`. No terminator is written. `out` must
    /// have at least `MAX_LEN` elements; a shorter one traps on entry rather
    /// than corrupting anything, so an undersized buffer is a caller bug that
    /// surfaces immediately — on every call, not only on the values that would
    /// have overflowed it.
    ///
    /// The text is identical to what `bid128ToString(_:)` returns, and this
    /// form is the one to reach for when the destination is bytes — a stream,
    /// a socket, a CSV or JSON writer — because it leaves nothing for the
    /// collector.
    ///
    /// The two interchange encodings differ only in how the coefficient is
    /// stored: BID128 as a binary integer, DPD128 as a leading digit plus
    /// eleven 10-bit declets. The sign and the 14-bit biased exponent are the
    /// same in both, and peer encodings of the same value render to identical
    /// text.
    ///
    /// - Parameters:
    ///   - out: the destination, at least `MAX_LEN` bytes.
    ///   - bits: the BID128 encoding.
    /// - Returns: the number of bytes written.
    public static func bid128ToAscii(_ out: inout [UInt8], _ bits: UInt128) -> Int {
        return out.withUnsafeMutableBufferPointer { buf in
            decodeBid128toAscii(buf, hiWord(bits), loWord(bits))
        }
    }

    /// Render a DPD128 encoding into a caller-supplied buffer, allocating
    /// nothing.
    ///
    /// Writes the ASCII text into `out` starting at index 0 and returns its
    /// length; the text is `out[0..<n]`. No terminator is written. `out` must
    /// have at least `MAX_LEN` elements; a shorter one traps on entry rather
    /// than corrupting anything, so an undersized buffer is a caller bug that
    /// surfaces immediately — on every call, not only on the values that would
    /// have overflowed it.
    ///
    /// The text is identical to what `dpd128ToString(_:)` returns, and this
    /// form is the one to reach for when the destination is bytes — a stream,
    /// a socket, a CSV or JSON writer — because it leaves nothing for the
    /// collector.
    ///
    /// The two interchange encodings differ only in how the coefficient is
    /// stored: BID128 as a binary integer, DPD128 as a leading digit plus
    /// eleven 10-bit declets. The sign and the 14-bit biased exponent are the
    /// same in both, and peer encodings of the same value render to identical
    /// text.
    ///
    /// - Parameters:
    ///   - out: the destination, at least `MAX_LEN` bytes.
    ///   - bits: the DPD128 encoding.
    /// - Returns: the number of bytes written.
    public static func dpd128ToAscii(_ out: inout [UInt8], _ bits: UInt128) -> Int {
        return out.withUnsafeMutableBufferPointer { buf in
            decodeDpd128toAscii(buf, hiWord(bits), loWord(bits))
        }
    }

    /// Parse a decimal character sequence into a BID128 encoding.
    ///
    /// Returns `nil` on success, with the encoding written to `out`. On
    /// failure returns a human-readable message and writes the canonical
    /// positive quiet NaN, so a caller who discards the message still observes
    /// a legal IEEE 754-2019 datum rather than a stale value. The exact
    /// wording of the message is not part of the contract and may change
    /// between versions.
    ///
    /// Accepted input:
    ///
    /// - Plain notation: `"0"`, `"-1.5"`, `"123.456"`, `"0.0001"`.
    /// - Scientific notation: `"1.5E10"`, `"-2.3e-7"`, `"6.02E+23"`. Both `E`
    ///   and `e` are accepted as the exponent separator.
    /// - Digit separators: `_` between two digits, in the coefficient or the
    ///   exponent (`"1_000"`, `"1.234_567"`, `"1e1_0"`). An underscore must be
    ///   both preceded and followed by a digit, so `"1_"`, `"_1"`, `"1__2"`,
    ///   `"1_.5"` and `"1._5"` are all rejected.
    /// - The case-insensitive words `Infinity`, `Inf`, `NaN`, `qNaN` and
    ///   `sNaN`, each with an optional sign and an optional NaN payload of
    ///   decimal digits (`"NaN123"`, `"-sNaN42"`). A payload may also be
    ///   parenthesised, as `"NaN(123)"`.
    ///
    /// The parenthesised payload form is positional and balanced: `(`
    /// immediately after the word, at least one digit, `)` last. `"NaN()"`,
    /// `"NaN(1"`, `"NaN(1)2(3)"`, `"NaN[1]"` and `"NaN{1}"` are rejected.
    /// Rendering never emits parentheses, and the full decimal128 ports accept
    /// the same spelling.
    ///
    /// More than 34 significant digits round to 34, ties-to-even. Magnitudes
    /// above the representable range become `Infinity`; magnitudes below it
    /// become a subnormal or zero. None of those are failures.
    ///
    /// Failures are structural: an empty sequence, unrecognized characters,
    /// missing digits around the radix point, a malformed exponent field.
    ///
    /// The two interchange encodings differ only in how the coefficient is
    /// stored: BID128 as a binary integer, DPD128 as a leading digit plus
    /// eleven 10-bit declets. The same text parses to peer encodings of the
    /// same value in either format, and the canonical positive quiet NaN is
    /// the same bit pattern in both.
    ///
    /// - Parameters:
    ///   - out: receives the BID128 encoding, or the canonical positive
    ///   quiet NaN on failure. Always written.
    ///   - text: the character sequence to parse.
    /// - Returns: `nil` on success, or a human-readable message on failure.
    public static func bid128Parse(_ out: inout UInt128, _ text: String) -> String? {
        var words: Words = (0, 0)
        let errorStr = encodeStringOrError(&words, formatIsBid: true, str: Array(text.utf8))
        if errorStr != nil {
            words = (QNAN_PATTERN_HI, 0)
        }
        out = joinWords(words)
        return errorStr
    }

    /// Parse a decimal character sequence into a DPD128 encoding.
    ///
    /// Returns `nil` on success, with the encoding written to `out`. On
    /// failure returns a human-readable message and writes the canonical
    /// positive quiet NaN, so a caller who discards the message still observes
    /// a legal IEEE 754-2019 datum rather than a stale value. The exact
    /// wording of the message is not part of the contract and may change
    /// between versions.
    ///
    /// Accepted input:
    ///
    /// - Plain notation: `"0"`, `"-1.5"`, `"123.456"`, `"0.0001"`.
    /// - Scientific notation: `"1.5E10"`, `"-2.3e-7"`, `"6.02E+23"`. Both `E`
    ///   and `e` are accepted as the exponent separator.
    /// - Digit separators: `_` between two digits, in the coefficient or the
    ///   exponent (`"1_000"`, `"1.234_567"`, `"1e1_0"`). An underscore must be
    ///   both preceded and followed by a digit, so `"1_"`, `"_1"`, `"1__2"`,
    ///   `"1_.5"` and `"1._5"` are all rejected.
    /// - The case-insensitive words `Infinity`, `Inf`, `NaN`, `qNaN` and
    ///   `sNaN`, each with an optional sign and an optional NaN payload of
    ///   decimal digits (`"NaN123"`, `"-sNaN42"`). A payload may also be
    ///   parenthesised, as `"NaN(123)"`.
    ///
    /// The parenthesised payload form is positional and balanced: `(`
    /// immediately after the word, at least one digit, `)` last. `"NaN()"`,
    /// `"NaN(1"`, `"NaN(1)2(3)"`, `"NaN[1]"` and `"NaN{1}"` are rejected.
    /// Rendering never emits parentheses, and the full decimal128 ports accept
    /// the same spelling.
    ///
    /// More than 34 significant digits round to 34, ties-to-even. Magnitudes
    /// above the representable range become `Infinity`; magnitudes below it
    /// become a subnormal or zero. None of those are failures.
    ///
    /// Failures are structural: an empty sequence, unrecognized characters,
    /// missing digits around the radix point, a malformed exponent field.
    ///
    /// The two interchange encodings differ only in how the coefficient is
    /// stored: BID128 as a binary integer, DPD128 as a leading digit plus
    /// eleven 10-bit declets. The same text parses to peer encodings of the
    /// same value in either format, and the canonical positive quiet NaN is
    /// the same bit pattern in both.
    ///
    /// - Parameters:
    ///   - out: receives the DPD128 encoding, or the canonical positive
    ///   quiet NaN on failure. Always written.
    ///   - text: the character sequence to parse.
    /// - Returns: `nil` on success, or a human-readable message on failure.
    public static func dpd128Parse(_ out: inout UInt128, _ text: String) -> String? {
        var words: Words = (0, 0)
        let errorStr = encodeStringOrError(&words, formatIsBid: false, str: Array(text.utf8))
        if errorStr != nil {
            words = (QNAN_PATTERN_HI, 0)
        }
        out = joinWords(words)
        return errorStr
    }

    // ------------------------------------------------------------------
    // Internal-state assertions
    //
    // Two mechanisms, and the split matters here for the same reason it does in
    // the C port.
    //
    //   verify   internal-consistency claims -- unreachable for ANY input, so a
    //            failure is a codec bug rather than bad data. Compiled out
    //            unless VERIFY_ENABLED is defined; Package.swift defines it for
    //            debug builds only, so a release consumer never takes a trap
    //            inside the library on data they do not control.
    //
    //   demand   buffer-sizing and invariant claims that guard a write or an
    //            encode. In Kotlin the equivalent violation throws; here it
    //            traps, and it stays live in every configuration because the
    //            alternative is silently encoding an out-of-range value.
    // ------------------------------------------------------------------

    @inline(__always)
    private static func verify(_ condition: @autoclosure () -> Bool,
                               _ message: @autoclosure () -> String = "invariant",
                               file: StaticString = #fileID, line: UInt = #line) {
        #if VERIFY_ENABLED
        if !condition() {
            fatalError("decimal128-text-codec: impossible state: \(message())", file: file, line: line)
        }
        #endif
    }

    @inline(__always)
    private static func demand(_ condition: @autoclosure () -> Bool,
                               _ message: @autoclosure () -> String = "invariant",
                               file: StaticString = #fileID, line: UInt = #line) {
        if !condition() {
            fatalError("decimal128-text-codec: impossible state: \(message())", file: file, line: line)
        }
    }

    // ------------------------------------------------------------------
    // The 128-bit boundary
    //
    // Public in, public out. Everything between these and the encoders works in
    // the reference's `dw1` / `dw0` word pair, which is what makes the two
    // files readable side by side.
    // ------------------------------------------------------------------

    /// The reference's `LongArray(2)`, as a value rather than a buffer:
    /// `hi` is the high 64 bits of an encoding, `lo` the low 64.
    private typealias Words = (hi: UInt64, lo: UInt64)

    @inline(__always)
    private static func hiWord(_ v: UInt128) -> UInt64 { UInt64(truncatingIfNeeded: v >> 64) }

    @inline(__always)
    private static func loWord(_ v: UInt128) -> UInt64 { UInt64(truncatingIfNeeded: v) }

    @inline(__always)
    private static func joinWords(_ w: Words) -> UInt128 { (UInt128(w.hi) << 64) | UInt128(w.lo) }

    // ------------------------------------------------------------------
    // Format constants -- IEEE 754-2019 Table 3.6, decimal128
    // ------------------------------------------------------------------

    private static let BIAS = 6176
    private static let Q_MIN = -6176 // the minimum quantum exponent
    private static let Q_MAX = 6111  // the maximum quantum exponent
    private static let T_WIDTH = 110 // trailing significand field width in bits
    private static let W5 = 17       // combination field width in bits

    /// The trailing-significand mask for the high word.
    ///
    /// The reference writes this as `(1L shl t) - 1L` with `t == 110` and leans
    /// on the JVM masking shift counts to 6 bits, which turns it into
    /// `(1 shl 46) - 1`. Swift's shift is not a masking shift -- `1 << 110` on a
    /// `UInt64` is 0, and subtracting 1 from that traps -- so the intended
    /// 46-bit mask is spelled out.
    private static let COEFF_T_HI_MASK: UInt64 = (UInt64(1) << (110 &- 64)) &- 1

    // 10^34, one past the largest coefficient; maxx = max eXclusive
    private static let MAXX_COEFF_34_HI: UInt64 = 0x0001_ED09_BEAD_87C0
    private static let MAXX_COEFF_34_LO: UInt64 = 0x378D_8E64_0000_0000

    // 10^33, the smallest 34-digit coefficient
    private static let MIN_PRECISION_34_COEFF_HI: UInt64 = 0x0000_314D_C644_8D93
    private static let MIN_PRECISION_34_COEFF_LO: UInt64 = 0x38C1_5B0A_0000_0000

    // 33 nines -- the largest canonical NaN payload
    private static let MAX_PAYLOAD_HI = MIN_PRECISION_34_COEFF_HI
    private static let MAX_PAYLOAD_LO = MIN_PRECISION_34_COEFF_LO &- 1

    private static let SIGN_BIT: UInt64 = 0x8000_0000_0000_0000
    private static let INF_PATTERN_HI: UInt64 = 0x7800_0000_0000_0000
    private static let QNAN_PATTERN_HI: UInt64 = 0x7C00_0000_0000_0000
    private static let SNAN_PATTERN_HI: UInt64 = 0x7E00_0000_0000_0000

    private static let TEN_POW_15: UInt64 = 1_000_000_000_000_000
    private static let TEN_POW_18: UInt64 = 1_000_000_000_000_000_000

    private static let ascii_minus: UInt8 = 0x2D
    private static let ascii_plus: UInt8 = 0x2B
    private static let ascii_0: UInt8 = 0x30
    private static let ascii_dot: UInt8 = 0x2E
    private static let ascii_E: UInt8 = 0x45

    // ----------------------------------------------------------------------
    // Rendering into a buffer
    //
    // The renderers proper, and the only ones. Every form is produced here,
    // into a buffer the caller owns; the two String entry points wrap these
    // with `String(unsafeUninitializedCapacity:)`, which builds straight into
    // the String's own storage.
    //
    // A set of String-returning peers used to sit above these to short-circuit
    // three constants -- "Infinity", a bare NaN and every plain-form zero, all
    // 15 bytes or fewer and so small-form strings costing neither an allocation
    // nor a retain. Keeping them meant a second copy of the field extraction
    // and class dispatch per encoding, kept in step only by the corpus running
    // both forms past the same expected text. One renderer per encoding is
    // worth more than the constants: a capacity of MAX_LEN is past the
    // small-form limit, so every String result now allocates.
    //
    // None of the optional leading characters live in the string data. The
    // sign, and the `s` that marks a signaling NaN, are each written
    // unconditionally and then overwritten by whatever follows when they are
    // not wanted. The one exception is a TRAILING `+` in the exponent-form
    // zero, noted where it happens.
    // ----------------------------------------------------------------------

    private static let ascii_s: UInt8 = 0x73

    /// Render a BID128 encoding into the caller's buffer.
    ///
    /// Field extraction follows IEEE 754-2019 §3.5.2; the class it lands on --
    /// Infinity, NaN (quiet or signaling, with optional payload), zero
    /// (canonical or non-canonical), or finite non-zero -- picks the leaf
    /// renderer. ``bid128ToString(_:)`` and ``bid128ToAscii(_:_:)`` both wrap
    /// what this writes.
    private static func decodeBid128toAscii(_ ascii: UnsafeMutableBufferPointer<UInt8>,
                                            _ bid128Hi: UInt64, _ bid128Lo: UInt64) -> Int {
        // IEEE754-2019 Table 3.6 -- Decimal interchange format parameters, p 23
        let k = 128       // storage width in bits
        let t = T_WIDTH   // trailing significand field width in bits
        verify(1 &+ W5 &+ t == k)
        // The API's contract is a buffer of at least MAX_LEN, so that is what is
        // checked -- once, on every call, rather than per value. A shorter buffer
        // that happens to fit the value in hand is still a caller bug, and one
        // that would otherwise surface only on the data that overflows it. The
        // sibling ports get this from the parameter's type; Swift takes a
        // [UInt8] of any size, so it is enforced here.
        demand(ascii.count >= MAX_LEN, "the buffer is at least MAX_LEN bytes")

        // 1 + 17 + 110 == 128
        // 1 bit for the sign
        let sign = (bid128Hi & SIGN_BIT) != 0
        // w5 bit combination field ... for bid128 0x1FFFF
        let combination = Int((bid128Hi >> (t &- 64)) & 0x1FFFF)
        let coeffTHi = bid128Hi & COEFF_T_HI_MASK

        let coeffHi: UInt64
        let qExp: Int
        if (combination >> (W5 &- 2)) != 0b11 {
            //  IEEE754-2019 3.5.2 c) 2) i) -- p 21
            //   If G0 and G1 together are one of 00, 01, or 10, then the biased
            //   exponent E is formed from G0 through Gw+1 and the significand
            //   is formed from bits Gw+2 through the end of the encoding (including T).
            //
            // w+5=17 w=12 Gw+1=G13 Gw+2=G14
            // the top 14 bits of the combination field represent the biased exponent ...
            let biasedExponentE = combination >> 3
            qExp = biasedExponentE &- BIAS
            // ... and the bottom 3 bits are the most significant bits of the significand
            coeffHi = UInt64(combination & 0x07)
        } else if (combination >> (W5 &- 4)) != 0b1111 {
            // IEEE754-2019 3.5.2 c) 2) ii) -- p 21
            //  If G0 and G1 together are 11 and G2 and G3 together are one
            //  of 00, 01, or 10, then the biased exponent E is formed from
            //  G2 through Gw+3 and the significand is formed by prefixing
            //  the 4 bits (8 + Gw+4) to T.
            let biasedExponentE = (combination >> 1) & ((1 << (W5 &- 5 &+ 2)) &- 1)
            qExp = biasedExponentE &- BIAS
            coeffHi = 8 &+ UInt64(combination & 1)
        } else if (combination >> (W5 &- 5)) == 0b11110 {
            // if the top 5 bits are 0b11110 then Infinity
            return infBytes(ascii, sign)
        } else {
            // if the top 5 bits are 0b11111 then NaN,
            // with the next bit determining signaling NaN
            verify((combination >> (W5 &- 5)) == 0b11111)
            let isSignaling = ((combination >> (W5 &- 6)) & 1) != 0
            return nanBytes(ascii, sign, isSignaling, coeffTHi, bid128Lo)
        }

        let dw1 = (coeffHi << (t &- 64)) | coeffTHi
        let dw0 = bid128Lo
        // IEEE754-2019 3.5.2 p21
        //  If the value exceeds the maximum, the significand c is
        //  non-canonical and the value used for c is zero.
        if (dw1 | dw0) == 0 ||
            MAXX_COEFF_34_HI < dw1 ||
            (dw1 == MAXX_COEFF_34_HI && (MAXX_COEFF_34_LO &- 1) < dw0) {
            return zerBytes(ascii, sign, qExp)
        }
        return fnzBytes(ascii, sign, qExp, dw1, dw0)
    }

    /// Render a DPD128 encoding into the caller's buffer.
    ///
    /// The peer of ``decodeBid128toAscii(_:_:_:)``: both reduce an encoding to
    /// `(sign, qExp, coefficient)` and then dispatch to the same leaf
    /// renderers, which have never seen an interchange format.
    private static func decodeDpd128toAscii(_ ascii: UnsafeMutableBufferPointer<UInt8>,
                                            _ dpd128Hi: UInt64, _ dpd128Lo: UInt64) -> Int {
        let w = 12        // exponent continuation width
        let t = T_WIDTH   // trailing significand field width in bits
        // see decodeBid128toAscii: the API's contract is checked, not the value's
        demand(ascii.count >= MAX_LEN, "the buffer is at least MAX_LEN bytes")

        let sign = (dpd128Hi & SIGN_BIT) != 0
        let combination = Int((dpd128Hi >> (t &- 64)) & 0x1FFFF)
        // in DPD the low w bits of the biased exponent always sit at the bottom of G
        let expContinuation = combination & 0x0FFF

        let d0: UInt64
        let qExp: Int
        var isNaN = false
        var isSignaling = false

        if (combination >> (W5 &- 2)) != 0b11 {
            // G0G1 is 00, 01 or 10: leading digit 0..7, exponent MSBs in G0G1
            let expMSB = combination >> (W5 &- 2)
            qExp = ((expMSB << w) | expContinuation) &- BIAS
            d0 = UInt64((combination >> w) & 0b111)
        } else if (combination >> (W5 &- 4)) != 0b1111 {
            // G0G1 is 11 and G2G3 is not 11: leading digit 8..9, exponent MSBs in G2G3
            let expMSB = (combination >> (W5 &- 4)) & 0b11
            qExp = ((expMSB << w) | expContinuation) &- BIAS
            d0 = 8 &+ UInt64((combination >> w) & 0b1)
        } else if (combination >> (W5 &- 5)) == 0b11110 {
            return infBytes(ascii, sign)
        } else {
            verify((combination >> (W5 &- 5)) == 0b11111)
            isNaN = true
            isSignaling = ((combination >> (W5 &- 6)) & 1) != 0
            d0 = 0
            qExp = 0
        }

        // Rebuild the binary coefficient from the declets. The leading digit
        // rides along as a sixth declet of the high group: values 0..9 encode
        // to themselves as a declet, so it decodes back unchanged.
        let decletsHi = (d0 << 50) | ((dpd128Hi & 0x3FFF_FFFF_FFFF) << 4) | (dpd128Lo >> 60)
        let decletsLo = dpd128Lo & 0x0FFF_FFFF_FFFF_FFFF // low 60 bits, six declets
        let binHi = binFromDeclets(decletsHi)
        let binLo = binFromDeclets(decletsLo)

        let dw1: UInt64
        let dw0: UInt64
        if binHi == 0 {
            dw1 = 0
            dw0 = binLo
        } else {
            // binHi * 10^18 + binLo is a genuine 128-bit product: the low word
            // is the wrapping sum, and the carry out of it feeds the high word.
            dw0 = (binHi &* TEN_POW_18) &+ binLo
            let carry: UInt64 = dw0 < binLo ? 1 : 0
            dw1 = unsignedMulHi(binHi, TEN_POW_18) &+ carry
        }

        if isNaN {
            return nanBytes(ascii, sign, isSignaling, dw1, dw0)
        }
        if (dw1 | dw0) == 0 {
            return zerBytes(ascii, sign, qExp)
        }
        return fnzBytes(ascii, sign, qExp, dw1, dw0)
    }


    private static let INFINITY_TEXT = Array("Infinity".utf8)
    private static let NAN_TEXT = Array("NaN".utf8)
    private static let ZERO_EXP_TEXT = Array("0E".utf8)

    /// Every plain-form zero is a prefix of this literal. `k = -qExp` is the
    /// count of zeros after the radix point, so `k == 0` renders `"0"` with no
    /// radix point at all and `k >= 1` renders `"0."` followed by `k` zeros --
    /// lengths 1 and `k + 2`.
    private static let PLAIN_ZERO = Array("0.000000".utf8)

    private static func infBytes(_ ascii: UnsafeMutableBufferPointer<UInt8>, _ sign: Bool) -> Int {
        let signLen = sign ? 1 : 0
        let totalLen = signLen &+ INFINITY_TEXT.count
        demand(totalLen <= MAX_LEN, "Infinity fits the buffer")
        ascii[0] = ascii_minus // overwritten by the 'I' when unsigned
        for i in 0..<INFINITY_TEXT.count {
            ascii[signLen &+ i] = INFINITY_TEXT[i]
        }
        return totalLen
    }

    private static func nanBytes(_ ascii: UnsafeMutableBufferPointer<UInt8>, _ sign: Bool,
                                 _ isSignaling: Bool,
                                 _ payloadHi: UInt64, _ payloadLo: UInt64) -> Int {
        let signLen = sign ? 1 : 0
        let sLen = isSignaling ? 1 : 0
        let wordOff = signLen &+ sLen
        let baseLen = wordOff &+ NAN_TEXT.count
        demand(baseLen <= MAX_LEN, "the bare NaN fits the buffer")
        ascii[0] = ascii_minus   // overwritten by the 's' or the 'N' when unsigned
        ascii[signLen] = ascii_s // overwritten by the 'N' when quiet
        for i in 0..<NAN_TEXT.count {
            ascii[wordOff &+ i] = NAN_TEXT[i]
        }
        if (payloadHi | payloadLo) == 0 ||
            // non canonical IEEE 754-2019 3.5.2 c) 2)
            MAX_PAYLOAD_HI < payloadHi ||
            (payloadHi == MAX_PAYLOAD_HI && MAX_PAYLOAD_LO < payloadLo) {
            return baseLen
        }
        let digitLen = calcDigitLen128(payloadHi, payloadLo)
        let totalLen = baseLen &+ digitLen
        demand(totalLen <= MAX_LEN, "the NaN payload fits the buffer")
        u128ToAscii(digitLen, payloadHi, payloadLo, ascii, baseLen)
        return totalLen
    }

    private static func zerBytes(_ ascii: UnsafeMutableBufferPointer<UInt8>, _ sign: Bool,
                                 _ qExp: Int) -> Int {
        let signLen = sign ? 1 : 0
        if qExp <= 0 && qExp >= -6 {
            let k = -qExp
            let zeroLen = (k == 0) ? 1 : k &+ 2
            demand(signLen &+ zeroLen <= MAX_LEN, "the plain zero fits the buffer")
            ascii[0] = ascii_minus // overwritten by the '0' when unsigned
            for i in 0..<zeroLen {
                ascii[signLen &+ i] = PLAIN_ZERO[i]
            }
            return signLen &+ zeroLen
        }
        // A positive exponent needs an explicit '+'; a negative one prints its
        // own '-' from appendIntBytes. Write the '+' unconditionally and let
        // appendIntBytes land on top of it when qExp < 0 -- the same discipline
        // as the leading sign, pointed the other way. It is correct only
        // because appendIntBytes emits a '-' for a negative value and emits
        // nothing for a positive one, and because the plain form above has
        // already taken every qExp in [-6, 0], so this branch never sees zero.
        let plusLen = (qExp > 0) ? 1 : 0
        let baseLen = signLen &+ ZERO_EXP_TEXT.count &+ plusLen
        demand(baseLen &+ 6 <= MAX_LEN, "the exponent-form zero fits the buffer")
        ascii[0] = ascii_minus // overwritten by the '0' when unsigned
        for i in 0..<ZERO_EXP_TEXT.count {
            ascii[signLen &+ i] = ZERO_EXP_TEXT[i]
        }
        ascii[signLen &+ ZERO_EXP_TEXT.count] = ascii_plus // overwritten by the '-' when qExp < 0
        return baseLen &+ appendIntBytes(ascii, baseLen, qExp)
    }

    /// Write a signed decimal exponent at `off`, returning its length. The
    /// magnitude never exceeds 6176, so it is at most four digits.
    private static func appendIntBytes(_ ascii: UnsafeMutableBufferPointer<UInt8>,
                                       _ off: Int, _ v: Int) -> Int {
        var signLen = 0
        var magnitude = v
        if v < 0 {
            ascii[off] = ascii_minus
            signLen = 1
            magnitude = -v
        }
        let digitLen: Int
        if magnitude >= 1000 {
            digitLen = 4
        } else if magnitude >= 100 {
            digitLen = 3
        } else if magnitude >= 10 {
            digitLen = 2
        } else {
            digitLen = 1
        }
        renderTailDigitsBeforeIndex(digitLen, UInt64(magnitude), ascii, off &+ signLen &+ digitLen)
        return signLen &+ digitLen
    }

    private static func fnzBytes(_ ascii: UnsafeMutableBufferPointer<UInt8>, _ sign: Bool,
                                 _ qExp: Int, _ dw1: UInt64, _ dw0: UInt64) -> Int {
        let digitLen = calcDigitLen128(dw1, dw0)
        let eExp = qExp &+ (digitLen &- 1)
        if qExp == 0 {
            return fnzToIntegerBytes(ascii, sign, digitLen, dw1, dw0)
        }
        if qExp <= 0 && eExp >= -6 {
            return fnzToDecimalPointBytes(ascii, sign, qExp, digitLen, dw1, dw0)
        }
        return fnzToNormalizedScientificBytes(ascii, sign, qExp, digitLen, dw1, dw0)
    }

    /// Format a finite non-zero value with `qExp == 0` as a plain integer
    /// sequence: no radix point, no exponent.
    private static func fnzToIntegerBytes(_ ascii: UnsafeMutableBufferPointer<UInt8>, _ sign: Bool,
                                          _ digitLen: Int, _ dw1: UInt64, _ dw0: UInt64) -> Int {
        verify(digitLen > 0)
        let signLen = sign ? 1 : 0
        let totalLen = signLen &+ digitLen
        demand(totalLen <= MAX_LEN, "the integer form fits the buffer")
        // written unconditionally: when there is no sign the first digit
        // overwrites it, which is cheaper than branching
        ascii[0] = ascii_minus
        u128ToAscii(digitLen, dw1, dw0, ascii, signLen)
        return totalLen
    }

    /// Format a finite non-zero value in fixed-point notation, with an explicit
    /// radix point and the appropriate number of leading zeros — `"0.00012345"`.
    ///
    /// Renders the coefficient digits, then shifts the trailing digits right by
    /// one position to open a slot for the radix point. Leading zeros are
    /// written directly into the buffer before the digits.
    private static func fnzToDecimalPointBytes(_ ascii: UnsafeMutableBufferPointer<UInt8>, _ sign: Bool,
                                               _ qExp: Int, _ digitLen: Int,
                                               _ dw1: UInt64, _ dw0: UInt64) -> Int {
        let digitsRightOfDecimal = -qExp
        let leadingZeroCount = max(1 &+ digitsRightOfDecimal &- digitLen, 0)
        let signLen = sign ? 1 : 0
        let decimalPointLen = 1
        let totalLen = signLen &+ leadingZeroCount &+ decimalPointLen &+ digitLen
        demand(totalLen <= MAX_LEN, "the fixed-point form fits the buffer")
        ascii[0] = ascii_minus
        if signLen <= leadingZeroCount {
            for i in signLen...leadingZeroCount { // there is one extra here
                ascii[i] = ascii_0
            }
        }
        u128ToAscii(digitLen, dw1, dw0, ascii, signLen &+ leadingZeroCount)
        var i = totalLen &- 1
        while i >= totalLen &- digitsRightOfDecimal {
            ascii[i] = ascii[i &- 1]
            i &-= 1
        }
        ascii[totalLen &- digitsRightOfDecimal &- 1] = ascii_dot
        return totalLen
    }

    /// Format a finite non-zero value in normalized scientific notation —
    /// `"1.234E+5"`, `"-9.99E-200"`.
    ///
    /// Renders the coefficient digits, inserts a radix point after the leading
    /// digit when there is more than one, then appends `E`, the exponent sign
    /// and the absolute exponent. The sign is always written: `+` for
    /// non-negative exponents, `-` for negative, per the GDAS
    /// `to-scientific-string` form.
    private static func fnzToNormalizedScientificBytes(_ ascii: UnsafeMutableBufferPointer<UInt8>, _ sign: Bool,
                                                       _ qExp: Int, _ digitLen: Int,
                                                       _ dw1: UInt64, _ dw0: UInt64) -> Int {
        verify(digitLen > 0)
        let eExp = qExp &+ (digitLen &- 1)
        // the reference computes this branchlessly off a 32-bit sign shift;
        // Swift's Int is 64-bit and the exponent is bounded well inside it
        let eExpAbs = eExp < 0 ? -eExp : eExp
        let signLen = sign ? 1 : 0
        let decimalPointLen = digitLen > 1 ? 1 : 0
        let expELen = 1
        let expSignLen = 1
        let expSignByte = eExp < 0 ? ascii_minus : ascii_plus
        let expDigitLen: Int
        if eExpAbs >= 1000 {
            expDigitLen = 4
        } else if eExpAbs >= 100 {
            expDigitLen = 3
        } else if eExpAbs >= 10 {
            expDigitLen = 2
        } else {
            expDigitLen = 1
        }
        let totalLen = signLen &+ decimalPointLen &+ digitLen &+ expELen &+ expSignLen &+ expDigitLen
        demand(totalLen <= MAX_LEN, "the scientific form fits the buffer")
        ascii[0] = ascii_minus
        u128ToAscii(digitLen, dw1, dw0, ascii, signLen &+ decimalPointLen)
        if decimalPointLen > 0 {
            ascii[signLen] = ascii[signLen &+ 1]
            ascii[signLen &+ 1] = ascii_dot
        }
        let iE = signLen &+ decimalPointLen &+ digitLen
        ascii[iE] = ascii_E
        ascii[iE &+ 1] = expSignByte
        renderTailDigitsBeforeIndex(expDigitLen, UInt64(eExpAbs), ascii, totalLen)
        return totalLen
    }

    // ==================================================================
    // MARK: - Render an integer
    // ==================================================================

    /// Reciprocal-multiplication constants for unsigned `÷ 10^8` on a 64-bit
    /// dividend, exact for every input.
    ///
    /// Compute `n / 10^8` as `unsignedMulHi(n, M_U64_DIV_1E8) >> S_U64_DIV_1E8`.
    /// The shift is "+ 64 high" because `unsignedMulHi` already returns the
    /// upper 64 bits of the 128-bit product; the named shift combines with that
    /// to give the effective magic-number divide.
    private static let M_U64_DIV_1E8: UInt64 = 0x8000_0000_0000_0000 | 0x2BCC_7711_8461_CEFD
    private static let S_U64_DIV_1E8: UInt64 = 26 // + 64 high

    private static let MASK32: UInt64 = 0x0000_0000_FFFF_FFFF

    /// Render a 128-bit unsigned integer as `digitPrintCount` decimal digits
    /// into `ascii`, ending at offset `off + digitPrintCount`.
    ///
    /// Three phases:
    ///
    ///  1. While `dw1T != 0`: peel 8 digits per outer iteration via three
    ///     `÷ 10^8` divisions on rotating 96-bit chunks, using ``unsignedMulHi``
    ///     for the high half of each multi-word divide.
    ///  2. Once the value fits in 64 bits: peel 8 digits at a time via a single
    ///     `÷ 10^8` per iteration.
    ///  3. For 1–7 leftover digits: delegate to ``renderTailDigitsBeforeIndex``.
    ///
    /// The caller must have allocated at least `off + digitPrintCount` bytes and
    /// is responsible for any leading-zero padding outside the rendered range.
    @discardableResult
    private static func u128ToAscii(_ digitPrintCount: Int, _ dw1: UInt64, _ dw0: UInt64,
                                    _ ascii: UnsafeMutableBufferPointer<UInt8>, _ off: Int) -> Int {
        var dw1T = dw1
        var dw0T = dw0
        var ich = off &+ digitPrintCount
        var remainingDigitCount = digitPrintCount
        while dw1T != 0 {
            let q2 = unsignedMulHi(dw1T, M_U64_DIV_1E8) >> S_U64_DIV_1E8
            let r2 = dw1T &- (q2 &* 100_000_000)
            let s2 = (r2 << 32) | (dw0T >> 32)
            let q1 = unsignedMulHi(s2, M_U64_DIV_1E8) >> S_U64_DIV_1E8
            let r1 = s2 &- (q1 &* 100_000_000)
            let s1 = (r1 << 32) | (dw0T & MASK32)
            let q0 = unsignedMulHi(s1, M_U64_DIV_1E8) >> S_U64_DIV_1E8
            let r0 = s1 &- (q0 &* 100_000_000)
            // q1 and q0 are each strictly below 2^32 -- r2 and r1 are remainders
            // mod 10^8 -- so this recombination cannot overflow
            dw0T = (q1 << 32) &+ q0
            dw1T = q2
            render8DigitsBeforeIndex(r0, ascii, ich)
            ich &-= 8
            remainingDigitCount &-= 8
        }
        while remainingDigitCount >= 8 {
            let t0 = unsignedMulHi(dw0T, M_U64_DIV_1E8) >> S_U64_DIV_1E8
            let r0 = dw0T &- (t0 &* 100_000_000)
            dw0T = t0
            render8DigitsBeforeIndex(r0, ascii, ich)
            ich &-= 8
            remainingDigitCount &-= 8
        }
        if remainingDigitCount > 0 {
            renderTailDigitsBeforeIndex(remainingDigitCount, dw0T, ascii, ich)
        }
        return digitPrintCount
    }

    /// Reciprocal-multiplication constants for unsigned division by small powers
    /// of 10.
    ///
    /// `M_U32_DIV_1E1` / `S_U32_DIV_1E1` divide by 10 and `M_U32_DIV_1E2` /
    /// `S_U32_DIV_1E2` by 100, both valid for 32-bit dividends.
    /// `M_U64_DIV_1E4` / `S_U64_DIV_1E4` divide by 10000 on 64-bit dividends and
    /// are used to split an 8-digit value into two 4-digit halves.
    private static let M_U32_DIV_1E1: UInt64 = 0xCCCC_CCCD
    private static let S_U32_DIV_1E1: UInt64 = 35

    private static let M_U32_DIV_1E2: UInt64 = 0x51EB_851F
    private static let S_U32_DIV_1E2: UInt64 = 37

    private static let M_U64_DIV_1E4: UInt64 = 0x346D_C5D6_3886_594B
    private static let S_U64_DIV_1E4: UInt64 = 11 // + 64 high

    /// Render exactly 8 decimal digits of `dw` into `ascii`, ending at
    /// `offMaxx`. The caller must ensure `dw < 10^8`; fewer significant digits
    /// are padded with leading zeros.
    ///
    /// A binary cascade: `÷ 10^4` once to split into two 4-digit halves, then
    /// `÷ 10^2` twice to split each half into 2-digit pairs, then `÷ 10` four
    /// times for the individual digits.
    private static func render8DigitsBeforeIndex(_ dw: UInt64, _ ascii: UnsafeMutableBufferPointer<UInt8>, _ offMaxx: Int) {
        let abcd = unsignedMulHi(dw, M_U64_DIV_1E4) >> S_U64_DIV_1E4
        let efgh = dw &- (abcd &* 10000)

        let ab = (abcd &* M_U32_DIV_1E2) >> S_U32_DIV_1E2
        let cd = abcd &- (ab &* 100)

        let ef = (efgh &* M_U32_DIV_1E2) >> S_U32_DIV_1E2
        let gh = efgh &- (ef &* 100)

        let a = (ab &* M_U32_DIV_1E1) >> S_U32_DIV_1E1
        let b = ab &- (a &* 10)

        let c = (cd &* M_U32_DIV_1E1) >> S_U32_DIV_1E1
        let d = cd &- (c &* 10)

        let e = (ef &* M_U32_DIV_1E1) >> S_U32_DIV_1E1
        let f = ef &- (e &* 10)

        let g = (gh &* M_U32_DIV_1E1) >> S_U32_DIV_1E1
        let h = gh &- (g &* 10)

        demand(offMaxx &- 8 >= 0, "the eight digits are inside the buffer")
        ascii[offMaxx &- 8] = ascii_0 &+ UInt8(truncatingIfNeeded: a)
        ascii[offMaxx &- 7] = ascii_0 &+ UInt8(truncatingIfNeeded: b)
        ascii[offMaxx &- 6] = ascii_0 &+ UInt8(truncatingIfNeeded: c)
        ascii[offMaxx &- 5] = ascii_0 &+ UInt8(truncatingIfNeeded: d)
        ascii[offMaxx &- 4] = ascii_0 &+ UInt8(truncatingIfNeeded: e)
        ascii[offMaxx &- 3] = ascii_0 &+ UInt8(truncatingIfNeeded: f)
        ascii[offMaxx &- 2] = ascii_0 &+ UInt8(truncatingIfNeeded: g)
        ascii[offMaxx &- 1] = ascii_0 &+ UInt8(truncatingIfNeeded: h)
    }

    /// Render exactly `renderDigitCount` decimal digits of `dw` into `ascii`,
    /// ending at `offMaxx`. Fewer significant digits are padded with leading
    /// zeros.
    ///
    /// Two phases: peel 4 digits per iteration while at least 4 remain, then one
    /// digit at a time for the remaining 0–3.
    ///
    /// Kept `private` here. It is public in the legacy base this family
    /// descends from, which was an accidental leak — nothing outside the codec
    /// ever called it.
    private static func renderTailDigitsBeforeIndex(_ renderDigitCount: Int, _ dw: UInt64,
                                                    _ ascii: UnsafeMutableBufferPointer<UInt8>, _ offMaxx: Int) {
        var t = dw
        var remainingDigitCount = renderDigitCount
        var ib = offMaxx
        demand(offMaxx &- renderDigitCount >= 0, "the digits are inside the buffer")
        while remainingDigitCount >= 4 {
            let t0 = unsignedMulHi(t, M_U64_DIV_1E4) >> S_U64_DIV_1E4
            let abcd = t &- (t0 &* 10000)
            t = t0
            let ab = (abcd &* M_U32_DIV_1E2) >> S_U32_DIV_1E2
            let cd = abcd &- (ab &* 100)
            let a = (ab &* M_U32_DIV_1E1) >> S_U32_DIV_1E1
            let b = ab &- (a &* 10)
            let c = (cd &* M_U32_DIV_1E1) >> S_U32_DIV_1E1
            let d = cd &- (c &* 10)
            ascii[ib &- 4] = ascii_0 &+ UInt8(truncatingIfNeeded: a)
            ascii[ib &- 3] = ascii_0 &+ UInt8(truncatingIfNeeded: b)
            ascii[ib &- 2] = ascii_0 &+ UInt8(truncatingIfNeeded: c)
            ascii[ib &- 1] = ascii_0 &+ UInt8(truncatingIfNeeded: d)
            ib &-= 4
            remainingDigitCount &-= 4
        }
        while remainingDigitCount > 0 {
            let divTen = (t &* M_U32_DIV_1E1) >> S_U32_DIV_1E1
            let digit = t &- (divTen &* 10)
            ib &-= 1
            ascii[ib] = ascii_0 &+ UInt8(truncatingIfNeeded: digit)
            t = divTen
            remainingDigitCount &-= 1
        }
        verify(offMaxx &- ib == renderDigitCount)
    }

    // ==================================================================
    // MARK: - Encode: text -> encoding
    // ==================================================================

    private static let ascii_9: UInt8 = 0x39
    private static let ascii_e: UInt8 = 0x65
    private static let ascii_underscore: UInt8 = 0x5F
    private static let ascii_lparen: UInt8 = 0x28
    private static let ascii_rparen: UInt8 = 0x29

    /// Read the byte at `pos` and advance, or return NUL at end of input.
    ///
    /// The reference reads a Kotlin `String` through a `getOrNul` accessor that
    /// yields NUL forever past the end. Swift strings are not randomly indexable
    /// by integer, so the public entry points hand the parser the UTF-8 bytes
    /// once and this reads those. Every byte a numeral can contain is ASCII, so
    /// a multi-byte sequence arrives as bytes >= 0x80 and is rejected as an
    /// unrecognized character, which is the same answer the reference gives.
    @inline(__always)
    private static func chAt(_ str: [UInt8], _ pos: inout Int) -> UInt8 {
        if pos < str.count {
            let c = str[pos]
            pos &+= 1
            return c
        }
        return 0
    }

    @inline(__always)
    private static func isDigit(_ ch: UInt8) -> Bool { (ch >= ascii_0 && ch <= ascii_9) }

    /// Top-level dispatcher. Reads an optional sign, then dispatches by leading
    /// character to the finite-value, infinity or NaN parser.
    ///
    /// The leading character is passed through to the dispatched parser so it
    /// does not have to re-read what the dispatcher already consumed.
    private static func encodeStringOrError(_ out: inout Words, formatIsBid: Bool, str: [UInt8]) -> String? {
        var pos = 0
        let chFirst = chAt(str, &pos)
        var ch = chFirst
        let sign = (ch == ascii_minus)
        if (ch == ascii_plus || ch == ascii_minus) {
            ch = chAt(str, &pos)
        }
        if (isDigit(ch) || ch == ascii_dot) {
            return parseFiniteValueText(&out, formatIsBid, sign, ch, str, pos)
        }
        let chLower = ch | 0x20
        if (chLower == UInt8(ascii: "i")) {
            return parseInfinityText(&out, sign, ch, str, pos)
        }
        if (chLower == UInt8(ascii: "n") || chLower == UInt8(ascii: "s") || chLower == UInt8(ascii: "q")) {
            return parseNanText(&out, formatIsBid, sign, ch, str, pos)
        }
        if (chFirst == 0) {
            return "empty string"
        }
        return "invalid format"
    }

    /// Parse the keyword `Infinity`, or its 3-letter abbreviation `Inf`,
    /// case-insensitively.
    private static func parseInfinityText(_ out: inout Words, _ sign: Bool, _ chFirst: UInt8,
                                          _ str: [UInt8], _ startPos: Int) -> String? {
        var pos = startPos
        var ch = chFirst
        var chPrevCode: UInt8 = 0
        let target = Array("infinity".utf8)
        for i in 0..<8 {
            let targetCode = target[i]
            if ((ch | 0x20) != targetCode) {
                if (ch == 0) {
                    break
                } else {
                    return "failure parsing infinity"
                }
            }
            chPrevCode = ch | 0x20
            ch = chAt(str, &pos)
        }
        if (ch != 0 || (chPrevCode != UInt8(ascii: "f") && chPrevCode != UInt8(ascii: "y"))) {
            return "failure parsing Infinity"
        }
        out = (INF_PATTERN_HI | (sign ? SIGN_BIT : 0), 0)
        return nil
    }

    /// Parse `NaN`, `qNaN` or `sNaN` -- case-insensitive -- with an optional
    /// decimal payload.
    ///
    /// Payloads of 34+ digits AS WRITTEN are non-canonical and produce a zero
    /// payload per IEEE 754-2019 3.5.2.
    ///
    /// The payload may be written bare (`NaN123`) or enclosed in parentheses
    /// (`NaN(123)`). The parenthesised form is positional and balanced: the `(`
    /// must follow the word immediately, at least one digit must appear, and the
    /// `)` must be the last character of the input. So `NaN(1)2(3)`, `NaN(1`,
    /// `NaN(1]` and `NaN()` are all rejected, and `NaN[1]` / `NaN{1}` are not
    /// this form at all.
    ///
    /// The full decimal128 ports accept the same spelling; the codecs had it
    /// first, and the ports took it on 2026-08-23. The reason it exists at all
    /// is that C's own `strtod` reads
    /// `NAN(n-char-sequence)`, so the spelling reaches a caller from the
    /// platform itself. The resemblance stops at the parentheses -- strtod's
    /// sequence is letters, digits and underscores read as an
    /// implementation-defined integer (`NAN(abc)` and `NAN(0x1c8)` are legal
    /// there), while a decimal128 payload is decimal digits. This is a
    /// paren-tolerant spelling of our own payload syntax, not C's.
    ///
    /// The legacy base this family descends from skipped `(`, `)`, `[`, `]`, `{`
    /// and `}` ANYWHERE, so it read `NaN(1)2(3)` as payload 123. That is not
    /// this, and stays rejected.
    private static func parseNanText(_ out: inout Words, _ formatIsBid: Bool, _ sign: Bool,
                                     _ chFirst: UInt8, _ str: [UInt8], _ startPos: Int) -> String? {
        var pos = startPos
        var ch = chFirst
        let hasS = ((ch | 0x20) == UInt8(ascii: "s"))
        let hasQ = ((ch | 0x20) == UInt8(ascii: "q"))
        if (hasQ || hasS) {
            ch = chAt(str, &pos)
        }
        if ((ch | 0x20) != UInt8(ascii: "n") ||
            (chAt(str, &pos) | 0x20) != UInt8(ascii: "a") ||
            (chAt(str, &pos) | 0x20) != UInt8(ascii: "n")) {
            return "failure parsing NaN"
        }
        var payloadDw0: UInt64 = 0
        var payloadDw1: UInt64 = 0
        ch = chAt(str, &pos)
        let hasParen = (ch == ascii_lparen)
        if (hasParen) {
            ch = chAt(str, &pos)
        }
        if (hasParen || ch != 0) {
            var accumDigitCount = 0
            var accum19a: UInt64 = 0
            var accum19b: UInt64 = 0
            while (isDigit(ch)) {
                let d = UInt64(ch &- ascii_0)
                // Count every digit written, leading zeros included. The
                // 33-digit limit below is a limit on the payload as spelled, not
                // on its significant digits, so "NaN" followed by forty zeros
                // and a one is over the limit and reads as zero. Leading zeros
                // contribute nothing to the accumulators, so the value of a
                // payload within the limit is unaffected.
                accumDigitCount &+= 1
                if (accumDigitCount <= 19) {
                    // at most 19 digits, and 10^19 - 1 fits a UInt64, so checked
                    accum19a = (accum19a &* 10) &+ d
                } else {
                    // Within the 33-digit limit this holds at most 14 digits
                    // and cannot wrap; past the limit it can, and the whole
                    // payload is discarded below, so the wrapped value is never
                    // read.
                    accum19b = (accum19b &* 10) &+ d
                }
                ch = chAt(str, &pos)
            }
            if (accumDigitCount == 0) {
                return hasParen ? "failure parsing NaN" : "non-digit NaN payload character"
            }
            if (hasParen) {
                // the ')' must be present and must end the input
                if (ch != ascii_rparen) {
                    return (ch == 0) ? "failure parsing NaN" : "non-digit NaN payload character"
                }
                if (chAt(str, &pos) != 0) {
                    return "failure parsing NaN"
                }
            } else if (ch != 0) {
                return "non-digit NaN payload character"
            }
            if (accumDigitCount > 33) {
                // IEEE754-2019 3.5.2 Encodings
                //  ... as the payload of a NaN). If the value exceeds the maximum,
                //  the significand c is non-canonical and the value used for c is zero.
                payloadDw0 = 0
                payloadDw1 = 0
            } else {
                payloadDw0 = accum19a
                payloadDw1 = 0
                if (accumDigitCount > 19) {
                    let pow10 = accumDigitCount &- 19
                    let p = u128FmaPow10(accum19a, pow10, accum19b)
                    payloadDw1 = p.hi
                    payloadDw0 = p.lo
                }
            }
        }
        out = setNaN(formatIsBid, sign, hasS, payloadDw1, payloadDw0)
        return nil
    }

    /// Parse a finite decimal numeral: an optional radix point, an optional
    /// `E`/`e` exponent with an optional sign, and any number of digits.
    ///
    /// Coefficients with more than 34 significant digits are accepted; leading
    /// zeros before a non-zero digit are flushed, and the digits past 34 are
    /// tracked as `residue` for the ties-to-even rounding that follows. Excess
    /// exponent magnitudes clamp to 9999, which is enough for the rounding logic
    /// to detect overflow or underflow.
    ///
    /// Sign comes from `sign`, already consumed by the dispatcher; `chFirst` is
    /// the first digit or `.` and is processed by the main loop.
    private static func parseFiniteValueText(_ out: inout Words, _ formatIsBid: Bool, _ sign: Bool,
                                             _ chFirst: UInt8, _ str: [UInt8], _ startPos: Int) -> String? {
        var pos = startPos
        var residue = EXACT

        var hasCoefficientDigit = false // have we seen any digits at all, including zero
        var significantDigitCount = 0   // does not count leading zeros
        var hasDot = false
        var expSign = false
        // an underscore is a digit separator: legal only between two digits,
        // so it must follow a digit and the next character must be a digit too
        var prevWasDigit = false
        var afterUnderscore = false

        verify(chFirst != 0)
        var ch = chFirst
        var fractionalDigitCount = 0
        var accum19a: UInt64 = 0
        var accum19b: UInt64 = 0
        var exp = 0

        while (isDigit(ch) || ch == ascii_dot || ch == ascii_underscore) {
            if (isDigit(ch)) {
                let d = Int(ch &- ascii_0)
                hasCoefficientDigit = true
                // count while flushing leading zeros. The reference does this
                // branchlessly off a 32-bit sign shift; Swift's Int is 64-bit,
                // so the same thing is said directly.
                if (significantDigitCount != 0 || d != 0) {
                    significantDigitCount &+= 1
                }
                if (significantDigitCount <= 19) {
                    // at most 19 digits, and 10^19 - 1 fits a UInt64, so checked
                    accum19a = (accum19a &* 10) &+ UInt64(d)
                } else if (significantDigitCount <= 34) {
                    // at most 15 more digits, so likewise checked
                    accum19b = (accum19b &* 10) &+ UInt64(d)
                } else if (significantDigitCount == 34 &+ 1) {
                    residue = residueFromDecimalDigit(d)
                } else {
                    residue = residueMerge(residue, residueFromDecimalDigit(d))
                }
                if (hasDot) {
                    fractionalDigitCount &+= 1
                }
                prevWasDigit = true
                afterUnderscore = false
            } else if (ch == ascii_underscore) {
                if (!prevWasDigit) {
                    return "invalid underscore location"
                }
                prevWasDigit = false
                afterUnderscore = true
            } else { // '.'
                if (afterUnderscore) {
                    return "invalid underscore location"
                }
                if (hasDot) {
                    return "double radix dot"
                }
                hasDot = true
                prevWasDigit = false
            }
            ch = chAt(str, &pos)
        }
        if (afterUnderscore) {
            return "invalid underscore location"
        }
        if (!hasCoefficientDigit) {
            return "no coefficient digit"
        }
        // this path has at least one digit
        if (ch == ascii_E || ch == ascii_e) {
            ch = chAt(str, &pos)
            if (ch == ascii_plus || ch == ascii_minus) {
                expSign = (ch == ascii_minus)
                ch = chAt(str, &pos)
            }
            var hasExpDigit = false
            var expSignificantDigitCount = 0
            prevWasDigit = false
            afterUnderscore = false
            while (isDigit(ch) || ch == ascii_underscore) {
                if (ch == ascii_underscore) {
                    if (!prevWasDigit) {
                        return "invalid underscore location"
                    }
                    prevWasDigit = false
                    afterUnderscore = true
                } else {
                    hasExpDigit = true
                    let eDigit = Int(ch &- ascii_0)
                    // count while flushing leading zeros
                    if (expSignificantDigitCount != 0 || eDigit != 0) {
                        expSignificantDigitCount &+= 1
                    }
                    // The clamp below discards `exp` entirely once more than
                    // 4 significant digits were written, which is strictly
                    // before it could wrap.
                    exp = (exp &* 10) &+ eDigit
                    prevWasDigit = true
                    afterUnderscore = false
                }
                ch = chAt(str, &pos)
            }
            if (afterUnderscore) {
                return "invalid underscore location"
            }
            if (!hasExpDigit) {
                return "no exponent digit"
            }
            // clamp exp to 9999 once after the loop
            if (expSignificantDigitCount > 4) {
                exp = 9999
            }
        }
        if (ch != 0) {
            return "unexpected char"
        }
        // we have at least one digit
        var dw0 = accum19a
        var dw1: UInt64 = 0
        if (significantDigitCount > 19) {
            let pow10 = min(34, significantDigitCount) &- 19
            let p = u128FmaPow10(accum19a, pow10, accum19b)
            dw1 = p.hi
            dw0 = p.lo
        }
        // At this point the coefficient is within precision, but the residue
        // still has to be rounded in, and a rounding rollover could move the
        // exponent. Excess digits to the right of the radix point and excess
        // digits beyond the precision limit pull the quantum exponent in
        // opposite directions, so both corrections land here.
        let signedExp = expSign ? -exp : exp
        let qExp = signedExp &- fractionalDigitCount &+ max(0, significantDigitCount &- 34)
        out = roundAndFinalizeFinite(formatIsBid, sign, qExp, dw1, dw0, residue)
        return nil
    }

    // ==================================================================
    // MARK: - Pack: (sign, qExp, coefficient) -> encoding
    // ==================================================================

    /// Pack a finite value into whichever interchange format the caller asked
    /// for. BID and DPD are peers: both carry the same sign, the same 14-bit
    /// biased exponent and the same 34-digit coefficient, and differ only in how
    /// that coefficient is laid out. Everything upstream of this point --
    /// rounding, clamping and the underflow region -- is format-neutral.
    private static func setFinite(_ formatIsBid: Bool, _ sign: Bool, _ qExp: Int,
                                  _ dw1: UInt64, _ dw0: UInt64) -> Words {
        return formatIsBid
            ? bid128SetFinite(sign, qExp, dw1, dw0)
            : dpd128SetFinite(sign, qExp, dw1, dw0)
    }

    /// Pack the sign, biased quantum exponent and 113-bit coefficient into the
    /// BID128 encoding.
    ///
    /// Always the short-form encoding -- combination-field top bits not `11` --
    /// which is correct for any canonical coefficient, since its top 3 bits
    /// necessarily fit in 0..7.
    private static func bid128SetFinite(_ sign: Bool, _ qExp: Int,
                                        _ dw1: UInt64, _ dw0: UInt64) -> Words {
        verify(qExp >= Q_MIN && qExp <= Q_MAX)
        verify(calcDigitLen128(dw1, dw0) <= 34)
        let qBiased = qExp &+ BIAS
        let s: UInt64 = sign ? SIGN_BIT : 0
        let g = UInt64(qBiased) << (3 &+ 46)
        return (s | g | dw1, dw0)
    }

    /// Pack a finite value into DPD128. The peer of ``bid128SetFinite``: same
    /// inputs, same sign bit, same 14-bit biased exponent, and a coefficient of
    /// the same 34 digits -- laid out as a leading digit carried in the
    /// combination field plus eleven declets.
    ///
    /// The leading digit cannot be packed independently of the exponent: DPD
    /// puts it in the same five-bit prefix as the exponent's top two bits, so
    /// unlike BID there is no shared "pack sign and exponent" step to factor out.
    private static func dpd128SetFinite(_ sign: Bool, _ qExp: Int,
                                         _ dw1: UInt64, _ dw0: UInt64) -> Words {
        verify(qExp >= Q_MIN && qExp <= Q_MAX)
        verify(calcDigitLen128(dw1, dw0) <= 34)

        // Split the coefficient into its low 18 digits and its high 16. Two
        // divisions by 10^9 rather than one by 10^18, so the existing 128-bit
        // kernel does the work and no wider machinery is needed.
        let step1 = u113DivModPow10Max9(dw1, dw0, 9)
        let step2 = u113DivModPow10Max9(step1.qHi, step1.qLo, 9)
        let binLo = (step2.rem &* 1_000_000_000) &+ step1.rem
        verify(step2.qHi == 0) // the high 16 digits fit in one word
        let binHi = step2.qLo

        // the top digit rides in the combination field; the other 15 are declets
        let d0 = binHi / TEN_POW_15
        let declets5Hi = decletsFromBin(binHi &- (d0 &* TEN_POW_15))
        let declets6Lo = decletsFromBin(binLo)
        verify(d0 <= 9)

        let biasedQExp = qExp &+ BIAS
        let expMSB = (biasedQExp >> 12) & 0x3
        let expLSB = biasedQExp & 0x0FFF
        let gPrefix = (d0 <= 7)
            ? (expMSB << 3) | Int(d0)                        // G0G1 = exponent MSBs
            : 0b11000 | (expMSB << 1) | (Int(d0) & 1)        // G0G1 = 11, digit is 8 or 9
        let signCombo = ((sign ? 1 : 0) << 17) | (gPrefix << 12) | expLSB

        return ((UInt64(signCombo) << 46) | (declets5Hi >> 4),
                (declets5Hi << 60) | declets6Lo)
    }

    /// Pack a NaN into whichever interchange format the caller asked for.
    ///
    /// A NaN payload is a coefficient, so the formats diverge here exactly as
    /// they do for finite values: BID keeps it as a binary integer, DPD as
    /// declets. Infinity by contrast has no coefficient, which is why it is
    /// byte-identical in both and needs no such split.
    private static func setNaN(_ formatIsBid: Bool, _ sign: Bool, _ isSignaling: Bool,
                               _ payloadDw1: UInt64, _ payloadDw0: UInt64) -> Words {
        return formatIsBid
            ? bid128SetNaN(sign, isSignaling, payloadDw1, payloadDw0)
            : dpd128SetNaN(sign, isSignaling, payloadDw1, payloadDw0)
    }

    private static func bid128SetNaN(_ sign: Bool, _ isSignaling: Bool,
                                     _ payloadDw1: UInt64, _ payloadDw0: UInt64) -> Words {
        let withoutPayload =
            (isSignaling ? SNAN_PATTERN_HI : QNAN_PATTERN_HI) | (sign ? SIGN_BIT : 0)
        return (withoutPayload | payloadDw1, payloadDw0)
    }

    /// Pack a NaN into DPD128. The payload occupies the whole 110-bit trailing
    /// field as eleven declets -- 33 digits, with no leading digit in the
    /// combination field, since G0..G4 are fixed at 11111 and G5 carries the
    /// signaling flag.
    private static func dpd128SetNaN(_ sign: Bool, _ isSignaling: Bool,
                                     _ payloadDw1: UInt64, _ payloadDw0: UInt64) -> Words {
        verify(calcDigitLen128(payloadDw1, payloadDw0) <= 33)

        let step1 = u113DivModPow10Max9(payloadDw1, payloadDw0, 9)
        let step2 = u113DivModPow10Max9(step1.qHi, step1.qLo, 9)
        let binLo = (step2.rem &* 1_000_000_000) &+ step1.rem
        verify(step2.qHi == 0) // a 33-digit payload leaves 15 digits up top
        let declets5Hi = decletsFromBin(step2.qLo)
        let declets6Lo = decletsFromBin(binLo)

        let gField = (0b11111 << 12) | (isSignaling ? 1 << 11 : 0)
        let signCombo = ((sign ? 1 : 0) << 17) | gField
        return ((UInt64(signCombo) << 46) | (declets5Hi >> 4),
                (declets5Hi << 60) | declets6Lo)
    }

    /// Encode `Infinity`, or `-Infinity`.
    private static func finalizeOverflow(_ sign: Bool) -> Words {
        return ((sign ? SIGN_BIT : 0) | INF_PATTERN_HI, 0)
    }

    // ==================================================================
    // MARK: - Round and finalize
    // ==================================================================

    /// Round a parsed coefficient/exponent pair to ties-to-even and finalize it
    /// into an encoding.
    ///
    /// Full handling of the decimal128 boundary conditions: underflow to
    /// subnormal or zero, overflow to infinity, and the clamped-near-Emax region
    /// where a finite value with too-large quantum exponent is still
    /// representable by absorbing the excess into the coefficient.
    ///
    /// Step 1 (fast path): if the input already fits within precision and range
    /// and no rounding is required -- residue at most LT_HALF, or HALF with an
    /// even retained low bit -- encode and return immediately. This picks up the
    /// vast majority of cases.
    ///
    /// Step 2 (zero coefficient): zeros with an out-of-range qExp get clamped
    /// into range.
    ///
    /// Step 3 (special values): not applicable -- specials are handled by the
    /// callers before reaching here.
    ///
    /// Step 4 (underflow): below Emin, divert to ``finalizeUnderflowRegion``.
    ///
    /// Step 5 (precision truncation): REMOVED as unreachable from a codec's
    /// callers -- see the note in the body, which also states what would have to
    /// change for it to be needed again.
    ///
    /// Step 6 (rounding): apply ties-to-even. If rounding rolls the coefficient
    /// over to 10^34, normalize to 10^33 and increment the exponent.
    ///
    /// Step 7 (overflow / clamping): above Emax, either absorb the excess into
    /// the coefficient or overflow to infinity.
    private static func roundAndFinalizeFinite(_ formatIsBid: Bool, _ sign: Bool, _ qExpIn: Int,
                                               _ dw1In: UInt64, _ dw0In: UInt64,
                                               _ residueIn: Int) -> Words {
        // Step 1: fast path -- already in valid decimal128 range ...
        //         ... and no ties-to-even rounding to apply
        if (residueIn <= LT_HALF || (residueIn == HALF && (dw0In & 1) == 0)) {
            if (coeffQExpFit(dw1In, dw0In, qExpIn)) {
                return setFinite(formatIsBid, sign, qExpIn, dw1In, dw0In)
            }
            // Step 2: zero coefficient with out-of-range qExp ... clamp qExp
            if ((dw1In | dw0In) == 0) {
                let qClamped = max(min(qExpIn, Q_MAX), Q_MIN)
                return setFinite(formatIsBid, sign, qClamped, 0, 0)
            }
        }

        // Step 3: special values ... not applicable ... only Finite

        // Step 5 -- precision truncation -- IS NOT HERE, and this is the reason.
        //
        // This finalize chain descends from one built for an arithmetic engine,
        // whose callers hand it coefficients wider than the 34-digit precision
        // limit: multiply and FMA produce a double-width product, and the engine
        // truncates it here, accumulating the discarded digits into the residue
        // before rounding. A codec has no such caller.
        //
        // parseFiniteValueText accumulates at most 19 + 15 = 34 significant
        // digits and turns every digit past them into a residue instead, so the
        // coefficient it hands over is never wider than the limit. The only
        // other entry to this function is the swamped branch of
        // finalizeUnderflowRegion, which passes a zero coefficient. So the
        // truncation step is unreachable, and rather than carry a path that has
        // never once executed -- and therefore has never been verified to work
        // -- it is removed and the invariant is enforced.
        //
        // Measured on the C port, which is a translation of the same reference:
        // zero executions across the 87k-row shared corpus, 400,000 random
        // numerals, and 76,280 finalize calls driven by inputs of up to 5,000
        // digits, where the widest coefficient ever seen here was 34.
        //
        // This is `demand`, not `verify`: it is unconditional, because a build
        // with VERIFY_ENABLED off would otherwise fall through and encode an
        // out-of-range coefficient silently. It cannot fire on a caller's data
        // -- no input reaches it -- only on a future caller that breaks the
        // invariant, which is exactly when a loud failure is wanted. A caller
        // that is not a parser needs the truncation step back; it is live in
        // every full port's Finalize, where multiply and FMA do reach it.
        demand(calcDigitLen128(dw1In, dw0In) <= 34, "coefficient wider than precision")

        // Step 4: underflow. With no precision truncation to outrank it, the
        // test is simply whether the exponent is below the minimum.
        if (qExpIn < Q_MIN) {
            return finalizeUnderflowRegion(formatIsBid, sign, qExpIn, dw1In, dw0In, residueIn)
        }

        let totalResidue = residueIn
        var dw1 = dw1In
        var dw0 = dw0In
        var qExp = qExpIn

        // Step 6: rounding ... in this world only ties-to-even
        let applyRounding = (totalResidue == GT_HALF || (totalResidue == HALF && (dw0 & 1) != 0))
        if (applyRounding) {
            // step 6.1: increment. A coefficient of 0xFFFF...FFFF in the low
            // word carries into the high word, which is exactly what the two
            // statements together compute.
            dw0 = dw0 &+ 1
            dw1 = dw1 &+ (dw0 == 0 ? 1 : 0)

            // step 6.2: rollover
            if (dw1 == MAXX_COEFF_34_HI && dw0 == MAXX_COEFF_34_LO) {
                dw1 = MIN_PRECISION_34_COEFF_HI
                dw0 = MIN_PRECISION_34_COEFF_LO
                qExp &+= 1
            }
        }

        // Step 7: check final bounds
        verify(qExp >= Q_MIN)
        verify(calcDigitLen128(dw1, dw0) <= 34)
        if (qExp > Q_MAX) {
            let qExcess = qExp &- Q_MAX
            let digitLen = calcDigitLen128(dw1, dw0)
            if (digitLen &+ qExcess <= 34) {
                return finalizeClamping(formatIsBid, sign, qExp, dw1, dw0)
            }
            return finalizeOverflow(sign)
        }
        return setFinite(formatIsBid, sign, qExp, dw1, dw0)
    }

    /// Test whether a coefficient/exponent pair fits as a canonical encoding:
    /// exponent in `Q_MIN...Q_MAX` and coefficient in `0..<10^34`.
    ///
    /// The fast path uses the high word's leading-zero count to cheaply confirm
    /// the coefficient has at most 113 bits, in which case it is necessarily
    /// below 10^34, since 2^113 > 10^34. The slow path compares against 10^34.
    @inline(__always)
    private static func coeffQExpFit(_ dw1: UInt64, _ dw0: UInt64, _ qExp: Int) -> Bool {
        if (qExp < Q_MIN || qExp > Q_MAX) {
            return false
        }
        if (dw1.leadingZeroBitCount > 128 &- 113) {
            return true
        }
        let pow10Offset = 34 << 1
        let maxxHi = POW10[pow10Offset &+ 1]
        return (dw1 < maxxHi || (dw1 == maxxHi && dw0 < POW10[pow10Offset]))
    }

    /// Encode a finite value whose natural quantum exponent exceeds `Q_MAX` but
    /// whose coefficient has enough leading capacity to absorb the excess.
    ///
    /// Multiplies the coefficient by `10^qExcess`, reducing the exponent to
    /// exactly `Q_MAX`. This preserves the value while bringing the encoding
    /// into representable range. The caller must have verified there is room
    /// (`digitLen + qExcess <= 34`).
    private static func finalizeClamping(_ formatIsBid: Bool, _ sign: Bool, _ qExp: Int,
                                         _ dw1: UInt64, _ dw0: UInt64) -> Words {
        let qExcess = qExp &- Q_MAX
        verify(qExcess > 0 && qExcess <= 34 &- calcDigitLen128(dw1, dw0))
        let pow10Offset = qExcess << 1
        let y1 = POW10[pow10Offset &+ 1]
        let y0 = POW10[pow10Offset]
        // A 128x128 product truncated to 128 bits: each partial product below
        // wraps by construction, and the discarded halves are known zero because
        // the caller checked the result fits in 34 digits.
        let pp00Hi = unsignedMulHi(dw0, y0)
        let pp00Lo = dw0 &* y0
        let pp10Lo = dw1 &* y0
        let pp01Lo = dw0 &* y1
        let dw0Scaled = pp00Lo
        let dw1Scaled = pp00Hi &+ pp10Lo &+ pp01Lo
        verify(coeffQExpFit(dw1Scaled, dw0Scaled, Q_MAX))
        return setFinite(formatIsBid, sign, Q_MAX, dw1Scaled, dw0Scaled)
    }

    /// Dispatch underflow handling for a value whose exponent is below Emin.
    /// Three cases:
    ///
    ///  - Truncation needed exceeds the digit count: the result is zero, the
    ///    value being below half the smallest subnormal.
    ///  - Truncation equals the digit count: a boundary case where the leading
    ///    digit of the coefficient decides the rounding.
    ///  - Truncation is less than the digit count: representable as a subnormal,
    ///    with some precision preserved and rounding applied.
    private static func finalizeUnderflowRegion(_ formatIsBid: Bool, _ sign: Bool, _ qExp: Int,
                                                _ dw1: UInt64, _ dw0: UInt64,
                                                _ residue: Int) -> Words {
        // IEEE 754-2019 7.5 Underflow -- the subnormal region
        verify(qExp < Q_MIN)
        let truncationNeeded = Q_MIN &- qExp
        let digitLen = calcDigitLen128(dw1, dw0)
        verify(digitLen <= 34)
        if (truncationNeeded > digitLen) {
            // Swamped: the result is zero under ties-to-even, and always inexact
            return roundAndFinalizeFinite(formatIsBid, sign, Q_MIN, 0, 0, LT_HALF)
        }
        if (truncationNeeded == digitLen) {
            return finalizeUnderflowBoundary(formatIsBid, sign, dw1, dw0, residue)
        }
        return finalizeSubnormal(formatIsBid, sign, qExp, dw1, dw0, residue)
    }

    /// Handle the underflow boundary case, where the most-significant digit of
    /// the coefficient sits exactly one position right of the representable
    /// range.
    ///
    /// The coefficient value itself decides the rounding: comparing it against
    /// `(10^digitLen) / 2` yields the residue class. Combined with any incoming
    /// residue that drives a ties-to-even decision between zero -- always even,
    /// and the default outcome -- and 1 ulp, the smallest subnormal, reached
    /// only when the total residue is GT_HALF.
    private static func finalizeUnderflowBoundary(_ formatIsBid: Bool, _ sign: Bool,
                                                  _ dw1: UInt64, _ dw0: UInt64,
                                                  _ residueIn: Int) -> Words {
        let digitLen = calcDigitLen128(dw1, dw0)
        verify(digitLen != 0)
        let scaleResidue = residueFromValuePow10(dw1, dw0, digitLen)
        let totalResidue = residueMerge(scaleResidue, residueIn)
        // ties-to-even: round away from zero only at GT_HALF, since the
        // alternative result is 0, which is even
        return setFinite(formatIsBid, sign, Q_MIN, 0, totalResidue == GT_HALF ? 1 : 0)
    }

    private static func finalizeSubnormal(_ formatIsBid: Bool, _ sign: Bool, _ qExpIn: Int,
                                          _ dw1In: UInt64, _ dw0In: UInt64,
                                          _ residueIn: Int) -> Words {
        let truncationNeeded = Q_MIN &- qExpIn
        verify(truncationNeeded > 0 && truncationNeeded < calcDigitLen128(dw1In, dw0In))

        let scaled = u128ScaleDownPow10(dw1In, dw0In, truncationNeeded)
        let totalResidue = residueMerge(scaled.residue, residueIn)
        var dw1T = scaled.hi
        var dw0T = scaled.lo
        var qExpT = Q_MIN

        let roundUp = (totalResidue == GT_HALF || (totalResidue == HALF && (dw0T & 1) != 0))
        if (roundUp) {
            // apply rounding -- wrapping, as in step 6.1
            dw0T = dw0T &+ 1
            dw1T = dw1T &+ (dw0T == 0 ? 1 : 0)
            if (dw1T == MAXX_COEFF_34_HI && dw0T == MAXX_COEFF_34_LO) {
                dw1T = MIN_PRECISION_34_COEFF_HI
                dw0T = MIN_PRECISION_34_COEFF_LO
                qExpT &+= 1
            }
        }
        return setFinite(formatIsBid, sign, qExpT, dw1T, dw0T)
    }

    // ==================================================================
    // MARK: - Residue -- how much was discarded, relative to half a ulp
    // ==================================================================

    /// Residue classification for rounding decisions.
    ///
    /// When discarding low-order digits during truncation to 34 significant
    /// digits, the discarded part falls into one of four classes relative to
    /// half a ulp of the retained value:
    ///
    ///  - `EXACT`   -- discarded part is zero; no rounding needed
    ///  - `LT_HALF` -- strictly less than half; round down, toward zero
    ///  - `HALF`    -- exactly half; tie-break per the rounding direction
    ///  - `GT_HALF` -- strictly greater than half; round up, away from zero
    ///
    /// For ties-to-even, `HALF` rounds to the nearest even retained digit;
    /// `LT_HALF` and `GT_HALF` are unambiguous; `EXACT` is a no-op.
    private static let EXACT = 0
    private static let LT_HALF = 1
    private static let HALF = 2
    private static let GT_HALF = 3

    /// Maps a discarded decimal digit 0..9 to its residue class, two bits per
    /// digit packed low-to-high: 0 to EXACT, 1..4 to LT_HALF, 5 to HALF, 6..9 to
    /// GT_HALF.
    private static let DIGIT_MAP = 0b11_11_11_11_10_01_01_01_01_00

    /// Classify a single discarded decimal digit 0..9.
    @inline(__always)
    private static func residueFromDecimalDigit(_ digit: Int) -> Int {
        return (DIGIT_MAP >> (digit << 1)) & 0x03
    }

    /// Combine a primary `roundResidue` with a `stickyResidue` from
    /// less-significant digits, in the round-bit-and-sticky-bit style. The
    /// sticky residue collapses to a single nonzero bit which is OR'd into the
    /// low bit of the round residue.
    @inline(__always)
    private static func residueMerge(_ roundResidue: Int, _ stickyResidue: Int) -> Int {
        let s = (stickyResidue & 1) | (stickyResidue >> 1)
        return (roundResidue | s) & 0x03
    }

    /// Classify a 128-bit value relative to half of `10^pow10`.
    ///
    /// Used in the underflow boundary case, where the entire coefficient is
    /// discarded by truncation, so the residue is decided by where it falls
    /// relative to half the truncation divisor.
    private static func residueFromValuePow10(_ dw1: UInt64, _ dw0: UInt64, _ pow10: Int) -> Int {
        if ((dw1 | dw0) == 0) {
            return EXACT
        }
        let pow10Index = pow10 << 1
        let pow10Hi = POW10[pow10Index &+ 1]
        let pow10Lo = POW10[pow10Index]

        let halfHi = pow10Hi >> 1
        let halfLo = (pow10Hi << 63) | (pow10Lo >> 1)
        if (dw1 != halfHi) {
            return (dw1 < halfHi) ? LT_HALF : GT_HALF
        }
        if (dw0 != halfLo) {
            return (dw0 < halfLo) ? LT_HALF : GT_HALF
        }
        return HALF
    }

    /// Divide a 128-bit coefficient by `10^truncationNeeded`, returning the
    /// quotient and the round-and-sticky residue class of what was discarded.
    /// Truncates in chunks of up to 9 digits via ``u113DivModPow10Max9``.
    private static func u128ScaleDownPow10(_ dw1: UInt64, _ dw0: UInt64,
                                           _ truncationNeeded: Int) -> (hi: UInt64, lo: UInt64, residue: Int) {
        verify((dw1 | dw0) != 0)
        verify(truncationNeeded > 0 && truncationNeeded < calcDigitLen128(dw1, dw0))
        var scaleResidue = EXACT
        var dw1T = dw1
        var dw0T = dw0
        var digitsRemaining = truncationNeeded
        repeat {
            let stepPow10 = min(digitsRemaining, 9)
            let step = u113DivModPow10Max9(dw1T, dw0T, stepPow10)
            dw1T = step.qHi
            dw0T = step.qLo
            let stepResidue = residueFromValuePow10(0, step.rem, stepPow10)
            scaleResidue = residueMerge(stepResidue, scaleResidue)
            digitsRemaining &-= stepPow10
        } while (digitsRemaining > 0)
        return (dw1T, dw0T, scaleResidue)
    }

    // ==================================================================
    // MARK: - DPD declet conversion
    //
    // A declet is 10 bits holding three decimal digits, 0..999. This is the one
    // place BID and DPD genuinely differ: BID stores the 34-digit coefficient as
    // a binary integer, DPD as a leading digit plus eleven declets.
    //
    // Both directions are pure boolean arithmetic -- Cowlishaw's dpd2bcd and
    // bcd2dpd -- rather than lookup tables, which is what the reference measured
    // as the smaller and faster choice and what transcribes unchanged into the
    // sibling ports.
    // ==================================================================

    /// Decode up to seven packed DPD declets into a binary integer.
    ///
    /// Declets are ten bits each, least significant first. The topmost may be
    /// narrower than ten bits, which is how the coefficient's leading digit is
    /// carried: 0..9 encodes to itself as a declet.
    private static func binFromDeclets(_ declets: UInt64) -> UInt64 {
        var bin: UInt64 = 0
        var rest = declets
        var multiplier: UInt64 = 1
        while (rest != 0) {
            bin &+= dpdDecodeDeclet(rest & 0x3FF) &* multiplier
            multiplier &*= 1000
            rest >>= 10
        }
        return bin
    }

    /// Encode a binary integer of at most 18 digits into six packed declets,
    /// least significant first. The inverse of ``binFromDeclets`` over that
    /// range.
    private static func decletsFromBin(_ bin: UInt64) -> UInt64 {
        verify(bin < TEN_POW_18)
        var rest = bin
        var declets: UInt64 = 0
        var shift: UInt64 = 0
        while (rest != 0) {
            // reciprocal-multiply divide by 1000
            let q = unsignedMulHi(rest, 0x020C_49BA_5E35_3F7D) >> 3
            declets |= dpdEncodeDeclet(rest &- (q &* 1000)) << shift
            shift &+= 10
            rest = q
        }
        return declets
    }

    /// Decode a 10-bit DPD declet into `0...999`.
    ///
    /// Mapping: bit9..bit0 as `p q r s t u v w x y`. Accepts the 24
    /// non-canonical declets as well as the 1000 canonical ones, per
    /// Cowlishaw's dpd2bcd.
    private static func dpdDecodeDeclet(_ declet: UInt64) -> UInt64 {
        verify(declet <= 1023)

        if (declet == 0) {
            return 0
        }

        // Unpack to bits p..y
        let p = (declet >> 9) & 1
        let q = (declet >> 8) & 1
        let r = (declet >> 7) & 1
        let s = (declet >> 6) & 1
        let t = (declet >> 5) & 1
        let u = (declet >> 4) & 1
        let v = (declet >> 3) & 1
        let w = (declet >> 2) & 1
        let x = (declet >> 1) & 1
        let y = declet & 1

        let ns = s ^ 1
        let nx = x ^ 1
        let nv = v ^ 1
        let nw = w ^ 1
        let nt = t ^ 1

        let a = (v & w) & (ns | t | nx)
        let b = p & (nv | nw | (s & ~t & x))
        let c = q & (nv | nw | (s & ~t & x))
        let d = r

        let e = v & ((nw & x) | (~t & x) | (s & x))
        let f = (s & (nv | nx)) | (p & ns & t & v & w & x)
        let g = (t & (nv | nx)) | (q & ns & t & w)
        let h = u

        let i = v & ((nw & nx) | (w & x & (s | t)))
        let j = (nv & w)
            | (s & v & nw & x)
            | (p & w & (nx | (ns & ~t)))
        let k = (nv & x) | (t & nw & x) | (q & v & w & (nx | (ns & nt)))
        let m = y

        // Pack BCD digit bits -> three digits
        let d2 = (a << 3) | (b << 2) | (c << 1) | d
        let d1 = (e << 3) | (f << 2) | (g << 1) | h
        let d0 = (i << 3) | (j << 2) | (k << 1) | m

        return d2 &* 100 &+ d1 &* 10 &+ d0
    }

    /// Encode `0...999` into a 10-bit DPD declet, per Cowlishaw's bcd2dpd.
    ///
    /// The inverse of ``dpdDecodeDeclet`` over canonical declets. A
    /// non-canonical declet decodes to a value that re-encodes to the canonical
    /// declet for that value, so `encode(decode(x)) == x` only for canonical `x`.
    private static func dpdEncodeDeclet(_ n: UInt64) -> UInt64 {
        verify(n <= 999)

        if (n == 0) {
            return 0
        }

        // reciprocal-multiply digit extraction (optimized for n <= 999)
        let q10 = (n &* 205) >> 11 // n / 10
        let q100 = (n &* 41) >> 12 // n / 100

        let d2 = q100
        let d1 = q10 &- (q100 &* 10)
        let d0 = n &- (q10 &* 10)

        // BCD bits (MSB to LSB: 8, 4, 2, 1)
        let a = (d2 >> 3) & 1
        let b = (d2 >> 2) & 1
        let c = (d2 >> 1) & 1
        let d = d2 & 1

        let e = (d1 >> 3) & 1
        let f = (d1 >> 2) & 1
        let g = (d1 >> 1) & 1
        let h = d1 & 1

        let i = (d0 >> 3) & 1
        let j = (d0 >> 2) & 1
        let k = (d0 >> 1) & 1
        let m = d0 & 1

        let na = a ^ 1
        let ne = e ^ 1
        let ni = i ^ 1

        let p = b | ((a & j) | ((a & f) & i))
        let q = c | ((a & k) | ((a & g) & i))
        let r = d
        let s = (f & (na | ni)) | ((na & (e & j)) | (e & i))
        let t = g | ((na & (e & k)) | (a & i))
        let u = h
        let v = a | (e | i)
        let w = a | ((e & i) | (ne & j))
        let x = e | ((a & i) | (na & k))
        let y = m

        return (p << 9) | (q << 8) | (r << 7) | (s << 6) |
               (t << 5) | (u << 4) | (v << 3) | (w << 2) |
               (x << 1) | y
    }

    // ==================================================================
    // MARK: - Low-level unsigned arithmetic
    // ==================================================================

    /// Powers of 10 from `10^0` through `10^34` as 128-bit values in
    /// little-endian order: `POW10[2*i]` is the low 64 bits and
    /// `POW10[2*i + 1]` the high 64 bits of `10^i`.
    ///
    /// Sized to the coefficient bound and indexed directly -- no mask, no
    /// padding. Every reachable index is at most 34: the binding case is
    /// ``calcDigitLen128(_:_:)``, whose input is always a coefficient or NaN
    /// payload below `10^34`, so `bitLen <= 113` and
    /// `(bitLen * 1233) >> 12 <= 34`. It doubles as the `5^n` source for the
    /// divide kernel, since `10^n >> n` is exactly `5^n`; there is no POW5
    /// table.
    private static let POW10: [UInt64] = [
        // little-endian order
        1, 0,                     // 1 (10**0)
        0x0000_0000_0000_000A, 0, // 10 (10**1)
        0x0000_0000_0000_0064, 0, // 100 (10**2)
        0x0000_0000_0000_03E8, 0, // 1000 (10**3)
        0x0000_0000_0000_2710, 0, // 10000 (10**4)
        0x0000_0000_0001_86A0, 0, // 100000 (10**5)
        0x0000_0000_000F_4240, 0, // 1000000 (10**6)
        0x0000_0000_0098_9680, 0, // 10000000 (10**7)
        0x0000_0000_05F5_E100, 0, // 100000000 (10**8)
        0x0000_0000_3B9A_CA00, 0, // 1000000000 (10**9)
        0x0000_0002_540B_E400, 0, // 10000000000 (10**10)
        0x0000_0017_4876_E800, 0, // 100000000000 (10**11)
        0x0000_00E8_D4A5_1000, 0, // 1000000000000 (10**12)
        0x0000_0918_4E72_A000, 0, // 10000000000000 (10**13)
        0x0000_5AF3_107A_4000, 0, // 100000000000000 (10**14)
        0x0003_8D7E_A4C6_8000, 0, // 1000000000000000 (10**15)
        0x0023_86F2_6FC1_0000, 0, // 10000000000000000 (10**16)
        0x0163_4578_5D8A_0000, 0, // 100000000000000000 (10**17)
        0x0DE0_B6B3_A764_0000, 0, // 1000000000000000000 (10**18)
        0x8AC7_2304_89E8_0000, 0, // 10000000000000000000 (10**19)
        // minBitCount:64  maxBitCount:128
        0x6BC7_5E2D_6310_0000, 0x0000_0000_0000_0005, // 10**20
        0x35C9_ADC5_DEA0_0000, 0x0000_0000_0000_0036, // 10**21
        0x19E0_C9BA_B240_0000, 0x0000_0000_0000_021E, // 10**22
        0x02C7_E14A_F680_0000, 0x0000_0000_0000_152D, // 10**23
        0x1BCE_CCED_A100_0000, 0x0000_0000_0000_D3C2, // 10**24
        0x1614_0148_4A00_0000, 0x0000_0000_0008_4595, // 10**25
        0xDCC8_0CD2_E400_0000, 0x0000_0000_0052_B7D2, // 10**26
        0x9FD0_803C_E800_0000, 0x0000_0000_033B_2E3C, // 10**27
        0x3E25_0261_1000_0000, 0x0000_0000_204F_CE5E, // 10**28
        0x6D72_17CA_A000_0000, 0x0000_0001_431E_0FAE, // 10**29
        0x4674_EDEA_4000_0000, 0x0000_000C_9F2C_9CD0, // 10**30
        0xC091_4B26_8000_0000, 0x0000_007E_37BE_2022, // 10**31
        0x85AC_EF81_0000_0000, 0x0000_04EE_2D6D_415B, // 10**32
        0x38C1_5B0A_0000_0000, 0x0000_314D_C644_8D93, // 10**33
        0x378D_8E64_0000_0000, 0x0001_ED09_BEAD_87C0, // 10**34
    ]

    /// Bit length of a 128-bit value: the position of the highest set bit plus
    /// one, and 0 for the zero value.
    @inline(__always)
    private static func calcBitLen128(_ dw1: UInt64, _ dw0: UInt64) -> Int {
        if (dw1 != 0) {
            return 128 &- dw1.leadingZeroBitCount
        }
        if (dw0 != 0) {
            return 64 &- dw0.leadingZeroBitCount
        }
        return 0
    }

    /// Decimal digit count of a 128-bit value.
    ///
    /// `(bitLen * 1233) >> 12` is `floor(bitLen * log10(2))`, which is either the
    /// exact digit count or one too small; a single unsigned compare against the
    /// next-larger power of ten resolves the off-by-one.
    @inline(__always)
    private static func calcDigitLen128(_ dw1: UInt64, _ dw0: UInt64) -> Int {
        let bitLen = calcBitLen128(dw1, dw0)
        let loDigitCount = (bitLen &* 1233) >> 12
        let hiDigitCount = loDigitCount &+ 1
        let pow10Offset = loDigitCount << 1
        let p1 = POW10[pow10Offset &+ 1]
        let p0 = POW10[pow10Offset]
        if (dw1 != p1) {
            return (dw1 < p1) ? hiDigitCount &- 1 : hiDigitCount
        }
        return (dw0 < p0) ? hiDigitCount &- 1 : hiDigitCount
    }

    /// High 64 bits of the 128-bit product `x * y`.
    ///
    /// The reference decomposes this into four 32x32 partial products because
    /// the JVM has no unsigned 64-bit multiply-high; Swift has one on the type.
    @inline(__always)
    private static func unsignedMulHi(_ x: UInt64, _ y: UInt64) -> UInt64 {
        return x.multipliedFullWidth(by: y).high
    }

    /// Multiply a 64-bit value by `10^pow10` and add `a`, as a 128-bit result.
    @inline(__always)
    private static func u128FmaPow10(_ x: UInt64, _ pow10: Int, _ a: UInt64) -> Words {
        let y = POW10[pow10 << 1]
        // the low word of a genuine 128-bit product, so both wrap by design
        let prodLo = x &* y
        let prodHi = unsignedMulHi(x, y)
        let sumLo = prodLo &+ a
        let sumHi = prodHi &+ (sumLo < prodLo ? 1 : 0)
        return (sumHi, sumLo)
    }

    /// Divide a 113-bit value by `10^pow10` for `pow10` in `1...9`, returning
    /// the quotient and the remainder.
    ///
    /// Table-free: `10^pow10` factors as `2^pow10 * 5^pow10`, so the low
    /// `pow10` bits fall straight out as the low part of the remainder and the
    /// shifted value is divided by `5^pow10` with two hardware 64-bit divides.
    private static func u113DivModPow10Max9(_ dwHi: UInt64, _ dwLo: UInt64,
                                             _ pow10: Int) -> (qHi: UInt64, qLo: UInt64, rem: UInt64) {
        verify(pow10 >= 1 && pow10 <= 9)
        verify(dwHi.leadingZeroBitCount >= 15)

        let sh = UInt64(pow10)
        let mask = (UInt64(1) << sh) &- 1
        let b = dwLo & mask
        let sHi = dwHi >> sh
        let sLo = (dwLo >> sh) | (dwHi << (64 &- sh))

        let k = UInt64(50 &- pow10)
        let maskK = (UInt64(1) << k) &- 1
        let hi63 = (sHi << (14 &+ sh)) | (sLo >> k)
        let loK = sLo & maskK
        // two slots per power in POW10, hence the doubled index
        let d = POW10[pow10 << 1] >> sh // = 5^pow10
        let q1 = hi63 / d
        let r1 = hi63 % d
        let mid = (r1 << k) | loK
        let q0 = mid / d
        let r0 = mid % d

        // `q1 << k` deliberately drops the bits that `qHi` picks up; the low k
        // bits it leaves are zero, so the add below is an or and cannot carry.
        return (q1 >> (14 &+ sh), (q1 << k) &+ q0, (r0 << sh) | b)
    }
}
