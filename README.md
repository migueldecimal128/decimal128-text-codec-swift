# decimal128-text-codec-swift

A thin codec between the two IEEE 754-2019 decimal128 interchange encodings —
BID and DPD — and decimal character sequences. Nothing else: no arithmetic, no
comparison, no value type, no context, no status flags.

One Swift file, four public functions, zero dependencies. The point is that a
caller who holds interchange bits or a string, and wants the other one, can
depend on this without pulling in a full IEEE 754-2019 engine.

For the complete decimal128 implementation see `decimal128-swift` at
<https://decimal128.com>.

## API

```swift
import Decimal128TextCodec

let text = Decimal128TextCodec.bid128ToString(bits)   // cannot fail
let text = Decimal128TextCodec.dpd128ToString(bits)

var bits: UInt128 = 0
let err = Decimal128TextCodec.bid128Parse(&bits, "1.23E+45")   // nil = success
let err = Decimal128TextCodec.dpd128Parse(&bits, "1.23E+45")
```

An encoding is a `UInt128`, sign bit at the top, laid out per IEEE 754-2019
§3.5.2. Both parse functions **always write** their out-parameter — the
canonical positive quiet NaN on failure — so a caller who discards the message
still observes a legal IEEE 754-2019 datum rather than a stale value. The error
message is human-readable; its exact wording is not part of the contract.

## Behavior

**Rendering cannot fail.** Every 128-bit pattern maps to a valid decimal
character sequence. A non-canonical BID coefficient (≥ 10³⁴) renders as zero at
the encoded exponent, per IEEE 754-2019 §3.5.2, and a NaN payload ≥ 10³³ reads
as no payload. Those patterns never arise from this codec's own encode
direction — they arise from network and file data, which is why the codec
handles them.

**Output is the GDAS `to-scientific-string` form, and only that.** Integer form
when the quantum exponent is zero, plain form when the adjusted exponent is in
`[-6, 0]`, scientific otherwise. The exponent sign is always written:
`6.02E+23`, never `6.02E23`. Cohort information is preserved — `1.00` and `1.0`
are distinct outputs from distinct encodings of the same numerical value, and
nothing is ever normalized or stripped.

**Accepted input** matches what the full `decimal128-{lang}` ports accept, with
one deliberate exception below, so a caller can move between this codec and the
full library without the grammar shifting under them: plain and scientific
notation with `E` or `e`, a leading `+` or `-`, `_` digit separators *between
two digits*, and the case-insensitive words `Infinity`, `Inf`, `NaN`, `qNaN`,
`sNaN` with an optional sign and an optional payload of decimal digits.

**The exception: a NaN payload may be parenthesised** — `NaN(123)` as well as
`NaN123`. C's own `strtod` reads `NAN(n-char-sequence)`, so the spelling reaches
a caller from the platform itself. The form is positional and balanced: `(`
immediately after the word, at least one digit, `)` last. So `NaN()`, `NaN(1`,
`NaN(1]`, `NaN(1)2(3)`, `NaN (1)`, `NaN[1]` and `NaN{1}` are all rejected. The
resemblance to `strtod` stops at the parentheses — its sequence is letters,
digits and underscores read as an implementation-defined integer, so `NAN(abc)`
and `NAN(0x1c8)` are legal there and rejected here. Rendering never emits
parentheses; `NaN(123)` parses and renders back as `NaN123`.

**This is the one place the codecs accept text the full ports reject.** Text
containing a parenthesised payload parses here and fails in `decimal128-swift`.

**Rounding is ties-to-even, hardcoded**, and reachable only from the text →
bits direction: more than 34 significant digits, overflow to Infinity, or
underflow to a subnormal or zero. There is no rounding parameter and no format
selector — the premise is a four-function surface with no configuration. IEEE
754-2019 §5.4.2 places `convertFromDecimalCharacter` under the applicable
rounding-direction attribute; this codec deliberately implements only the
ties-to-even case, and is therefore a conforming **subset** of that operation.
Callers needing another rounding direction want the full library.

## Building

```
swift build
swift test
swift test -c release -Xswiftc -enable-testing
```

Swift 6, no dependencies. `Package.swift` declares a macOS 15 / iOS 18 floor,
which is what `UInt128` requires; declaring it there rather than annotating the
API keeps the four functions free of `@available` and the call sites free of
`if #available`.

