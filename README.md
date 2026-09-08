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

var buf = [UInt8](repeating: 0, count: Decimal128TextCodec.MAX_LEN)
let n = Decimal128TextCodec.bid128ToAscii(&buf, bits)   // the text is buf[0..<n]

var bits: UInt128 = 0
let err = Decimal128TextCodec.bid128Parse(&bits, "1.23E+45")   // nil = success
let err = Decimal128TextCodec.dpd128Parse(&bits, "1.23E+45")
```

An encoding is a `UInt128`, sign bit at the top, laid out per IEEE 754-2019
§3.5.2. That is the entire boundary; there is no value type, no context, no
status flags. Both parse functions **always write** their out-parameter — the
canonical positive quiet NaN on failure — so a caller who discards the message
still observes a legal IEEE 754-2019 datum rather than a stale value. The error
message is human-readable; its exact wording is not part of the contract.

The `ToString` renderers return an owned `String`; their `ToAscii` peers write
into a caller-owned `[UInt8]` and return a length, for callers who want no
allocation. `MAX_LEN` is 42, the exact bound on a rendered decimal128, and the
buffer must be at least that long.

## Behavior

**Rendering cannot fail.** Every 128-bit pattern maps to a valid decimal
character sequence. A non-canonical BID coefficient (≥ 10³⁴) renders as zero at
the encoded exponent, per IEEE 754-2019 §3.5.2, and a NaN payload ≥ 10³³
renders as no payload. Those patterns never arise from this codec's own encode
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
`NaN123`. C's own `strtod` reads `NAN(n-char-sequence)`, so the spelling
reaches a caller from the platform itself. The form is positional and balanced:
`(` immediately after the word, at least one digit, `)` last. So `NaN()`,
`NaN(1`, `NaN(1]`, `NaN(1)2(3)`, `NaN (1)`, `NaN[1]` and `NaN{1}` are all
rejected. The resemblance to `strtod` stops at the parentheses — its sequence
is letters, digits and underscores read as an implementation-defined integer,
so `NAN(abc)` and `NAN(0x1c8)` are legal there and rejected here. Rendering
never emits parentheses; `NaN(123)` parses and renders back as `NaN123`.

The full ports accept the same spelling — `decimal128-swift` took it on
2026-08-23, closing what had been the codecs' one grammar divergence from them.

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
swift test -c release
```

Swift 6, no dependencies. `Package.swift` declares a macOS 15 / iOS 18 floor,
which is what `UInt128` requires; declaring it there rather than annotating the
API keeps the four functions free of `@available` and the call sites free of
`if #available`.

Internal-consistency claims — the ones unreachable for any input — are spelled
`verify` and gated on `VERIFY_ENABLED`, which `Package.swift` defines for debug
builds only. The default is off in release, because a consumer compiles this
source into their own program and must not take a trap inside a library on data
they do not control. `demand` — the precision invariant that stands in for the
removed precision-truncation step — is live in every configuration. Both
configurations are tested, and neither needs `-enable-testing`: the suite
reaches only the four public functions.

## Tests

Seven tests across two suites in one file.

| file | suite | what it covers |
|---|---|---|
| `Tests/.../TestCorpusVectors.swift` | `TestCorpusVectors` | the four conformance tables over the shared corpus — 2,601 rows, both directions, both formats. Also holds the corpus reader and the hex helpers, its only consumer. |
| | `TestCanonicalCorpus` | the full 84,783-row canonical table |

That is the whole suite, and the shape is deliberate: **every test vector in
this repo comes from the shared corpus.** Nothing in the suite reaches past the
public surface.

An exhaustive unit test of the DPD declet primitives used to sit here too. It
was removed once instrumentation showed the corpus already drives all 1024
declet patterns through the decoder and all 1000 values through the encoder —
the canonical table supplying the 1000 by sheer volume, and the noncanonical
table's 462 declet rows supplying the 24 patterns a canonical encoder never
emits. What went with it is the *statement* that there are exactly 24: the
corpus proves each one decodes correctly without asserting how many there are.

The repo is standalone: it depends on no decimal128 port, at runtime or in
tests. The independent oracle is the shared `text_bid_dpd` corpus, generated by
the `decimal128-c` engine through its public API; that engine reaches its
answers by different algorithms, so agreement is a cross-check rather than a
tautology.

In-repo vector tables used to sit alongside the corpus here — BID render and
parse vectors, DPD render and parse vectors, the Cowlishaw `dqEncode` /
`dqCanonical` suite, and a `TestPublicAPI` suite of contract properties. They
are gone. Every input they held that the corpus did not is now a corpus row,
engine-authored, and the Cowlishaw files themselves live in
`decimal128-resources` under `rosetta/dectest`, so nothing is beyond a reader's
reach.

They were worth removing for a reason beyond duplication: the same tables were
carried in this port and its C and Kotlin siblings, and a whole vector shape —
`apply #a -> #b` — had silently fallen out of all three copies at once. No test
could have told us; it was found by joining against the source file.

The vectors are read from `resources/text_bid_dpd`, where `resources` is the
`decimal128-resources` submodule — the same mount every decimal128 port uses.
Nothing is copied into this repo, so there is no drift class to police. The
directory is recovered from the test file's own `#filePath`, so it does not
matter where the test binary runs from.

Two things worth knowing if you touch the tests:

- **The corpus quotes two of its five files.** `parse` and `error` double-quote
  the text column with `\\` and `\"` escapes; the other three leave it bare. A
  naive comma split silently corrupts four rows and still passes, because a
  malformed input fails to parse either way. The reader honours the quoting,
  the row counts are asserted, and `quotedColumnRoundTrips` checks those four
  rows by hand.
- **The submodule must be checked out.** With `resources/text_bid_dpd` empty,
  `Corpus.load` throws with a message naming the `git submodule update --init
  --recursive` that fixes it, rather than a suite that quietly tests nothing.
  Clone with `--recurse-submodules`.

## Provenance

Ported from `decimal128-text-codec-kotlin` (`Decimal128TextCodec.kt` @
`3a99efc`), which is the reference implementation for the family, with
`decimal128-text-codec-c` consulted where a systems language had already
answered a question Kotlin never had to ask. The design spec is
`TextCodecLayer.md` in the `decimal128-workorder` repository.

Four deliberate divergences from the reference, each noted at the point it
occurs in the source:

- **The public boundary is `UInt128`**, not a pair of words. Swift has a native
  128-bit unsigned integer, so a caller holds one value rather than two words
  plus a convention about which is which. The internals still work in
  `dw1`/`dw0` pairs exactly as the reference does — the split happens once on
  entry and the join once on exit — which is what keeps the two files readable
  side by side.
- **Dwords are `UInt64`, not signed `Long`.** The reference carries
  `unsignedLT` / `unsignedCmp` / `ushr` only because the JVM has no unsigned
  64-bit type.
- **Swift arithmetic traps where Kotlin's wraps.** Every site the reference
  relies on wrapping is spelled `&+` / `&*` here and carries a note saying why
  the wrap is the intended arithmetic. Every other site is left checked on
  purpose, so a translation error surfaces as a trap rather than a wrong
  answer.
- **The finalize chain returns its result** instead of writing through an
  out-parameter. The reference threads a `LongArray` that doubles as scratch
  for the divide kernel; Swift returns tuples, so neither the aliasing nor the
  scratch reuse needs to exist.

The finalizer's precision-truncation step is removed, in this port and in the
reference alike. It descends from a finalizer built for an arithmetic engine,
whose multiply and FMA hand it a double-width product; a codec's only caller is
a parser that accumulates at most 19 + 15 = 34 significant digits and turns
everything past them into a residue. Measured on the C port: zero executions
across the shared corpus, 400,000 random numerals, and 76,280 finalize calls
from inputs of up to 5,000 digits. A dead path is an unverified path, so it is
replaced by an unconditional `demand`. It stays live in every full port's
`Finalize`, where multiply and FMA do reach it; a caller here that is not a
parser needs it back.

The codec stands on the interchange formats alone. It holds no intermediate
value type: parsing yields loose scalars — sign, quantum exponent, coefficient,
residue — which are finalized and written *toward* an encoding. It does not
pivot through any engine's in-memory representation, and must not be changed
to.

## License

MIT.
