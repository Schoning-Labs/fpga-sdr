#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Full-chip Gowin build of rtl/top/sdr_top.v (docs/P1_TOP.md section 9): it regenerates the IP from the committed
# configuration and then runs Gowin EDA Standard synthesis, place-and-route and bitstream generation (docs/TOOLCHAIN.md) for
# GW5AST-LV138FPG676AC1/I0, device version B, the chip of the Tang Mega 138K Pro.
#
# IP (only the configuration is committed, docs/ARCHITECTURE.md section 7):
#   gowin/p1/ip/riscv_ae350_soc.ipc  -> riscv_ae350_config.v via ipc_to_config.py; the IP's own sources are compiled straight
#                                       from the Gowin install (IDE/ipcore/RiscV_AE350_SOC/data), which also holds the source
#                                       of Gowin's DDR3 IP (see the header of ipc_to_config.py)
#   hw/gowin/mem/gwmc_param.v           the settings of the DDR3 IP for the board's two chips (TR_DDR=1024)
#   gowin/p1/ip/gowin_pll_*.mod      -> gowin_pll_*.v via GowinModGen (command line)
#
# Usage, from the repository root:
#   gowin/p1/build.sh            synthesis, place-and-route, bitstream
#   gowin/p1/build.sh --syn      synthesis only
# Receivers: TR_NRX=1..8 (default 4, rtl/top/sdr_core.v). TR_NRX=8 TR_NO_ZOOM=1 is the 8-receiver chip without the zoom.
# Output: ${OUT_DIR:-gowin/impl}/sdr_top/ (gitignored). Reports: impl/pnr/sdr_top.rpt.txt,
# impl/pnr/sdr_top_tr_content.html; bitstream impl/pnr/sdr_top.fs.
#
# DDR3 switch (docs/MEM_1GB.md):
#   TR_DDR=1024 (default)  both memory chips, 1 GB: the AE350 with "Customized Data Memory", Gowin's DDR3 IP
#                        with 32 data lines and the bridge rtl/mem/ddr_mem.v in the logic
#   TR_DDR=256           the fall-back: the AE350's own shared DDR3 controller, one chip, 256 MB
#                        (riscv_ae350_soc_256.ipc, `TR_DDR_256 in the top level, the constraints without their
#                        "DDR3-1G-ONLY" blocks). It tells a board fault from a fault of the bridge.
#
# Further chip switches: TR_USBH_PMOD=1 moves the USB host board to PMOD1 (docs/USB_HOST.md section 4), TR_SFP_TXC_OWN=1 gives
# SFP lane 1 its own transmit clock (docs/SFP_LINKS.md section 1), SFP_POR_FABRIC=1 selects the global reset form of the
# transceiver (see the SFP section below), and TR_FLASH_REGION, TR_FLASH_PAT and TR_FLASH_PORT are a placement experiment for the
# flash controller of the AE350 (see the section on it below).
#
# Environment switches (most of them are described in docs/TANG_LESSONS.md
# section 7; with none set the build is the plain one, plus the post-place file):
#   GOWIN_IDE            the IDE folder; the default is the author's V1.9.12.04 install (/c/Gowin/Gowin_V1.9.12.04_x64/IDE),
#                        the version this repository is built with, so set it to your own install
#   OUT_DIR              build folder, absolute; one per run, so runs can go side by side
#   GOWIN_PLACE_OPT      -place_option, default 2 (docs/DECISIONS.md, 2026-11-19: place 2 closes timing, 1 and 3 do not)
#   GOWIN_ROUTE_OPT      -route_option, default 2 (1 measured best on this chip)
#   GOWIN_REPLICATE      -replicate_resources 0 or 1; not set by default
#   GOWIN_PNR_OPTS       further text for one set_option line, e.g. "-clock_route_order 1"
#   TIMING_MARGIN_PCT    tightens clk_dsp, clk_pix and clk_pix5 by that many percent in the build's copy of the
#                        constraints (default 0 = the real clocks; 5 is a common margin)
#   GOWIN_REPORTS=1      asks the timing report for 300 clk_dsp paths instead of 25, the 50 nets with the most
#                        loads and the 50 most congested grids (the last two are only checked on V1.9.12.04)
#   GOWIN_SNAPSHOT=1     copies rtl/ and hw/ into the build folder instead of linking them, so the sources may
#                        be edited while the run goes
#   GOWIN_DRY=1          writes the project (IP, constraints, run.tcl) and stops before Gowin starts
#   KEEP_DIR / TAG       deliverables (netlist, sdc, cst, timing and place reports, logs, bitstream, build.txt) are copied to
#                        KEEP_DIR after every run, also a failed one; the default is fpga-sdr-builds/<TAG> next to the repository folder;
#                        set KEEP_DIR to put them elsewhere. KEEP_DIR=none turns it off.
#   TIMING_GATE=1        stops the build after synthesis when the timing estimate (tools/levels/timing_est.py of the author's
#                        sister repository tangcommon) puts an end point above its requirement; LEVELS_FORCE=1 overrides;
#                        LEVELS_ONLY=1 stops after synthesis and the estimate; TIMING_MODEL picks the fitted model (default
#                        gowin/p1/timing_model.json, else the one of tangcommon); TIMING_PY is the estimator script (default
#                        G:/proj/tangcommon/tools/levels/timing_est.py)
# Every run writes the process ID of gw_sh to <out>/gw_sh.pid (tools/gowin_watch.py ends a stalled run by that ID, never by
# name) and, after place-and-route, prints the verdict of tools/gowin_verdict.py: the failing end points over all clock pairs,
# setup and hold. Do not edit this file while a run is going, because bash reads a script as it runs it.
#
# Needs Gowin EDA V1.9.12.04 (Standard, a licensed install) with its AE350 IP sources, GowinModGen.exe and
# serdes_toml_to_csr_138k.exe, Windows with powershell.exe (for the junctions into rtl/ and hw/) and Git Bash (cygpath, /proc),
# python, and git for the build identifier. The timing estimate after synthesis comes from the author's sister repository
# tangcommon; when that script is not there the estimate is skipped, because python fails and `|| true` ignores it. The build
# does not touch the board: tools/ladder_fw.sh write-chip writes the bitstream to the flash, and run.bat loads the SRAM through
# tools/radio_start.py, which needs a board loader tool (board.py with its board.json) that is not part of this repository.
set -euo pipefail