The `demand` checks — buffer sizing, and the precision invariant where the
finalizer's truncation step used to be — are live in every configuration. The
internal-state `verify` assertions are armed for **debug builds only**, because
a release consumer compiles this source into their own program and must not take
a trap inside a library on data they do not control. Both configurations are
tested; `-enable-testing` is what lets `@testable import` reach the declet
primitives in a release build.

## Tests

| suite | what it covers |
|---|---|
| `TestCorpusVectors` | the four conformance tables over the vendored corpus — 2,438 rows, both directions, both formats |
| `TestCanonicalCorpus` | the full 84,764-row canonical table, when a sibling `decimal128-resources` checkout is present |
| `TestBid128ToString`, `TestBid128Parse` | 374 hand-chosen BID render and parse vectors, including the whole rounding surface |
| `TestDpd128ToString`, `TestDpd128Parse` | DPD render and parse vectors, and the NaN payloads where the formats diverge |
| `TestDpdDeclet` | the declet codec, exhaustively over all 1024 patterns |
| `TestDpd128NonCanonical` | the 24 non-canonical declets, and junk in an infinity's trailing field |
| `TestDpd128DecTest` | Cowlishaw's `dqEncode` / `dqCanonical` — 463 vectors |
| `TestPublicAPI` | the promises as properties: paren-equals-bare, failure always writes, render/parse/render is a fixed point over 20,000 random patterns |

The conformance vectors under `Tests/Decimal128TextCodecTests/vectors` are
vendored from `decimal128-text-codec-c/tests/vectors`, this family's corpus of
record, and were generated by the `decimal128-c` engine through its public API.
That engine reaches its answers by different algorithms, so agreement is a
cross-check rather than a tautology. `dqEncode.decTest` is a third oracle, older
than this ecosystem, and is what makes the DPD declet arithmetic trustworthy
rather than merely self-consistent.

Two things worth knowing about the test surface:

- **A vendored copy drifts unless something compares it.**
  `Scripts/check_vendored_corpus.sh` diffs the four CSVs against a
  `decimal128-resources` checkout, permitting the two documented exemptions and
  nothing else — including the case where those two rows *stop* being in
  upstream, which would mean it had been edited: the corpus is a fixed artifact
  whose generator no longer exists, so upstream should not move. CI clones the
  (public) resources repo and runs it on every push.
- **`u113DivModPow10Max9` is not directly covered.** The corpus barely reaches
  it: the two render suites call it zero times and the parse suite reaches it 20
  times across five of its nine powers. The codec can be green on 86,069 corpus
  rows with that kernel substantially wrong.

## Provenance

Ported from `decimal128-text-codec-kotlin` (`Decimal128TextCodec.kt` @
`3a99efc`), which is the reference implementation for the family, with
`decimal128-text-codec-c` consulted where a systems language had already
answered a question Kotlin never had to ask.

Four deliberate divergences from the reference, each noted at the point it
occurs in the source:

- **The public boundary is `UInt128`**, not a pair of words. Swift has a native
  128-bit unsigned integer, so a caller holds one value rather than two words
  plus a convention about which is which. The internals still work in
  `dw1`/`dw0` pairs exactly as the reference does — the split happens once on
  entry and the join once on exit — which is what keeps the two files readable
  side by side.
- **Dwords are `UInt64`, not signed `Long`.** The reference carries
  `unsignedMulHi` / `unsignedLT` / `ushr` only because the JVM has no unsigned
  64-bit type.
- **Swift arithmetic traps where Kotlin's wraps.** Every site the reference
  relies on wrapping is spelled `&+` / `&*` here and carries a note saying why
  the wrap is the intended arithmetic. Every other site is left checked on
  purpose, so a translation error surfaces as a trap rather than a wrong answer.
- **The finalize chain returns its result** instead of writing through an
  out-parameter. The reference threads a `LongArray` that doubles as scratch for
  the divide kernel; Swift returns tuples, so neither the aliasing nor the
  scratch reuse needs to exist.

The finalizer's precision-truncation step is absent, in this port and in its two
peers alike. It descends from a finalizer built for an arithmetic engine, whose
multiply and FMA hand it a double-width product; a codec's only caller is a
parser that accumulates at most 19 + 15 = 34 significant digits and turns
everything past them into a residue. Measured on the C port: zero executions
across the shared corpus, 400,000 random numerals, and 76,280 finalize calls
from inputs of up to 5,000 digits. A dead path is an unverified path, so it is
replaced by an unconditional `demand`. It is still live in every full port's
`Finalize`, where multiply and FMA do reach it.

## License

MIT.
