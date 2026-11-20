#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Gowin build of the minimal HL2 test build rtl/hl2min/hl2min_top.v (docs/HL2MIN.md section 6), cut down from gowin/p1/build.sh:
# no AE350, no DDR3, no PLL, no video and no USB. The transceiver is generated exactly as there (the "SFP begin" section below is
# copied from that script unchanged, with the IDE default reset form by default). The part is GW5AST-LV138FPG676AC1/I0, device
# version B, and only Gowin V1.9.12.04 is used.
#
# Usage, from the repository root:
#   gowin/hl2min/build.sh            synthesis, place-and-route, bitstream
#   gowin/hl2min/build.sh --syn      synthesis only
# Output: ${OUT_DIR:-gowin/impl}/hl2min_top/ (gitignored); bitstream impl/pnr/hl2min_top.fs.
# Switches: GOWIN_IDE, OUT_DIR, GOWIN_PLACE_OPT (default 1), GOWIN_ROUTE_OPT (default 2), SFP_POR_FABRIC (default 0),
# GOWIN_DRY=1 (project written, Gowin not started) and GOWIN_SNAPSHOT=1 (rtl/ is copied into the build folder), as in
# gowin/p1/build.sh;
#   HL2MIN_N=<samples per frame> (default 968, standard frames; 5968 needs jumbo frames through the copper module)
#   HL2MIN_ADC=1                  real ADC samples instead of the HL2's test pattern (the pattern check then counts 0)
#   HL2MIN_SGMII=1                the PCS in SGMII instead of 1000BASE-X
#   HL2MIN_LANE=1                 the HL2 on lane 1 = cage SFP1 (tx_disable M20 low, M20/W18), lane 0 idle: lane 1 is generated
#                                 at 1.25 Gbit/s with 10-bit words like lane 0, with its own
#                                 transmit and receive clocks (ln1_txc, bl_rxc) for its buffers and the logic
# Every run writes the process ID of gw_sh to <out>/gw_sh.pid and prints the verdict of tools/gowin_verdict.py.
#
# Needs Gowin EDA V1.9.12.04 (Standard, a licensed install; GOWIN_IDE points at it and the default is the author's
# /c/Gowin/Gowin_V1.9.12.04_x64/IDE) with GowinModGen.exe, serdes_toml_to_csr_138k.exe and the SERDES IP data, Git Bash (cygpath,
# /proc) and python. It does not touch the board and does not need a board loader tool.
set -euo pipefail

# The IDE folder of the Gowin EDA install (the one that holds bin/gw_sh.exe): the default is the author's, so set GOWIN_IDE to yours.
GOWIN_IDE="${GOWIN_IDE:-/c/Gowin/Gowin_V1.9.12.04_x64/IDE}"
GOWIN_SH="$GOWIN_IDE/bin/gw_sh.exe"
MODGEN="$GOWIN_IDE/bin/GowinModGen.exe"
DEVICE_PN="GW5AST-LV138FPG676AC1/I0"
DEVICE_NAME="GW5AST-138C"
DEVICE_VERSION="B"
TOP="hl2min_top"

repo="$(pwd -W 2>/dev/null || pwd)"
if [ ! -f "$repo/gowin/hl2min/build.sh" ]; then
    echo "error: run from the repository root" >&2
    exit 1
fi
mode="all"
[ "${1:-}" = "--syn" ] && mode="syn"
out="${OUT_DIR:-$repo/gowin/impl}/${TOP}"
rm -rf "${out:?}"
mkdir -p "$out/ip"
lane="${HL2MIN_LANE:-0}"
case "$lane" in 0|1) ;; *) echo "error: HL2MIN_LANE must be 0 or 1" >&2; exit 1 ;; esac