# The IDE folder of the Gowin EDA install (the one that holds bin/gw_sh.exe): the default is the author's, so set GOWIN_IDE to yours.
GOWIN_IDE="${GOWIN_IDE:-/c/Gowin/Gowin_V1.9.12.04_x64/IDE}"
GOWIN_SH="$GOWIN_IDE/bin/gw_sh.exe"
MODGEN="$GOWIN_IDE/bin/GowinModGen.exe"
AE350_DATA="$GOWIN_IDE/ipcore/RiscV_AE350_SOC/data"
DEVICE_PN="GW5AST-LV138FPG676AC1/I0"
DEVICE_NAME="GW5AST-138C"
DEVICE_VERSION="B"
TOP="sdr_top"

repo="$(pwd -W 2>/dev/null || pwd)"
if [ ! -f "$repo/gowin/p1/build.sh" ]; then
    echo "error: run from the repository root" >&2
    exit 1
fi
mode="all"
[ "${1:-}" = "--syn" ] && mode="syn"
# ---- DDR3 begin
ddr="${TR_DDR:-1024}"
case "$ddr" in
    1024) ipc="riscv_ae350_soc.ipc" ;;
    256)  ipc="riscv_ae350_soc_256.ipc" ;;
    *)    echo "error: TR_DDR must be 1024 or 256" >&2; exit 1 ;;
esac
# ---- DDR3 end

out="${OUT_DIR:-$repo/gowin/impl}/${TOP}"
rm -rf "${out:?}"
mkdir -p "$out/ip"

