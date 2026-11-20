<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# S10 — `tr-filters`: N2ADR filter board responses

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work package S10 (`docs/PLAN.md`): compute the N2ADR filter board's response for every low-pass
filter, the Rx high-pass filter, and the "no filter" bypass path, from the board's published
schematic and BOM part values, check the result against the DK1CG VNA measurements on the HL2
wiki, and export the curves in a format the video compositor can use. This document has every
source and every assumption; the crate itself is `fw/tr-filters`.

## 1. Sources

Component values and topology (not the files themselves — see "Why the files are not copied"
below):

- `hardware/companions/n2adr/n2adr.sch` and `n2adr.net`, from
  `github.com/softerhardware/Hermes-Lite2` (branch `master` as of this work), KiCad project
  titled "HL2 Filter Board", company N2ADR, revision `E5build8`, dated 2019-02-20. The schematic
  gives every component's reference designator and value (its `F 1` field); the netlist gives
  which pins are wired to which node, which is how the ladder topology below was reconstructed
  (see "Method" below) rather than guessed from a typical filter shape.
- N2ADR's own page, <https://james.ahlstrom.name/hl2filter/>: general construction notes used for
  the Q assumptions (capacitors are "630 volt NP0 (or C0G) in US 1206 (3216 metric)"; inductors
  "from 220n to 680n are wirewound on non-magnetic cores", larger ones on ferrite cores). This
  page does not give per-filter component values, so it was not a source for those.
- Relay part number EC2-3NU (Panasonic/Aromat DPDT signal relay), from the schematic's `F 1`
  field on `K1`-`K7`.
- Measurement: "DK1CG's measurements", two plots on the HL2 wiki page
  <https://github.com/softerhardware/Hermes-Lite2/wiki/N2ADR-Filter-Board-Plots> —
  `N2ADR_FB_losses.png` (passband detail, +0.5 to -3 dB) and `N2ADR_FB_wideband.png` (0 to
  -100 dB) — described there as "the response of the various filters measured with a VNA".
- `docs/ARCHITECTURE.md` section 8 (already in this repository): the register-bit-to-filter
  table and the Quisk receive-table citation used for the band-selection logic in
  `fw/tr-filters/src/bands.rs`.

### Why the schematic/BOM files are not copied

`docs/ARCHITECTURE.md` section 8 already flags this: no licence statement was found in the N2ADR
hardware files. Only the numeric values read out of them are used here (in
`fw/tr-filters/src/filters.rs`, with the source reference designator named next to every value),
the same way `docs/ARCHITECTURE.md` itself already treats that repository.

## 2. Method: reconstructing the ladder topology from the netlist

