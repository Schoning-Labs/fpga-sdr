#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Measures the resources and timing of one RTL block with Gowin EDA, for the "Gowin measured" column of the chip ledger
# (docs/ARCHITECTURE.md section 3.14) and for comparison with the yosys estimate that tools/yosys_res.sh gives for the same block.
# It runs real Gowin synthesis and place-and-route (not synthesis only) with a clock constraint (120 MHz unless --period-ns says
# otherwise) and reports logic (LUT + ALU + LUTRAM, the same "Logic" figure that Gowin reports against the 138,240 LUT4 of the
# chip), registers, DSP, BSRAM and the worst setup slack with Fmax.
#
# Gowin EDA has no out-of-context place-and-route mode, as far as the GowinSynthesis user guide SUG550 (section 5, "Synthesis
# Constraints Support") and the -help text of every gw_sh Tcl command show, and `set_option -disable_io_insertion 1` still gives
# every port a real package pin. Measuring with one pin per port distorts the timing, because the logic is pulled toward pads
# that are spread over the die (gowin/reports/README.md), so every block should be measured with --wrap: gowin/gen_wrap.py (see
# its header) generates <top>_ooc_wrap around the block, with every port except the clock and rst on register shift chains, and
# the summary then also gives the block's own logic and registers ("Block alone", the wrapper's cells subtracted). --chain sets
# the chain length (default 64).
#
# Usage, from the repository root (the relative $readmemh and `include paths, and the rtl and hw junctions that this script
# makes, resolve from there):
#   gowin/res.sh <top> [--clk <port>] [--clk2 <port>] [--period-ns <ns>] [--wrap [--chain <n>]] [--sdc <file>]...
#                [--opt "<name> <value>"]... <file.v> ...
# <port> defaults to "clk" and <ns> to 8.333 (120 MHz). Pass --clk clock for tx_chain (rtl/tx/tx_chain.v names its clock port
# `clock` and has a separate `pace` strobe, see the header of that file). --clk2 names a second clock port and is handed to
# gen_wrap.py, so it only matters with --wrap. Without --wrap, <top> is run as it is, for example a hand-written wrapper such as
# gowin/wrap/spectrum_pipeline_ooc_wrap.v. --sdc appends the timing exceptions of a block (for example
# rtl/rx_backend/rx_backend.sdc) after the clock constraint and may be given more than once; their register patterns have to
# match through the wrapper's instance (u_dut/...), so write them with a leading "*". --opt "<name> <value>" adds a Gowin
# `set_option -<name> <value>` (for example --opt "replicate_resources 1") and may be given more than once.
#
# Examples (gowin/reports/README.md has the full list):
#   gowin/res.sh audio_engine --wrap rtl/audio/audio_ring_reader.v rtl/audio/audio_interp_x8.v \
#       rtl/audio/audio_nco_tick.v rtl/audio/audio_pt8211_tx.v rtl/audio/audio_engine.v
#   gowin/res.sh tx_chain --clk clock --wrap rtl/tx/tx_fir_interp4.v rtl/tx/CicInterpM5.v \
#       rtl/rx/nco_mixer.v rtl/tx/tx_chain.v
#
# Environment: GOWIN_SH (the gw_sh.exe to use), OUT_DIR, GOWIN_NUM_PATHS (list that many critical paths in the timing report
# instead of Gowin's default 25) and GOWIN_RUN=syn (synthesis only; the cell counts come from the netlist with
# tools/gowin_mems.py and there is no summary).
#
# Writes the Gowin project, netlist and reports to ${OUT_DIR:-gowin/impl}/<top>/ (gitignored: "impl/" in .gitignore matches this
# at any depth) and prints one summary line. The full synthesis and place-and-route reports stay under that directory; copy only
# the small excerpts that matter into gowin/reports/<top>/ by hand (see gowin/reports/README.md) and do not commit the impl tree
# itself (bitstream, netlist and the logs of each run, tens of MB per block).
#
# Needs Gowin EDA V1.9.12.04 (Standard, a licensed install; the default of GOWIN_SH below is the author's install, so set
# GOWIN_SH to your own gw_sh.exe), Windows with powershell.exe (for the junctions) and Git Bash (cygpath), and python for
# gowin/gen_wrap.py. With --wrap the bin and lib folders of oss-cad-suite are put on PATH from the author's /c/tools/oss-cad-suite
# (change that export line). It does not touch the board and does not need a board loader tool.
set -euo pipefail