# ---- SFP begin (docs/SFP_LINKS.md section 2.4): the transceiver of the two SFP+ cages. Nothing of Gowin's is in git: the wrapper
# Serdes_Top is generated here from ip/serdes/serdes.ipc, the encrypted PHY source is read from the install together with our
# define.vh and param.v, and the register file is made from ip/serdes/serdes.toml and named to place-and-route with set_csr.
# The reset form (docs/SFP_LINKS.md sections 2.3 and 2.4, IPUG1024-1.7.2E section 3.2 "Global Reset Enable") follows what was found
# on this board: the lane PLL did not lock
# with the global reset form and quad 1 `por_toggle_by_fabric = true`, and it locked with the IDE's default form.
#   SFP_POR_FABRIC=0 (default) is the IDE's default form: GowinModGen "-global_reset disable", serdes.toml as committed (quad 1
#       por_toggle_by_fabric = false) and no port por_n_i (`TR_SFP_NO_POR). The quad starts at configuration, and the firmware
#       restarts the lanes with their resets (pma_rstn_i) once the clock chip gives 125 MHz.
#   SFP_POR_FABRIC=1 is "-global_reset enable" (GowinModGen then puts por_n_i on FABRIC_POR_N_I, on the CMU resets and on every
#       lane PLL reset, and CK_AHB_I on FABRIC_CM_LIFE_CLK_O, itself) together with a copy of serdes.toml that has quad 1
#       por_toggle_by_fabric = true. A form that puts por_n_i on FABRIC_POR_N_I only and leaves the CMU and lane PLL resets tied
#       low is not offered, because it kept the lane PLL in reset on the board.
# Both forms turn the quad's own status nets of the generated wrapper into the output port sfp_diag (rtl/sfp/sfp_serdes.v):
# CMU0 and CMU1 OK, reference detect CM0 and CM1, lane 0 and lane 1 CMU OK, and lane 0 and lane 1 PMA receive lock.
# The checks below stop the build if the text that Gowin generates ever changes shape.
SERDES_DATA="$GOWIN_IDE/ipcore/SERDES_IP/IPlib/CUSTOMIZED/data"
SFP_POR_FABRIC="${SFP_POR_FABRIC:-0}"
mkdir -p "$out/serdes"
cp "$repo/gowin/p1/ip/serdes/serdes.ipc" "$out/serdes/"
sfptoml="$repo/gowin/p1/ip/serdes/serdes.toml"
if [ "$SFP_POR_FABRIC" != 0 ]; then
    sfptoml="$out/serdes/serdes_global.toml"
    python - "$repo/gowin/p1/ip/serdes/serdes.toml" "$sfptoml" <<'PYTOML'
import sys
t = open(sys.argv[1], encoding='utf-8').read()
q1 = t.index('[q1]')
end = t.index('\n[', q1 + 1)
s = t[q1:end]
if s.count('por_toggle_by_fabric = false') != 1:
    sys.exit("gowin/hl2min/build.sh: serdes.toml quad 1 has no 'por_toggle_by_fabric = false'")
t = t[:q1] + s.replace('por_toggle_by_fabric = false', 'por_toggle_by_fabric = true') + t[end:]
open(sys.argv[2], 'w', encoding='utf-8', newline='\n').write(t)
PYTOML
fi
if [ "$lane" = 1 ]; then
    # lane 1 like lane 0: 1.25 Gbit/s, 10-bit raw words
    python - "$sfptoml" "$out/serdes/serdes_lane1.toml" <<'PYL1'
import sys
t = open(sys.argv[1], encoding='utf-8').read()
a = t.index('[q1.ln1]')
b = t.index('\n[', a + 1)
s = t[a:b]
for x, y in (('tx_data_rate = "2.5G"', 'tx_data_rate = "1.25G"'), ('rx_data_rate = "2.5G"', 'rx_data_rate = "1.25G"'),
             ('width_mode = 20', 'width_mode = 10')):
    if s.count(x) != 1:
        sys.exit("gowin/hl2min/build.sh: serdes.toml [q1.ln1] has no '%s'" % x)
    s = s.replace(x, y)