The schematic alone gives component values but not which components are in series versus shunted
to ground. Guessing that from a typical filter shape would be unreliable for the two bands that
turn out to have an extra pair of parts (below). Instead, `n2adr.net` (KiCad's netlist export) was
parsed for the `(net (code N) (name ...) (node (ref X) (pin Y)) ...)` blocks that mention each
filter's components, e.g. for the 60/40 m filter (relay `K3`):

```
(net (code 38) (name "Net-(C32-Pad2)") (node (ref C32) (pin 2)) (node (ref L9) (pin 1))
                                        (node (ref C35) (pin 2)) (node (ref K3) (pin 4)))
(net (code 37) (name "Net-(C35-Pad1)") (node (ref C40) (pin 2)) (node (ref L9) (pin 2))
                                        (node (ref L12) (pin 1)) (node (ref C37) (pin 2))
                                        (node (ref C35) (pin 1)))
(net (code 49) (name "Net-(C40-Pad1)") (node (ref K3) (pin 5)) (node (ref L12) (pin 2))
                                        (node (ref C42) (pin 2)) (node (ref C40) (pin 1)))
(net (code 20) (name GND) (... (node (ref C32) (pin 1)) ... (node (ref C37) (pin 1)) ...
                                (node (ref C42) (pin 1)) ...))
```

Reading this: `C32`, `C37`, `C42` each have one pin tied to the `GND` net, so they are the three
shunt capacitors. `C35` shares both its nets with `L9` (net 38 = `L9` pin 1's node, net 37 =
`L9` pin 2's node) — it is wired directly in parallel with `L9`, not in series with it. Likewise
`C40` parallels `L12`. That is an elliptic (Cauer) ladder: shunt C — [series L parallel with a
small C, forming a notch] — shunt C — [series L parallel with a small C] — shunt C. The same check
run over every relay's nets (`K1`-`K7`) gives the topology table in section 3.

Two bands come out with this extra parallel-capacitor pair (60/40 m and 30/20 m); the other four
(160 m, 80 m, 17/15 m, 12/10 m) do not — their series inductors have no capacitor sharing both
nets, so they are plain 5-element Chebyshev-style Pi ladders (shunt C — series L — shunt C —
series L — shunt C). The Rx HPF (relay `K7`) is the same shape with series and shunt swapped
(series C — shunt L — series C — shunt L — series C), confirmed the same way.

## 3. The filters, as built

All values are from the reference designators named; `fw/tr-filters/src/filters.rs` has the same
table as Rust `const` ladders, each value commented with its designator.

| Filter (relay) | Topology, left to right | Values |
|---|---|---|
| 160 m (K1) | shunt C — series L — shunt C — series L — shunt C | C21 1800p, L5 3.9u, C22 3300p, L6 3.9u, C23 1800p |
| 80 m (K2) | shunt C — series L — shunt C — series L — shunt C | C8 1000p, L1 1.8u, C9 1800p, L2 1.8u, C10 1000p |
| 60/40 m (K3) | shunt C — [series L \|\| C] — shunt C — [series L \|\| C] — shunt C | C32 270p, L9 1000n \|\| C35 100p, C37 560p, L12 680n \|\| C40 270p, C42 220p |
| 30/20 m (K4) | shunt C — [series L \|\| C] — shunt C — [series L \|\| C] — shunt C | C33 150p, L10 560n \|\| C36 39p, C38 270p, L13 270n \|\| C41 220p, C43 68p |
| 17/15 m (K5) | shunt C — series L — shunt C — series L — shunt C | C34 180p, L11 390n, C39 330p, L14 390n, C44 180p |
| 12/10 m (K6) | shunt C — series L — shunt C — series L — shunt C | C24 150p, L7 220n, C25 330p, L8 220n, C26 150p |
| Rx HPF (K7) | series C — shunt L — series C — shunt L — series C | C47 1500p, L15 1.8u, C48 680p, L4 1.8u, C49 1500p |

Every filter is symmetric input-to-output (the first and last element share the same value),
which is the standard way to design a doubly-terminated LC ladder into equal source and load
impedances — expected here since both ends see 50 ohm.

Every path (filtered or not) also carries the loss of the relay chain itself: the seven relays
are wired in a daisy chain (RF in -> K6 -> K5 -> K4 -> K3 -> K2 -> K1 -> K7 -> RF out, from the
`Net-(Kn-Pad3)`/`Net-(Kn-Pad6)` nets linking consecutive relays' bypass contacts), so selecting
any one filter still routes the signal through the other six relays' bypass contacts, and
bypassing every filter routes it through all seven. Section 5 covers how that is modelled.

## 4. Q and loss assumptions

Ideal (lossless) LC components would show 0 dB loss everywhere in the passband and could not be
checked against a real measurement, so every reactive element gets a series ESR:

- Inductor: `R_L = omega * L / Q_L`, `Q_L = 150`. This scales resistance with frequency (skin
  effect), which keeps `Q_L` itself roughly constant across the HF range the way a real wirewound
  or toroidal inductor's does, rather than pinning one resistance value that would be wrong by a
  large factor at one end of the sweep. 150 is a middle-of-the-road number for small toroidal RF
  inductors (T30-2/T37-2/T50-2-class iron powder cores, which is what "220n to 680n... wirewound
  on non-magnetic cores" on the N2ADR page describes) over 2-30 MHz; published Q curves for these
  core sizes and mixes commonly run from about 80 at the low end of a winding's usable range to
  200+ near the middle. No per-inductor Q was measured or found published for this specific
  board, so one number is used for every inductor — the honest caveat, stated once here rather
  than in every code comment.
- Capacitor: `R_C = 1 / (omega * C * Q_C)`, `Q_C = 1000`. NP0/C0G ceramic capacitors (as
  specified on the N2ADR page) have very low dielectric loss at HF; 1000 makes their contribution
  small next to the inductors', which is the realistic case, without pretending they are
  perfectly lossless.
- Relay-chain and PCB loss: a single lumped series resistance of 2.3 ohm, applied once per path
  (see `fw/tr-filters/src/filters.rs::BOARD_THRU_R_OHM`). This is **not** derived from the
  EC2-3NU's datasheet (a public one with contact-resistance figures was not found); it is
  calibrated backwards from the measured "Board_thru" VNA trace itself (about -0.2 dB, flat from
  1-30 MHz — see section 6), on the assumption that whatever combination of relay contacts, PCB
  copper and the VNA test setup's own SMA connectors produced that number applies equally to
  every path, since it is present at close to the same level under every filter's own passband
  floor too. If the real relay contact resistance is much lower than this (quite possible — 2.3
  ohm split over seven contact pairs is 0.33 ohm/contact, high for a signal relay), the remainder
  is most likely the VNA calibration reference plane and connectors, which is fine for comparing
  to that same measurement but would overstate the board's real contribution to the RX/TX chain
  budget slightly. This is flagged as an open assumption, not resolved here.

All of this lives in `fw/tr-filters/src/abcd.rs` (`QAssumptions`) and
`fw/tr-filters/src/filters.rs` (`BOARD_THRU_R_OHM`), with the same reasoning in code comments.

## 5. Method: ABCD (chain) matrix analysis

Standard two-port network analysis (`fw/tr-filters/src/abcd.rs`): each element in the ladder
becomes a 2x2 complex ABCD matrix (`[[1, Z], [0, 1]]` for a series impedance, `[[1, 0], [Y, 1]]`
for a shunt admittance), the matrices are chained by matrix multiplication left to right, and the
whole network's insertion loss between two 50 ohm ports is

```
S21 = 2 / (A + B/Z0 + C*Z0 + D)
insertion_loss_dB = 20 * log10(|S21|)
```

which is the standard formula for a two-port matched at both ends (negative values are loss, 0 dB
is lossless thru — matching the sign convention both the DK1CG plots and Quisk use). Complex
arithmetic is a small hand-written `Complex32` (`fw/tr-filters/src/complex.rs`, `f32` only —
`no_std`, and the AE350 core's `F` extension is single-precision only, no `D`), and `log10`/`sqrt`
come from the `libm` crate (pure Rust, `no_std`, no other dependency).

The "no filter" path is just the relay-chain resistance alone, no reactive elements — a flat,
frequency-independent loss.

## 6. Reading the DK1CG plots

The two plots on the wiki page are PNG images with no published underlying data file, so the
comparison numbers in this document were read directly off the images: `N2ADR_FB_losses.png`
(850x454, axes +0.5 to -3 dB / 3e5 to 3e8 Hz) and `N2ADR_FB_wideband.png` (808x443, axes 0 to
-100 dB / 3e5 to 3e9 Hz), both by pixel-colour tracing:

1. Located the plot's border and the printed axis gridlines by scanning for long runs of
   near-black (border) and light-grey (gridline) pixels, then confirmed the pixel-to-value
   mapping by checking that gridlines land exactly where the log-frequency axis predicts (e.g.
   the 1, 10 and 100 MHz decade boundaries), which they do to within a pixel throughout. This was
   a one-off analysis step (a scratch Python script, not part of this repository); the method is
   recorded here in full and the resulting digitized points are in `docs/s10_dk1cg_digitized.json`
   so the numbers themselves are reproducible even though the throwaway script is not kept.
2. Identified each curve's legend colour by sampling the legend text pixels directly (RGB, e.g.
   `160m` = pure magenta `(255,0,255)`, `17/15m` = a slightly lighter orchid `(255,85,255)` — the
   two are close enough that they need the exact RGB, not just "magenta", to tell apart).
3. For every pixel column in the plot area, averaged the y-position of pixels matching each
   curve's colour (within a tolerance loose enough for anti-aliasing, tight enough not to pick up
   the axis border) and converted (x, y) to (frequency, dB) with the calibrated linear/log
   mapping.

This is read-off-a-picture accuracy, not the original VNA trace: figure on a few hundredths of a
dB of quantization from the plot's own pixel resolution, plus up to about a pixel-width of
frequency uncertainty near steep skirts. The digitized points are in
`docs/s10_dk1cg_digitized.json` (frequency in Hz, dB, one array per filter, with the same
provenance note inline). `docs/plot_s10_filters.py` reads that file and overlays it on freshly
computed curves from `tr-filters` to make the PNGs in `docs/img/`.

One digitizing artifact worth flagging: in the wideband image only, a handful of points for three
curves (`60/40m`, `30/20m`, `HPF`) land on a spurious flat band a few dB below where the curve
actually is — almost certainly colour bleed between adjacent, closely-drawn curves at that image's
lower resolution (808x443 for eight overlaid traces). The passband-detail image
(`N2ADR_FB_losses.png`) does not show this, and is what section 7's numbers below use.

## 7. Comparison against the measurement

### Passband loss (done-test: within 1 dB)

Average measured loss (from `N2ADR_FB_losses.png`, over each filter's intended amateur band) vs.
this crate's computed average over the same range:

| Filter | Measured avg (dB) | Computed avg (dB) | \|difference\| |
|---|---|---|---|
| 160 m | -0.64 | -0.34 | 0.30 |
| 80 m | -0.77 | -0.35 | 0.42 |
| 60/40 m | -0.82 | -0.31 | 0.51 |
| 30/20 m | -0.69 | -0.29 | 0.40 |
| 17/15 m | -0.83 | -0.36 | 0.47 |
| 12/10 m | -0.91 | -0.39 | 0.52 |
| Rx HPF | -0.37 | -0.22 | 0.14 |
| No filter (thru) | -0.22 | -0.19 | 0.03 |

Every filter is within 1 dB — done-test met for passband loss, with room to spare (worst case
0.52 dB). The computed loss runs consistently a little lower than measured, which fits the model:
Q assumptions are a single mid-range number per component type rather than the real, individually
varying parts, and the calibrated 2.3 ohm relay/board loss is a flat floor shared by all eight
paths rather than something that could track a filter-specific difference.

### Cutoff frequency and loss at cutoff (done-test: within 1 dB)

The -3 dB point, read both ways — the frequency where each curve crosses -3 dB, and (separately)
the loss this model computes at the frequency where the *measurement* crosses -3 dB:

| Filter | Measured -3 dB (MHz) | Computed -3 dB (MHz) | Frequency diff | Computed loss at measured -3 dB freq |
|---|---|---|---|---|
| 160 m | 2.67 | 2.67 | 0.2 % | -3.47 dB (0.47 dB off) |
| 80 m | ~5.35 | 5.36 | <1 % | -2.47 dB (0.53 dB off) |
| 60/40 m | 8.83 | 9.23 | 4.5 % | -1.14 dB (**1.86 dB off**) |
| 30/20 m | 17.30 | 17.72 | 2.4 % | -1.70 dB (**1.30 dB off**) |
| 17/15 m | 26.60 | 26.73 | 0.5 % | -2.80 dB (0.20 dB off) |
| 12/10 m | ~36.7 | 37.44 | ~2 % | -2.21 dB (0.79 dB off) |

Four of six low-pass filters meet the 1 dB done-test on both readings. The two that do not on the
"loss at the measured cutoff frequency" reading — 60/40 m and 30/20 m — are exactly the two
elliptic (Cauer) filters, the ones with a notch capacitor across each series inductor (section 3).
Their skirts are steep (that is the point of the elliptic design — better stopband rejection per
component), so a cutoff-frequency error of only 2-4.5 %, well inside typical component tolerance
for NP0 chip capacitors (+-5 %) and small hand-wound toroids (commonly +-5-10 % turn-count and
core-permeability variation), shows up as more than 1 dB when read at one fixed frequency, even
though the curve shape, both notch depths, and the notch frequencies themselves (visible in
`docs/img/s10_60_40m_wideband.png` and `docs/img/s10_30_20m_wideband.png`) line up closely with
the measurement. Nominal published part values were used throughout, deliberately not hand-tuned
to force a closer fit — doing that would fit this one board's measurement rather than the
schematic's stated values, which is what the work package asked to compute from. The honest
summary: passband loss matches within 1 dB everywhere, cutoff frequency matches within 5 % (and
better than 1 % for four of six filters) everywhere, and only the two steepest filters' loss
value at one specific frequency point misses the 1 dB bar, for a reason (component tolerance)
that a from-nominal-values model cannot close without measuring the actual board.

### Plots

`docs/img/s10_<filter>_passband.png` (one per filter, 0.5 to -3 dB, log frequency, matches
`N2ADR_FB_losses.png`'s own range) and `docs/img/s10_<filter>_wideband.png` (0 to -90 dB, for the
two elliptic filters, 160 m and the HPF, matching `N2ADR_FB_wideband.png`'s range) show the
computed curve as a line over the digitized measurement as points.
`docs/img/s10_fullband_0_38_4MHz.png` is the actual work-package deliverable range: all eight
curves, 0-38.4 MHz, linear frequency — the same shape the compositor table (section 8) exports.
Regenerate all of them with `python docs/plot_s10_filters.py` (needs `numpy` and `matplotlib`; it
shells out to `cargo run --example dump_curves -p tr-filters` itself, so the plots are always
built from the current Rust model).

## 8. Compositor export format (proposed)

`docs/ARCHITECTURE.md` section 3.5 fixes the *final* form the compositor consumes — "a per-column
y table in BSRAM ... up to 8 curves" — but that is necessarily built at render time (it depends on
the on-screen window's current width and dB scale, which change as the operator zooms). What this
crate exports instead, since ARCHITECTURE does not fix a source format, is resolution-independent:
[`tables::CurveTable`](../fw/tr-filters/src/tables.rs) — 385 points, 100 kHz apart, covering 0 to
38.4 MHz, insertion loss stored as hundredths of a dB in an `i16`. 770 bytes per filter, 6,160
bytes for all eight (7 filters + no-filter — matching "up to 8 curves" exactly, which is also why
`FilterId::NoFilter` is a full member of the set rather than a special case). Firmware calls
`tables::build_table` once per filter (plain arithmetic, no allocation, fine to run at boot on
the AE350 target) and resamples/rasterizes each `CurveTable` into whatever window is currently on
screen with `CurveTable::lookup_db`'s linear interpolation.

## 9. Band selection and the interferer helper

`fw/tr-filters/src/bands.rs`:

- `select_filter_for_freq(freq_hz)`: the tightest low-pass whose amateur band covers the
  frequency, matching the bit table in `docs/ARCHITECTURE.md` section 8.
- `select_filter_for_freqs(freqs_hz)`: the owner decision recorded there — "the firmware chooses
  one filter set that passes every active receiver" — implemented as picking the filter for the
  *highest* frequency among active receivers, since every low-pass on this board passes
  everything below its own cutoff.
- `is_outside_passband` / `OUTSIDE_PASSBAND_DB`: the other half of that same decision — "the
  display marks receivers that fall outside the chosen passband" — using the `CurveTable` so it
  is a cheap lookup, not a recomputation, at render/receive time.
- `hpf_should_engage(selected_lpf)`: Quisk's rule (`quisk_conf_defaults.py` lines 495-497, cited
  in `docs/ARCHITECTURE.md`) — the Rx HPF is in line for every band except 160 m.
- `best_filter_for_interferers(wanted_freq_hz, interferers, tables)`: the requested "helper that,
  given the signals in a spectrum, says which filter best attenuates strong out-of-band signals".
  Takes the wanted frequency and a list of `(interferer_freq, level)` pairs (from the spectrum,
  any consistent level unit), discards any candidate filter that would itself clip the wanted
  signal (worse than -3 dB), and picks the remaining filter that leaves the *strongest* residual
  interferer weakest after filtering — i.e. minimises the worst case, not the average, since one
  strong out-of-band signal getting through is usually the operative problem, not the total.

Open item the doc's section 8 already flagged and this work package does not resolve: which
physical relay contact bit 23 actually selects (the note about "normally bypassed" vs "normally
in line" read against Quisk's table) — that needs the AM-broadcast-band capture test on the real
HL2, not a filter-response calculation.

## 10. What is unfinished

- Component Q is one assumed number per component type, not measured or per-part; section 4 has
  the reasoning and the honest caveat.
- The 2.3 ohm relay/board loss is calibrated from the measurement, not derived independently
  (section 4).
- Two elliptic filters' loss at their exact measured cutoff frequency misses the 1 dB bar by up
  to 0.86 dB, attributed to ordinary component tolerance on nominal published values (section 7);
  everything else meets it.
- `tr-filters` is not yet called from any other crate (`tr-gui`'s compositor overlay, `tr-hl2`'s
  filter-select register writes) — those are separate, later work packages per `docs/PLAN.md`.
- The relay-bit-polarity open question noted above needs the real board.