# gw_sh.exe of the Gowin EDA install: the default is the author's V1.9.12.04 folder, and the GOWIN_SH environment variable
# replaces it. The part below is the chip of the Tang Mega 138K Pro.
GOWIN_SH="${GOWIN_SH:-/c/Gowin/Gowin_V1.9.12.04_x64/IDE/bin/gw_sh.exe}"
DEVICE_PN="GW5AST-LV138FPG676AC1/I0"
DEVICE_NAME="GW5AST-138C"
DEVICE_VERSION="B"

# Everything is resolved from the repository root, so refuse to run from anywhere else.
repo="$(pwd -W 2>/dev/null || pwd)"
if [ ! -d "$repo/rtl" ] || [ ! -f "$repo/gowin/res.sh" ]; then
    echo "error: run this from the repository root (rtl/ and gowin/res.sh must be there)" >&2
    exit 1
fi

# The first argument is the top module of the block; the options follow, then the source files.
top="$1"; shift
clk_port="clk"
period_ns="8.333"
wrap=0
chain=64
clk2_port=""
extra_sdc=()
extra_opt=()
while [ $# -gt 0 ]; do
    case "$1" in
        --clk) clk_port="$2"; shift 2 ;;
        --clk2) clk2_port="$2"; shift 2 ;;
        --period-ns) period_ns="$2"; shift 2 ;;
        --wrap) wrap=1; shift ;;
        --chain) chain="$2"; shift 2 ;;
        --sdc) extra_sdc+=("$2"); shift 2 ;;
        --opt) extra_opt+=("$2"); shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done
files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
    echo "usage: gowin/res.sh <top> [--clk <port>] [--period-ns <ns>] [--wrap [--chain <n>]] [--sdc <file>]... <file.v> ..." >&2
    exit 1
fi

# Each run gets its own project folder under out_dir, named after the top module and emptied first.
out_dir="${OUT_DIR:-$repo/gowin/impl}"
dut="$top"
if [ "$wrap" = 1 ]; then
    top="${dut}_ooc_wrap"
fi
projdir="$out_dir/$top"
rm -rf "${projdir:?}"
mkdir -p "${projdir:?}"

if [ "$wrap" = 1 ]; then
    # gowin/gen_wrap.py (see its header): every port but the clock and rst on shift-chain
    # registers, so place-and-route sees a handful of pins and every timed path is register to
    # register. The wrapper's own clock port is always `clk`.
    export PATH="/c/tools/oss-cad-suite/bin:/c/tools/oss-cad-suite/lib:$PATH"
    python "$repo/gowin/gen_wrap.py" "$dut" "$projdir/${top}.v" --chain "$chain" --clk "$clk_port" ${clk2_port:+--clk2 "$clk2_port"} "${files[@]}"
    files+=("$projdir/${top}.v")
    clk_port="clk"
fi

# Junctions so that `include "hw/regmap/generated/*.vh" and $readmemh "rtl/.../*.hex" resolve (the RTL writes both relative to the
# repository root, the convention of tools/yosys_res.sh): create_project below changes the working directory of gw_sh to $projdir,
# and Gowin resolves both relative to that working directory and not to the folder of the including file.
powershell.exe -NoProfile -Command \
    "New-Item -ItemType Junction -Path '$(cygpath -w "$projdir/rtl")' -Target '$(cygpath -w "$repo/rtl")' | Out-Null; \
     New-Item -ItemType Junction -Path '$(cygpath -w "$projdir/hw")' -Target '$(cygpath -w "$repo/hw")' | Out-Null"