open(sys.argv[2], 'w', encoding='utf-8', newline='\n').write(t[:a] + s + t[b:])
PYL1
    sfptoml="$out/serdes/serdes_lane1.toml"
fi
cat > "$out/serdes/serdes.mod" <<MOD
-type SERDES
-path $(cygpath -m "$out/serdes")/
-file_type vlg
-file_name serdes
-mod_name Serdes_Top
-series GW5AST
-device GW5AST-138
-device_version ${DEVICE_VERSION}
-package FCPBGA676A
-part_number ${DEVICE_PN}


-global_reset $([ "$SFP_POR_FABRIC" = 0 ] && echo disable || echo enable)
-protocol_module_name0 Customized_PHY_Top
-Customized_PHY_Topprotocol_module_type customized
-Customized_PHY_TopQ1Lane0 true
-Customized_PHY_TopQ1Lane1 true
-Customized_PHY_TopClock_Correction None
-Customized_PHY_TopWord_Alignment false
-Customized_PHY_TopRX_Channel_Bonding None
-Customized_PHY_TopEnableDRP false
-Customized_PHY_TopDRPPorts false
MOD
"$MODGEN" -do "$(cygpath -m "$out/serdes/serdes.mod")" > "$out/serdes/modgen.log" 2>&1 || {
    echo "GowinModGen failed for the transceiver, see $out/serdes/modgen.log" >&2; exit 1; }
python - "$out/serdes/serdes.v" "$SFP_POR_FABRIC" <<'PYWRAP'
import sys
p = sys.argv[1]
t = open(p, encoding='utf-8', errors='replace').read()
if sys.argv[2] != '0':
    need = ["input por_n_i;", ".FABRIC_POR_N_I(por_n_i)", ".FABRIC_LN0_CPLL_RESETN_I(por_n_i)",
            ".FABRIC_LN1_CPLL_RESETN_I(por_n_i)", ".FABRIC_CMU0_RESETN_I(por_n_i)", ".CK_AHB_I(q1_fabric_cm_life_clk_o)"]
    miss = [n for n in need if n not in t]
    if miss:
        sys.exit("gowin/hl2min/build.sh: the generated Serdes_Top lacks the global reset form: " + ", ".join(miss))
elif "por_n_i" in t:
    sys.exit("gowin/hl2min/build.sh: SFP_POR_FABRIC=0 but the generated Serdes_Top has por_n_i")
diag = ["q1_fabric_ln1_pma_rx_lock_o", "q1_fabric_ln0_pma_rx_lock_o", "q1_fabric_lane1_cmu_ok_o", "q1_fabric_lane0_cmu_ok_o",
        "q1_fabric_pma_cm1_dr_refclk_det_o", "q1_fabric_pma_cm0_dr_refclk_det_o", "q1_fabric_cmu1_ok_o", "q1_fabric_cmu_ok_o"]
for w in diag:
    if t.count("wire %s;" % w) != 1:
        sys.exit("gowin/hl2min/build.sh: the generated Serdes_Top has no wire " + w)
a = "module Serdes_Top ("
if t.count(a) != 1 or "\noutput " not in t:
    sys.exit("gowin/hl2min/build.sh: the generated Serdes_Top has not the expected shape; sfp_diag not added")
t = t.replace(a, "module Serdes_Top (sfp_diag, ")
i = t.index("\noutput ")
t = t[:i] + "\noutput [7:0] sfp_diag;" + t[i:]
j = t.rindex("endmodule")
t = t[:j] + "assign sfp_diag = {" + ", ".join(diag) + "};\n" + t[j:]
open(p, 'w', encoding='utf-8', newline='\n').write(t)
PYWRAP
cp "$repo/gowin/p1/ip/serdes/define.vh" "$repo/gowin/p1/ip/serdes/param.v" "$SERDES_DATA/static_macro_define.vh" "$out/ip/"
"$GOWIN_IDE/bin/serdes_toml_to_csr_138k.exe" -o "$(cygpath -m "$out/serdes.csr")" "$(cygpath -m "$sfptoml")" \
    > "$out/serdes/csr.log" 2>&1 || { echo "the transceiver's register file was not made, see $out/serdes/csr.log" >&2; exit 1; }