# ---------------------------------------------------------------- IP regeneration
python "$repo/gowin/p1/ip/ipc_to_config.py" "$repo/gowin/p1/ip/$ipc" "$out/ip/riscv_ae350_config.v"
for mod in "$repo"/gowin/p1/ip/*.mod; do
    name="$(basename "$mod")"
    sed "s#@OUT@#$(cygpath -m "$out/ip")#" "$mod" > "$out/ip/$name"
    ( cd "$out/ip" && "$MODGEN" -do "$name" ) > "$out/ip/${name%.mod}.log" 2>&1 || {
        echo "GowinModGen failed for $name, see $out/ip/${name%.mod}.log" >&2; exit 1; }
done

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
    sys.exit("gowin/p1/build.sh: serdes.toml quad 1 has no 'por_toggle_by_fabric = false'")
t = t[:q1] + s.replace('por_toggle_by_fabric = false', 'por_toggle_by_fabric = true') + t[end:]
open(sys.argv[2], 'w', encoding='utf-8', newline='\n').write(t)
PYTOML
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
        sys.exit("gowin/p1/build.sh: the generated Serdes_Top lacks the global reset form: " + ", ".join(miss))
elif "por_n_i" in t:
    sys.exit("gowin/p1/build.sh: SFP_POR_FABRIC=0 but the generated Serdes_Top has por_n_i")
diag = ["q1_fabric_ln1_pma_rx_lock_o", "q1_fabric_ln0_pma_rx_lock_o", "q1_fabric_lane1_cmu_ok_o", "q1_fabric_lane0_cmu_ok_o",
        "q1_fabric_pma_cm1_dr_refclk_det_o", "q1_fabric_pma_cm0_dr_refclk_det_o", "q1_fabric_cmu1_ok_o", "q1_fabric_cmu_ok_o"]
for w in diag:
    if t.count("wire %s;" % w) != 1:
        sys.exit("gowin/p1/build.sh: the generated Serdes_Top has no wire " + w)
a = "module Serdes_Top ("
if t.count(a) != 1 or "\noutput " not in t:
    sys.exit("gowin/p1/build.sh: the generated Serdes_Top has not the expected shape; sfp_diag not added")
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

# ---------------------------------------------------------------- build identifier, defines
hash="$(git -C "$repo" rev-parse --short=8 HEAD 2>/dev/null || echo 00000000)"
cat > "$out/tr_build_id.v" <<EOF
// generated by gowin/p1/build.sh: first 8 hex digits of the commit this bitstream was built from
module tr_build_id (output wire [31:0] id);
    assign id = 32'h${hash};
endmodule
EOF
# Gowin's Tcl has no command-line define option; the first source file carries the defines and
# they stay in force for the files after it (one compilation unit).
cat > "$out/p1_defines.v" <<'EOF'
// generated by gowin/p1/build.sh
`define GW_IDE        // rtl/vendor/hdmi/serializer.sv: Gowin OSER10 serializers
`define GOWIN_PLL     // rtl/hl2link/eth_clk_pll.v: Gowin_PLL_ETH (gowin/p1/ip/gowin_pll_eth.mod)
`define GOWIN_DSP     // rtl/rx/fir_decim.v: instantiated MULTALU27X18
`define TR_FFT_INCLUDED   // rtl/ft8/ft8_frame_core.v: the FFT comes in with rtl/spectrum/spectrum_pipeline.v
EOF
# ---- DDR3 begin
[ "$ddr" = 1024 ] || echo '`define TR_DDR_256    // rtl/top/sdr_top.v: own DDR3 controller of the AE350, 256 MB' >> "$out/p1_defines.v"
[ -z "${TR_NO_ZOOM:-}" ] || echo '`define TR_NO_ZOOM     // rtl/top/sdr_core.v: build without the zoom receiver' >> "$out/p1_defines.v"
# ---- DDR3 end
# SFP: TR_SFP_TXC_OWN=1 gives lane 1 its own transmit clock (a fourth lane clock; docs/SFP_LINKS.md section 1)
[ -z "${TR_SFP_TXC_OWN:-}" ] || echo '`define TR_SFP_TXC_OWN  // rtl/top/sdr_top.v: lane 1 transmit buffer on its own clock' >> "$out/p1_defines.v"
# SFP: the transceiver's reset form (SFP_POR_FABRIC, section "SFP begin" above): without the global reset no por_n_i port
[ "$SFP_POR_FABRIC" != 0 ] || echo '`define TR_SFP_NO_POR   // rtl/sfp/sfp_serdes.v: Serdes_Top without por_n_i (the IDE default reset form)' >> "$out/p1_defines.v"
# ---- NRX begin
# receivers built, 1 to 8; unset = the default in rtl/top/sdr_core.v (4). The target chip is 4 receivers with the
# zoom; the 8-receiver chip without the zoom is TR_NRX=8 TR_NO_ZOOM=1.
if [ -n "${TR_NRX:-}" ]; then
    case "$TR_NRX" in
        [1-8]) printf '// rtl/top/sdr_core.v: receivers built (no comment on the define line: it is a value)
`define TR_NRX %s
' "$TR_NRX" >> "$out/p1_defines.v" ;;
        *)     echo "error: TR_NRX must be a number from 1 to 8" >&2; exit 1 ;;
    esac
fi
# ---- NRX end

# Junctions so the repo-root-relative `include and $readmemh paths in the RTL resolve from the
# project directory (gowin/res.sh does the same).
src="$repo"
if [ "${GOWIN_SNAPSHOT:-0}" = 1 ]; then
    cp -r "$repo/rtl" "$repo/hw" "$out/"
    src="$out"
else
powershell.exe -NoProfile -Command \
    "New-Item -ItemType Junction -Path '$(cygpath -w "$out/rtl")' -Target '$(cygpath -w "$repo/rtl")' | Out-Null; \
     New-Item -ItemType Junction -Path '$(cygpath -w "$out/hw")' -Target '$(cygpath -w "$repo/hw")' | Out-Null"
fi

# ---------------------------------------------------------------- sources
rtl=(
    rtl/hl2link/crc32_eth.v rtl/hl2link/cdc_word.v rtl/hl2link/cdc_sample_fifo.v
    rtl/hl2link/gmii_rx_in.v rtl/hl2link/eth_frame_rx.v
    rtl/hl2link/raw_frame_buffer.v rtl/hl2link/gap_filler.v rtl/hl2link/cpu_rx_ring.v
    rtl/hl2link/hl2_link_rx_top.v
    rtl/hl2link/gmii_tx_out.v rtl/hl2link/crc32_append.v
    rtl/hl2link/cpu_tx_queue.v rtl/hl2link/tx_sample_framer.v rtl/hl2link/tx_rate_lock.v
    rtl/hl2link/rx_tx_fill_bridge.v rtl/hl2link/hl2_link_tx_top.v
    rtl/hl2link/eth_clk_pll.v
    rtl/net/chip_dna.v rtl/net/eth_top.v rtl/net/net_unit.v
    rtl/rx/nco_mixer.v rtl/rx/cic_integrator.v rtl/rx/cic_comb.v rtl/rx/cic_fixed.v
    rtl/rx/cic_var_shared.v rtl/rx/fir_decim.v rtl/rx/fir_delay_ram2.v rtl/rx/rx_channel.v
    rtl/rx/rx_bank.v
    rtl/rx_backend/bk_mul.v rtl/rx_backend/bk_ram.v rtl/rx_backend/bk_rom.v rtl/rx_backend/bk_fifo.v
    rtl/rx_backend/bk_front.v rtl/rx_backend/bk_decim.v rtl/rx_backend/bk_chfilt.v
    rtl/rx_backend/bk_cordic.v rtl/rx_backend/bk_post.v rtl/rx_backend/bk_ring.v
    rtl/rx_backend/rx_backend.v
    rtl/spectrum/spectrum_pipeline.v
    rtl/zoom/cic_var_pow2.v rtl/zoom/zoom_fir_half.v rtl/zoom/zoom_cic_comp.v rtl/zoom/zoom_ddc.v
    rtl/zoom/zoom_window.v rtl/zoom/zoom_spectrum.v rtl/zoom/zoom_frontend.v
    rtl/video/waterfall_writer.v rtl/video/colorbar_gen.v
    rtl/video/compositor_util.v rtl/video/compositor_fetch.v rtl/video/compositor_pix.v rtl/video/compositor.v
    rtl/video/sdr_hdmi_video.v
    rtl/tx/tx_fir_interp4.v rtl/tx/CicInterpM5.v rtl/tx/tx_chain.v
    rtl/audio/audio_ring_reader.v rtl/audio/audio_interp_x8.v rtl/audio/audio_nco_tick.v
    rtl/audio/audio_pt8211_tx.v rtl/audio/audio_engine.v
    rtl/audio/audio_out_src.v rtl/audio/audio_spdif_tx.v rtl/audio/audio_digital_out.v
    rtl/usb/usb_fs_phy.v rtl/usb/usb_fs_core.v rtl/usb/usb_afifo.v rtl/usb/usb_ep0.v rtl/usb/usb_ep_cap.v
    rtl/usb/usb_ep_play.v rtl/usb/usb_play.v rtl/usb/usb_regs.v rtl/usb/usb_audio.v
    rtl/usbh/usbh_phy.v rtl/usbh/usbh_port.v rtl/usbh/usbh_iso_out.v rtl/usbh/usbh_iso_in.v rtl/usbh/usbh_regs.v
    rtl/usbh/usbh_top.v
    rtl/ddr3/ddr3_write_arbiter.v rtl/ddr3/ddr3_wr_relay.v rtl/ddr3/ddr3_read_arbiter.v rtl/ddr3/ddr3_rd_relay.v
    rtl/ft8/ft8_frontend.v
    rtl/n1/enc_8b10b.v rtl/n1/fcs_append.v rtl/n1/gmii_mac_tx.v rtl/n1/gmii_mac_rx.v
    rtl/sfp/sfp_rx_sym.v rtl/sfp/sfp_enc20.v rtl/sfp/sfp_xstat.v rtl/sfp/sfp_pcs.v rtl/sfp/sfp_phy.v rtl/sfp/sfp_net.v
    rtl/sfp/sfp_top.v rtl/sfp/sfp_serdes.v
    rtl/blink/blink_tx.v rtl/blink/blink_rx.v rtl/blink/blink_rx_buf.v rtl/blink/blink_top.v
    rtl/top/ahb_reg_bridge.v rtl/top/regbus_cdc_dst.v rtl/top/regbus_leg.v rtl/top/sys_regs.v rtl/top/hl2_link_regs.v
    rtl/top/hl2_pkt_port.v rtl/top/block_regs.v rtl/top/rd_word_adapter.v rtl/top/p1_stubs.v
    rtl/top/sdr_core.v rtl/top/sdr_top.v
)
sv=(
    rtl/vendor/hdmi/tmds_channel.sv rtl/vendor/hdmi/serializer.sv rtl/vendor/hdmi/packet_picker.sv
    rtl/vendor/hdmi/packet_assembler.sv rtl/vendor/hdmi/audio_clock_regeneration_packet.sv
    rtl/vendor/hdmi/audio_info_frame.sv rtl/vendor/hdmi/audio_sample_packet.sv
    rtl/vendor/hdmi/auxiliary_video_information_info_frame.sv
    rtl/vendor/hdmi/source_product_description_info_frame.sv rtl/vendor/hdmi/hdmi.sv
)
# ---- DDR3 begin
if [ "$ddr" = 1024 ]; then
    # the AE350 without its own DDR3 controller (riscv_ae350_ddr3.v and its two FIFOs are not compiled); the
    # DDR3 IP's source (the copy in the AE350's folder) is instantiated by rtl/mem/ddr_mem.v, with our settings
    rtl+=(rtl/mem/ddr_mem.v)
    ip_src=(riscv_ae350_top.v riscv_ae350_soc.v riscv_ae350_flash.v ddr3_1_4code_hs.v DDR3_TOP.v)
    ddr_inc="$src/hw/gowin/mem"
else
    ip_src=(
        riscv_ae350_top.v riscv_ae350_soc.v riscv_ae350_ddr3.v riscv_ae350_flash.v ddr3_1_4code_hs.v
        DDR3_TOP.v fifo_top_32to128.v fifo_top_128to32.v
    )
    ddr_inc="$AE350_DATA/ddr3_default_settings"
fi
# strip_1g keeps the blocks of the constraints that fit the chosen TR_DDR: with 1024 it deletes the DDR3-256-ONLY blocks, and with 256 it
# deletes the DDR3-1G-ONLY blocks (the second memory chip) and renames DDR3_ADDR[14] to DDR3_A14.
strip_1g() {
    if [ "$ddr" = 1024 ]; then sed -e '/DDR3-256-ONLY begin/,/DDR3-256-ONLY end/d'; else sed -e '/DDR3-1G-ONLY begin/,/DDR3-1G-ONLY end/d' -e 's/DDR3_ADDR\[14\]/DDR3_A14/'; fi
}
# TR_USBH_PMOD=1: the USB host board on PMOD1 = J24 instead of PMOD0 = J22 (docs/USB_HOST.md section 4):
# dock pins 9, 10, 11, 12 = E25, D25, C24, B24
# usbh_pmod passes the constraints through, or with TR_USBH_PMOD=1 moves the USB host pins to the PMOD1 connector.
usbh_pmod() {
    if [ "${TR_USBH_PMOD:-0}" = 1 ]; then
        sed -e 's/^IO_LOC "usbh_a\[0\]" L22;/IO_LOC "usbh_a[0]" E25;/' -e 's/^IO_LOC "usbh_b\[0\]" N17;/IO_LOC "usbh_b[0]" D25;/'             -e 's/^IO_LOC "usbh_a\[1\]" N18;/IO_LOC "usbh_a[1]" C24;/' -e 's/^IO_LOC "usbh_b\[1\]" M26;/IO_LOC "usbh_b[1]" B24;/'
    else cat; fi
}
strip_1g < "$repo/gowin/p1/sdr.cst" | usbh_pmod > "$out/sdr.cst"
# ---- DDR3 end

# one timing-constraint file: the chip's own plus the receiver back end's multicycle paths
strip_1g < "$repo/gowin/p1/sdr.sdc" | cat - "$repo/rtl/rx_backend/rx_backend.sdc" "$repo/rtl/ft8/ft8_spectrogram.sdc" > "$out/sdr_all.sdc"
# ---- Optional placement group for the SPI flash controller of Gowin inside the AE350 (u_gwspiflash, the place to look when it shows
# setup failures at 100 MHz): TR_FLASH_REGION="R[96:108]C[170:181]" adds the group to the build's copy of the physical constraints,
# and TR_FLASH_PORT=1 defines the flash clock at the pad instead of the net.
if [ -n "${TR_FLASH_REGION:-}" ]; then
    # TR_FLASH_PAT: instance-name patterns below u_gwspiflash/, space separated (the IP's cells are named in the
    # timing report as u_ae350/u_RiscV_AE350_SOC/u_riscv_ae350_flash_top/u_gwspiflash/u_spi_ctrl/ctrl_cs_r_3_s0)
    fp=""; for q in ${TR_FLASH_PAT:-u_spi_ctrl/*}; do fp="$fp \"u_ae350/u_RiscV_AE350_SOC/u_riscv_ae350_flash_top/u_gwspiflash/$q\""; done
    printf '
GROUP flash_ctrl = {%s};
GRP_LOC flash_ctrl %s;
' "$fp" "$TR_FLASH_REGION" >> "$out/sdr.cst"
fi
[ -z "${TR_FLASH_PORT:-}" ] || sed -i 's/\[get_nets {FLASH_SPI_CLK_in}\]/[get_ports {FLASH_SPI_CLK}]/' "$out/sdr_all.sdc"
# timing margin: the design clocks' ratios scaled by (100 + margin) / 100, in the build's copy only
mpct="${TIMING_MARGIN_PCT:-0}"
[ "$mpct" = 0 ] || python "$repo/gowin/p1/sdc_margin.py" "$out/sdr_all.sdc" "$mpct"
if [ "${GOWIN_REPORTS:-0}" = 1 ]; then
    {   echo 'report_timing -setup -max_paths 300 -max_common_paths 1 -from_clock [get_clocks {clk_dsp}] -to_clock [get_clocks {clk_dsp}]'
        # the other clocks that can fail: without these lines the timing report lists no path of theirs
        for c in clk_eth clk_pix ae350_ahb_clk sfp_txc n1_rxc bl_rxc; do
            echo "report_timing -setup -max_paths 40 -max_common_paths 1 -to_clock [get_clocks {$c}]"
        done
        echo 'report_timing -hold -max_paths 40 -max_common_paths 1'
        echo 'report_high_fanout_nets -max_nets 50'
        echo 'report_route_congestion -max_grids 50'
    } >> "$out/sdr_all.sdc"
fi

# The Tcl script for gw_sh: project, device, sources, constraints, options and the run command.
tcl="$out/run.tcl"
{
    echo "create_project -name ${TOP} -dir {$(cygpath -m "$(dirname "$out")")} -pn ${DEVICE_PN} -device_version ${DEVICE_VERSION} -force"
    echo "set_device -name ${DEVICE_NAME} ${DEVICE_PN}"
    echo "add_file -type verilog {$(cygpath -m "$out/p1_defines.v")}"
    for f in "${rtl[@]}" "${sv[@]}"; do echo "add_file -type verilog {$(cygpath -m "$src/$f")}"; done
    for f in "$out"/ip/gowin_pll_*.v; do
        case "$f" in *_tmp.v) ;; *) echo "add_file -type verilog {$(cygpath -m "$f")}" ;; esac
    done
    for f in "${ip_src[@]}"; do echo "add_file -type verilog {$(cygpath -m "$AE350_DATA/$f")}"; done
    # SFP transceiver: generated wrapper and Gowin's PHY source (docs/SFP_LINKS.md 2.4)
    echo "add_file -type verilog {$(cygpath -m "$out/serdes/serdes.v")}"
    echo "add_file -type verilog {$(cygpath -m "$SERDES_DATA/customized_phy_wrapper.v")}"
    echo "add_file -type verilog {$(cygpath -m "$SERDES_DATA/customized_phy.v")}"
    echo "add_file -type verilog {$(cygpath -m "$out/tr_build_id.v")}"
    echo "add_file -type cst {$(cygpath -m "$out/sdr.cst")}"
    echo "add_file -type sdc {$(cygpath -m "$out/sdr_all.sdc")}"
    echo "set_option -top_module ${TOP}"
    echo "set_option -include_path {$(cygpath -m "$out");$(cygpath -m "$out/ip");$(cygpath -m "$AE350_DATA");$(cygpath -m "$ddr_inc");$(cygpath -m "$src/rtl/n1")}"
    echo "set_option -verilog_std sysv2017"
    echo "set_option -looplimit 20000"
    echo "set_option -use_cpu_as_gpio 1"
    echo "set_option -use_mspi_as_gpio 1"
    echo "set_option -use_sspi_as_gpio 1"
    echo "set_option -place_option ${GOWIN_PLACE_OPT:-2}"
    echo "set_option -route_option ${GOWIN_ROUTE_OPT:-2}"
    [ -z "${GOWIN_REPLICATE:-}" ] || echo "set_option -replicate_resources ${GOWIN_REPLICATE}"
    echo "set_option -timing_driven 1"
    echo "set_option -gen_posp 1"      # post-place file impl/pnr/<top>.posp: sites of all DSP blocks and block RAMs
    # V1.9.12.04 always writes the text timing report and no longer knows the switch
    case "$GOWIN_IDE" in *1.9.11*) echo "set_option -gen_text_timing_rpt 1" ;; esac
    echo "set_csr {$(cygpath -m "$out/serdes.csr")}"       # the transceiver's register file (SUG1220 3.3.19)
    [ -z "${GOWIN_PNR_OPTS:-}" ] || echo "set_option ${GOWIN_PNR_OPTS}"
    if [ "$mode" = syn ]; then
        echo "run syn"
    else
        # synthesis, then the timing estimate (below), then place-and-route when the shell says go
        echo "run syn"
        echo "set f [open {$(cygpath -m "$out")/syn.done} w]; close \$f"
        echo "if {\"${LEVELS_ONLY:-0}\" != \"1\"} {"
        echo "  for {set i 0} {\$i < 1800 && ![file exists {$(cygpath -m "$out")/pnr.go}] && ![file exists {$(cygpath -m "$out")/pnr.stop}]} {incr i} { after 2000 }"
        echo "  if {[file exists {$(cygpath -m "$out")/pnr.go}]} { run pnr }"
        echo "}"
    fi
} > "$tcl"

if [ "${GOWIN_DRY:-0}" = 1 ]; then
    echo "gowin/p1/build.sh: dry run, project written to $out (run.tcl, sdr_all.sdc); Gowin not started"
    exit 0
fi
log="$out/gw_sh.log"
start=$(date +%s)
# gw_sh runs as a child so its Windows process ID can be written down (tools/gowin_watch.py)
( cd "$out" && exec "$GOWIN_SH" run.tcl ) > "$log" 2>&1 &
gwpid=$!
cat "/proc/$gwpid/winpid" > "$out/gw_sh.pid" 2>/dev/null || echo "$gwpid" > "$out/gw_sh.pid"
# Build deliverables are copied to ${KEEP_DIR} while the build folder still exists, also when the build fails. The default is
# `fpga-sdr-builds/<tag>` next to the repository folder, with tag = TAG or the name of the build folder's parent; KEEP_DIR=none
# turns the copy off.
save_deliverables() {
    [ "${KEEP_DIR:-}" = none ] && return 0
    local dst="${KEEP_DIR:-$repo/../fpga-sdr-builds/${TAG:-$(basename "$(dirname "$out")")}}"
    mkdir -p "$dst"
    local i="$out/impl"
    cp -f "$i"/gwsynthesis/*.vg "$i"/gwsynthesis/*_syn_rsc.xml "$i"/gwsynthesis/*.log "$dst/" 2>/dev/null || true
    cp -f "$out"/sdr.cst "$out"/sdr_all.sdc "$out"/run.tcl "$out"/gw_sh.log "$out"/timing.txt "$dst/" 2>/dev/null || true
    cp -f "$i"/pnr/*.tr "$i"/pnr/*.rpt.txt "$i"/pnr/*.log "$i"/pnr/cmd.do "$i"/pnr/*.fs "$dst/" 2>/dev/null || true
    {
        echo "commit $(git -C "$repo" rev-parse HEAD 2>/dev/null) dirty=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l)"
        echo "place=${GOWIN_PLACE_OPT:-2} route=${GOWIN_ROUTE_OPT:-2} margin=${TIMING_MARGIN_PCT:-0} nrx=${TR_NRX:-4} ddr=${ddr} extra='${GOWIN_PNR_OPTS:-}'"
        echo "date $(date -Iseconds)"
    } > "$dst/build.txt"
    echo "gowin/p1/build.sh: deliverables in $dst"
}

if [ "$mode" = all ]; then
    # Timing estimate after synthesis and before place-and-route (tools/levels/timing_est.py of the sister repository tangcommon,
    # see its docs/TIMING_LEVELS.md): it only reports, unless TIMING_GATE=1 stops the build when an end point is estimated above
    # its requirement (LEVELS_FORCE=1 overrides).
    while [ ! -f "$out/syn.done" ] && kill -0 "$gwpid" 2>/dev/null; do sleep 3; done
    if [ -f "$out/syn.done" ]; then
        model="$repo/gowin/p1/timing_model.json"; [ -f "$model" ] || model=G:/proj/tangcommon/tools/levels/timing_model.json
        python "${TIMING_PY:-G:/proj/tangcommon/tools/levels/timing_est.py}" "$out/impl/gwsynthesis/${TOP}.vg" \
            --sdc "$(cygpath -m "$out/sdr_all.sdc")" --model "${TIMING_MODEL:-$model}" --margin "${TIMING_MARGIN:-0}" \
            > "$out/timing.txt" 2> "$out/timing.err" || true
        n=$(awk '/^TIMING:/{print $2}' "$out/timing.txt"); n=${n:-0}
        sed -n '/^# worst nets/q;p;40q' "$out/timing.txt"; grep '^CLOCK:' "$out/timing.txt" || true
        if [ "$n" -gt 0 ] && [ "${TIMING_GATE:-0}" = 1 ] && [ "${LEVELS_FORCE:-0}" != 1 ]; then
            touch "$out/pnr.stop"; wait "$gwpid" || true; save_deliverables
            echo "TIMING: $n endpoints estimated above their requirement: no place-and-route (LEVELS_FORCE=1 overrides). List: $out/timing.txt" >&2; exit 1
        fi
        if [ "${LEVELS_ONLY:-0}" = 1 ]; then wait "$gwpid" || true; save_deliverables; echo "timing estimate only: $out/timing.txt"; exit 0; fi
        touch "$out/pnr.go"
    fi
fi
if ! wait "$gwpid"; then
    save_deliverables
    echo "gowin/p1/build.sh: Gowin run failed after $(( $(date +%s) - start )) s, see $log" >&2
    tail -40 "$log" >&2
    exit 1
fi
save_deliverables
echo "gowin/p1/build.sh: ${mode} done in $(( $(date +%s) - start )) s; reports in $out/impl"
if [ "$mode" = all ]; then
    python "$repo/tools/gowin_verdict.py" "$out/impl/pnr/${TOP}_tr_content.html" || true
fi