# The timing constraints: the clock first, then the files of --sdc appended in the order given.
sdc="$projdir/clk.sdc"
cat > "$sdc" <<EOF
create_clock -name ${clk_port} -period ${period_ns} [get_ports {${clk_port}}]
EOF
for f in ${extra_sdc[@]+"${extra_sdc[@]}"}; do
    case "$f" in
        /*|?:*) cat "$f" ;;
        *) cat "$repo/$f" ;;
    esac >> "$sdc"
done

freq_mhz=$(awk -v p="$period_ns" 'BEGIN { printf "%.3f", 1000.0 / p }')

# The Tcl script for gw_sh: project, device, sources, constraints, options and the run command.
tcl="$projdir/run.tcl"
{
    echo "create_project -name ${top} -dir {$(cygpath -m "$out_dir")} -pn ${DEVICE_PN} -device_version ${DEVICE_VERSION} -force"
    echo "set_device -name ${DEVICE_NAME} ${DEVICE_PN}"
    # Gowin has no command-line define: the first source file carries them (one compilation unit).
    # GOWIN_DSP: rtl/rx/fir_decim.v instantiates the MULTALU27X18 block instead of its simulation model.
    echo '`define GOWIN_DSP' > "$projdir/defines.v"
    echo "add_file -type verilog {$(cygpath -m "$projdir/defines.v")}"
    for f in "${files[@]}"; do
        case "$f" in
            /*|?:*) abs="$f" ;;
            *) abs="$repo/$f" ;;
        esac
        echo "add_file -type verilog {$(cygpath -m "$abs")}"
    done
    echo "add_file -type sdc {$(cygpath -m "$sdc")}"
    echo "set_option -top_module ${top}"
    echo "set_option -include_path {$(cygpath -m "$projdir")}"
    echo "set_option -global_freq ${freq_mhz}"
    # Gowin's default loop limit is 2000, and several blocks here initialize a RAM array in an unrolled `initial` for loop (for
    # example the g_ram branch of rtl/fft/fft_delay.v, with L up to 8192 for the 16k-point full-band FFT). Gowin's parser rejects
    # that as "Loop count limit ... exceeded, condition is never false" when the limit is lower than the loop.
    echo "set_option -looplimit 20000"
    # GOWIN_NUM_PATHS: list more than Gowin's default 25 critical paths in the timing report
    # (useful when many endpoints fail; the digest below still shows the worst one).
    if [ -n "${GOWIN_NUM_PATHS:-}" ]; then
        echo "set_option -num_critical_paths ${GOWIN_NUM_PATHS}"
    fi
    for o in ${extra_opt[@]+"${extra_opt[@]}"}; do
        echo "set_option -${o}"
    done
    # GOWIN_RUN=syn: synthesis only (cell counts from the netlist with tools/gowin_mems.py; no summary)
    echo "run ${GOWIN_RUN:-all}"
} > "$tcl"

# Run gw_sh inside the project folder; on a failure the end of its log is shown.
log="$projdir/gw_sh.log"
( cd "$projdir" && "$GOWIN_SH" run.tcl ) > "$log" 2>&1 || {
    echo "gowin/res.sh: Gowin run failed for ${top}, see $log" >&2
    tail -40 "$log" >&2
    exit 1
}

if [ "${GOWIN_RUN:-all}" != all ]; then
    echo "${top}: ${GOWIN_RUN} only, netlist $projdir/impl/gwsynthesis/${top}.vg"
    exit 0
fi

rpt="$projdir/impl/pnr/${top}.rpt.txt"
tr_html="$projdir/impl/pnr/${top}_tr_content.html"
summary="$projdir/summary.txt"

# Each of these already reads "<used>/<total>" (for example "364/138240"), taken verbatim from the Resource Usage Summary table of
# Gowin. Gowin leaves out the DSP and BSRAM rows entirely when a design uses neither (seen with ddr3_write_arbiter_ooc_wrap, which
# has no such rows at all), so a missing match there means zero and not unknown.
logic=$(awk -F'\\|' '/Logic  *\|/ { gsub(/ /,"",$2); print $2; exit }' "$rpt" || true)
register=$(awk -F'\\|' '/^  Register  *\|/ { gsub(/ /,"",$2); print $2; exit }' "$rpt" || true)
bsram=$(awk -F'\\|' '/^  BSRAM  *\|/ { gsub(/ /,"",$2); print $2; exit }' "$rpt" || true)
dsp=$(awk -F'\\|' '/^  DSP  *\|/ { gsub(/ /,"",$2); print $2; exit }' "$rpt" || true)
logic="${logic:-0/138240}"
register="${register:-0/139140}"
bsram="${bsram:-0/340}"
dsp="${dsp:-0/298}"

tr_text=$(sed -e 's/<[^>]*>/ /g' -e 's/&nbsp;\?/ /g' "$tr_html" 2>/dev/null | tr -s ' \t\r\n' ' ')
fmax_line=$(echo "$tr_text" | grep -oE '[0-9]+\.[0-9]+\(MHz\) [0-9]+\.[0-9]+\(MHz\) [0-9]+ [A-Za-z0-9_]+' | head -1 || true)
tns_setup=$(echo "$tr_text" | grep -oE '[A-Za-z0-9_]+ Setup -?[0-9]+\.[0-9]+ [0-9]+' | head -1 || true)
# Node names contain [ ] . / so match them as "any non-space run" rather than an explicit
# character class (a class with escaped brackets is not portable ERE and grep -E rejects it).
worst_path=$(echo "$tr_text" | grep -oE "Data Delay 1 -?[0-9]+\.[0-9]+ [^ ]+ [^ ]+ ${clk_port}:\[[A-Z]\] ${clk_port}:\[[A-Z]\]" | head -1 || true)

# With --wrap: the block's own share, i.e. the totals minus the wrapper's own cells. The wrapper
# is the top row of Gowin's synthesis hierarchy report (each row there counts only that module's
# own cells, not its children's); its registers and LUT/ALU/RAM16 are subtracted from the
# place-and-route totals. DSP and BSRAM need no correction (the wrapper has none).
dut_line=""
if [ "$wrap" = 1 ]; then
    syn_rsc="$projdir/impl/gwsynthesis/${top}_syn_resource.html"
    # after the header row: the wrapper's name, then REG, ALU, LUT, DSP, BSRAM, SSRAM, ROM16
    wr=$(sed -e 's/<[^>]*>/ /g' -e 's/&nbsp;\?//g' "$syn_rsc" 2>/dev/null | tr -s ' \t\r' ' ' \
        | grep -v '^ *$' \
        | awk '/ROM16 NUMBER/ {getline; for (i = 0; i < 7; i++) {getline; v[i] = ($1 == "-") ? 0 : $1}
                               print v[0], v[1] + v[2] + 6 * v[5] + v[6]; exit}' || true)
    if [ -n "$wr" ]; then
        w_reg=${wr% *}; w_logic=${wr#* }
        dut_line="${dut}: Logic $(( ${logic%/*} - w_logic ))  Register $(( ${register%/*} - w_reg ))  (the wrapper's own ${w_logic} logic and ${w_reg} registers subtracted)"
    fi
fi

{
    echo "=== ${top}: Gowin ${GOWIN_SH##*/} resource and timing (target ${freq_mhz} MHz, ${period_ns} ns) ==="
    echo "Logic ${logic}  Register ${register}  DSP ${dsp}  BSRAM ${bsram}"
    [ -n "$dut_line" ] && echo "Block alone: ${dut_line}"
    echo "Max Frequency Summary row: ${fmax_line:-not found, see $tr_html}"
    echo "Total Negative Slack (setup): ${tns_setup:-not found, see $tr_html}"
    echo "Worst path: ${worst_path:-not found, see $tr_html}"
} > "$summary"

echo "${top}: Logic ${logic}, Register ${register}, DSP ${dsp}, BSRAM ${bsram} -- ${fmax_line:-Fmax n/a}  (full reports: $projdir/impl, digest: $summary)"
[ -n "$dut_line" ] && echo "  block alone: ${dut_line}"
exit 0
