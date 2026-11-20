#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Resource count of one RTL block for the chip ledger (docs/ARCHITECTURE.md section 3.14), made with the synth_gowin -family gw5a
# flow of yosys (synthesis only; Gowin place-and-route gives the real numbers, see gowin/res.sh).
#
# Differences from a plain `synth_gowin -family gw5a`:
#   - every multiplier is counted as DSP blocks (pieces of at most 27 x 36, see tools/yosys_res_dsp_stub.v) instead of being built
#     from LUTs, which is what yosys otherwise does for gw5a;
#   - the summary line reports "logic" = LUT1..LUT4 + ALU + 6 x RAM16SDP4, the quantity that Gowin counts against the 138,240
#     LUT4 of the GW5AST-138 (a RAM16SDP4 occupies 3 CLS = 6 LUTs of a CFU). MUX2_LUT5..8 are the dedicated wide-function muxes of
#     the CFU and not LUTs, so they are reported separately and not added. LUT1 is reported separately too (yosys buffers and
#     inverters that a vendor mapper normally absorbs).
#
# Usage, from the repository root (relative $readmemh and `include paths resolve from there):
#   tools/yosys_res.sh <top> [--chparam "<chparam args>"] <file.v> ...
# Example:
#   tools/yosys_res.sh fft_r22sdf --chparam "-set LOG_N 12 -set IW 17 -set REAL_IN 0 fft_r22sdf" \
#       rtl/fft/fft_mul.v rtl/fft/fft_delay.v rtl/fft/fft_bf.v rtl/fft/fft_twmul.v rtl/fft/fft_r22sdf.v
# It writes the yosys log and statistics to ${OUT_DIR:-/tmp}/yosys_res_<top>.* and prints one line.
#
# Needs the yosys of oss-cad-suite, which the export line below looks for in /c/tools/oss-cad-suite (the author's install, so
# change the folder there). It does not use Gowin EDA or the board.
set -euo pipefail

# yosys and its libraries from the oss-cad-suite install of the author's PC; change the folder if yours is elsewhere.
export PATH="/c/tools/oss-cad-suite/bin:/c/tools/oss-cad-suite/lib:$PATH"
# Folder of this script in Windows form, for the read_verilog line of the DSP stub in the yosys script below.
here="$(cd "$(dirname "$0")" && (pwd -W 2>/dev/null || pwd))"
top="$1"; shift
chp=""
if [ "${1:-}" = "--chparam" ]; then chp="chparam $2"; shift 2; fi
out_dir="${OUT_DIR:-/tmp}"
mkdir -p "$out_dir"
# Windows-style path for the same reason as $here: paths written as text inside the .ys script (the `tee -o ...` command below)
# do not go through the path conversion that MSYS applies to a plain command-line argument (like -l "${out}.log" below), so yosys
# sees the literal string and, as a Windows build, cannot open a bare /tmp/... path and needs a real Windows path here.
out_dir_w="$(cd "$out_dir" && (pwd -W 2>/dev/null || pwd))"
out="${out_dir_w}/yosys_res_${top}"
ys="${out}.ys"

{
    echo "read_verilog -lib ${here}/yosys_res_dsp_stub.v"
    echo "read_verilog $*"
    [ -n "$chp" ] && echo "$chp"
    echo "synth_gowin -family gw5a -top ${top} -noiopads -run begin:coarse"
    # The 'coarse' step of synth_gowin itself, with the DSP split inserted after 'share' (the place where synth_gowin puts it
    # for gw1n and gw2a).
    for c in proc check flatten "tribuf -logic" deminout opt_expr opt_clean "opt -nodffe -nosdff" \
             fsm opt wreduce peepopt opt_clean share; do echo "$c"; done
    echo "techmap -map +/mul2dsp.v -D DSP_A_MAXWIDTH=27 -D DSP_B_MAXWIDTH=36 -D DSP_A_MINWIDTH=6 -D DSP_B_MINWIDTH=6 -D DSP_NAME=MULBB"
    for c in alumacc opt "memory -nomap" opt_clean; do echo "$c"; done
    echo "synth_gowin -family gw5a -top ${top} -noiopads -run map_ram:"
    echo "tee -o ${out}.stat.txt stat"
} > "$ys"

yosys -q -l "${out}.log" -s "$ys" > /dev/null

# Add up the cell counts of the statistics file by type and print the one summary line.
awk -v top="$top" '
    / LUT1$/ { l1 += $1 }
    / LUT[1-4]$/ { lut += $1 }
    / ALU$/ { alu += $1 }
    / MUX2_LUT[5-8]$/ { mux += $1 }
    / RAM16S[A-Z0-9]*$/ { lr += $1 }
    / DFF[A-Z]*$/ { ff += $1 }
    / MULBB$/ { dsp += $1 }
    / (DPB|DPX9B|SDPB|SDPX9B|SP|SPX9|pROM|pROMX9)$/ { bram += $1 }
    END {
        printf "%s: DSP %d, BSRAM(18k) %d, logic %d (LUT %d incl. LUT1 %d, ALU %d, LUTRAM %d x 6), MUX2 %d, FF %d\n",
               top, dsp, bram, lut + alu + 6 * lr, lut, l1, alu, lr, mux, ff
    }' "${out}.stat.txt"