# ---- SFP end

# ---------------------------------------------------------------- settings, defines
n="${HL2MIN_N:-968}"
case "$n" in ''|*[!0-9]*) echo "error: HL2MIN_N must be a number" >&2; exit 1 ;; esac
if [ "$n" -lt 2 ] || [ "$n" -gt 5968 ] || [ $((n % 2)) != 0 ]; then echo "error: HL2MIN_N: even, 2 to 5968" >&2; exit 1; fi
# Register 0x30 of the HL2 holds the samples per frame in its upper half and 1 + 2 * pat in its lower half, where pat = 1 selects the test pattern.
pat=$([ "${HL2MIN_ADC:-0}" = 1 ] && echo 0 || echo 1)
reg30=$(printf '%04X%04X' "$n" $(( 1 + 2 * pat )))
sgmii=$([ "${HL2MIN_SGMII:-0}" = 1 ] && echo 1 || echo 0)
echo "\`define HL2MIN_LANE ${lane}" > "$out/hl2min_lane.v"
cat > "$out/hl2min_defines.v" <<EOF
// generated by gowin/hl2min/build.sh
EOF
[ "$SFP_POR_FABRIC" != 0 ] || echo '`define TR_SFP_NO_POR   // rtl/sfp/sfp_serdes.v: Serdes_Top without por_n_i (the IDE default reset form)' >> "$out/hl2min_defines.v"
# the core's settings: register 0x30 for the HL2 and the PCS mode (a wrapper module sets the parameters)
cat > "$out/hl2min_cfg.v" <<EOF
// generated by gowin/hl2min/build.sh: HL2 register 0x30 = 0x${reg30} (N = ${n}, test pattern ${pat}), SGMII ${sgmii}
\`define HL2MIN_REG30 32'h${reg30}
\`define HL2MIN_SGMII ${sgmii}
EOF
cat "$out/hl2min_cfg.v" "$out/hl2min_lane.v" >> "$out/hl2min_defines.v"

src="$repo"
if [ "${GOWIN_SNAPSHOT:-0}" = 1 ]; then
    cp -r "$repo/rtl" "$out/"
    src="$out"
fi
rtl=(
    rtl/n1/enc_8b10b.v rtl/n1/fcs_append.v
    rtl/sfp/sfp_rx_sym.v rtl/sfp/sfp_xstat.v rtl/sfp/sfp_pcs.v rtl/sfp/sfp_phy.v rtl/sfp/sfp_serdes.v
    rtl/hl2link/crc32_eth.v rtl/hl2link/cdc_word.v rtl/hl2link/cdc_sample_fifo.v
    rtl/hl2link/gmii_rx_in.v rtl/hl2link/eth_frame_rx.v rtl/hl2link/raw_frame_buffer.v rtl/hl2link/gap_filler.v
    rtl/hl2link/cpu_rx_ring.v rtl/hl2link/hl2_link_rx_top.v rtl/hl2link/gmii_tx_out.v
    rtl/hl2min/hl2min_clkseq.v rtl/hl2min/hl2min_sender.v rtl/hl2min/hl2min_report.v rtl/hl2min/hl2min_core.v rtl/net/chip_dna.v
    rtl/hl2min/hl2min_top.v
)
# the clock nets of the HL2's lane: lane 0 sfp_txc / n1_rxc, lane 1 ln1_txc / bl_rxc
if [ "$lane" = 1 ]; then
    sed -e 's/^CLOCK_LOC "sfp_txc"/CLOCK_LOC "ln1_txc"/' -e 's/^CLOCK_LOC "n1_rxc"/CLOCK_LOC "bl_rxc"/' "$repo/gowin/hl2min/hl2min.cst" > "$out/hl2min.cst"
    sed -e 's/\[get_nets {sfp_txc}\]/[get_nets {ln1_txc}]/' -e 's/\[get_nets {n1_rxc}\]/[get_nets {bl_rxc}]/' "$repo/gowin/hl2min/hl2min.sdc" > "$out/hl2min.sdc"
    grep -q 'ln1_txc' "$out/hl2min.sdc" && grep -q 'bl_rxc' "$out/hl2min.cst" || { echo "error: lane 1 constraints not made" >&2; exit 1; }
else
    cp "$repo/gowin/hl2min/hl2min.cst" "$out/hl2min.cst"
    cp "$repo/gowin/hl2min/hl2min.sdc" "$out/hl2min.sdc"
fi

# The Tcl script for gw_sh: project, device, sources, constraints, options and the run command.
tcl="$out/run.tcl"
{
    echo "create_project -name ${TOP} -dir {$(cygpath -m "$(dirname "$out")")} -pn ${DEVICE_PN} -device_version ${DEVICE_VERSION} -force"
    echo "set_device -name ${DEVICE_NAME} ${DEVICE_PN}"
    echo "add_file -type verilog {$(cygpath -m "$out/hl2min_defines.v")}"
    for f in "${rtl[@]}"; do echo "add_file -type verilog {$(cygpath -m "$src/$f")}"; done
    # SFP transceiver: generated wrapper and Gowin's PHY source (docs/SFP_LINKS.md 2.4)
    echo "add_file -type verilog {$(cygpath -m "$out/serdes/serdes.v")}"
    echo "add_file -type verilog {$(cygpath -m "$SERDES_DATA/customized_phy_wrapper.v")}"
    echo "add_file -type verilog {$(cygpath -m "$SERDES_DATA/customized_phy.v")}"
    echo "add_file -type cst {$(cygpath -m "$out/hl2min.cst")}"
    echo "add_file -type sdc {$(cygpath -m "$out/hl2min.sdc")}"
    echo "set_option -top_module ${TOP}"
    echo "set_option -include_path {$(cygpath -m "$out");$(cygpath -m "$out/ip");$(cygpath -m "$src/rtl/n1")}"
    echo "set_option -verilog_std sysv2017"
    echo "set_option -looplimit 20000"
    echo "set_option -use_cpu_as_gpio 1"
    echo "set_option -use_mspi_as_gpio 1"
    echo "set_option -use_sspi_as_gpio 1"
    echo "set_option -place_option ${GOWIN_PLACE_OPT:-1}"
    echo "set_option -route_option ${GOWIN_ROUTE_OPT:-2}"
    echo "set_option -timing_driven 1"
    echo "set_csr {$(cygpath -m "$out/serdes.csr")}"       # the transceiver's register file (SUG1220 3.3.19)
    echo "run ${mode}"
} > "$tcl"

if [ "${GOWIN_DRY:-0}" = 1 ]; then
    echo "gowin/hl2min/build.sh: dry run, project written to $out (run.tcl); Gowin not started"
    exit 0
fi
log="$out/gw_sh.log"
start=$(date +%s)
( cd "$out" && exec "$GOWIN_SH" run.tcl ) > "$log" 2>&1 &
gwpid=$!
cat "/proc/$gwpid/winpid" > "$out/gw_sh.pid" 2>/dev/null || echo "$gwpid" > "$out/gw_sh.pid"
if ! wait "$gwpid"; then
    echo "gowin/hl2min/build.sh: Gowin run failed after $(( $(date +%s) - start )) s, see $log" >&2
    tail -40 "$log" >&2
    exit 1
fi
echo "gowin/hl2min/build.sh: ${mode} done in $(( $(date +%s) - start )) s; bitstream $out/impl/pnr/${TOP}.fs"
if [ "$mode" = all ]; then
    python "$repo/tools/gowin_verdict.py" "$out/impl/pnr/${TOP}_tr_content.html" || true
fi
