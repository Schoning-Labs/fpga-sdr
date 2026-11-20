// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`
// from hw/regmap/ft8.toml. See docs/REGMAP.md.
//
// FT8/FT4 decoder front end (docs/ARCHITECTURE.md 3.12): slot capture and spectrogram (F5), Costas
// sync search (F6), candidate engine (F7). All DDR3 addresses are lane-word addresses (8 bytes each).
// status: draft

`ifndef SDR_REGMAP_FT8_VH
`define SDR_REGMAP_FT8_VH

`define FT8_BASE 32'hE80D0000
`define FT8_SIZE 32'h00010000

// id -- Block identifier: F8 + version 2 (version 1 had no second pass: no p2_* registers).
`define FT8_ID_ADDR 32'h00000000
`define FT8_ID_ABS_ADDR (`FT8_BASE + `FT8_ID_ADDR)
`define FT8_ID_RESET 32'h46380002

// irq_status -- Events; interrupt line 11 = OR of irq_status & irq_enable. Write 1 to clear.
`define FT8_IRQ_STATUS_ADDR 32'h00000004
`define FT8_IRQ_STATUS_ABS_ADDR (`FT8_BASE + `FT8_IRQ_STATUS_ADDR)
`define FT8_IRQ_STATUS_RESET 32'h00000000
`define FT8_IRQ_STATUS_SYNC_DONE_LSB 0
`define FT8_IRQ_STATUS_SYNC_DONE_MSB 7
`define FT8_IRQ_STATUS_SYNC_DONE_WIDTH 8
`define FT8_IRQ_STATUS_CAND_DONE_LSB 8
`define FT8_IRQ_STATUS_CAND_DONE_MSB 8
`define FT8_IRQ_STATUS_CAND_DONE_WIDTH 1
`define FT8_IRQ_STATUS_FRAME_LSB 9
`define FT8_IRQ_STATUS_FRAME_MSB 9
`define FT8_IRQ_STATUS_FRAME_WIDTH 1
`define FT8_IRQ_STATUS_P2_DONE_LSB 10
`define FT8_IRQ_STATUS_P2_DONE_MSB 10
`define FT8_IRQ_STATUS_P2_DONE_WIDTH 1

// irq_enable -- Which irq_status bits drive interrupt line 11.
`define FT8_IRQ_ENABLE_ADDR 32'h00000008
`define FT8_IRQ_ENABLE_ABS_ADDR (`FT8_BASE + `FT8_IRQ_ENABLE_ADDR)
`define FT8_IRQ_ENABLE_RESET 32'h00000000
`define FT8_IRQ_ENABLE_SYNC_DONE_LSB 0
`define FT8_IRQ_ENABLE_SYNC_DONE_MSB 7
`define FT8_IRQ_ENABLE_SYNC_DONE_WIDTH 8
`define FT8_IRQ_ENABLE_CAND_DONE_LSB 8
`define FT8_IRQ_ENABLE_CAND_DONE_MSB 8
`define FT8_IRQ_ENABLE_CAND_DONE_WIDTH 1
`define FT8_IRQ_ENABLE_FRAME_LSB 9
`define FT8_IRQ_ENABLE_FRAME_MSB 9
`define FT8_IRQ_ENABLE_FRAME_WIDTH 1
`define FT8_IRQ_ENABLE_P2_DONE_LSB 10
`define FT8_IRQ_ENABLE_P2_DONE_MSB 10
`define FT8_IRQ_ENABLE_P2_DONE_WIDTH 1

// status -- Engine state.
`define FT8_STATUS_ADDR 32'h0000000C
`define FT8_STATUS_ABS_ADDR (`FT8_BASE + `FT8_STATUS_ADDR)
`define FT8_STATUS_RESET 32'h00000000
`define FT8_STATUS_SPEC_BUSY_LSB 0
`define FT8_STATUS_SPEC_BUSY_MSB 0
`define FT8_STATUS_SPEC_BUSY_WIDTH 1
`define FT8_STATUS_SYNC_BUSY_LSB 1
`define FT8_STATUS_SYNC_BUSY_MSB 1
`define FT8_STATUS_SYNC_BUSY_WIDTH 1
`define FT8_STATUS_CAND_BUSY_LSB 2
`define FT8_STATUS_CAND_BUSY_MSB 2
`define FT8_STATUS_CAND_BUSY_WIDTH 1
`define FT8_STATUS_CAP_OVERFLOW_LSB 3
`define FT8_STATUS_CAP_OVERFLOW_MSB 3
`define FT8_STATUS_CAP_OVERFLOW_WIDTH 1
`define FT8_STATUS_P2_BUSY_LSB 4
`define FT8_STATUS_P2_BUSY_MSB 4
`define FT8_STATUS_P2_BUSY_WIDTH 1

// frame_last -- The spectrogram frame written last.
`define FT8_FRAME_LAST_ADDR 32'h00000010
`define FT8_FRAME_LAST_ABS_ADDR (`FT8_BASE + `FT8_FRAME_LAST_ADDR)
`define FT8_FRAME_LAST_RESET 32'h00000000
`define FT8_FRAME_LAST_RX_LSB 0
`define FT8_FRAME_LAST_RX_MSB 2
`define FT8_FRAME_LAST_RX_WIDTH 3
`define FT8_FRAME_LAST_FRAME_LSB 8
`define FT8_FRAME_LAST_FRAME_MSB 16
`define FT8_FRAME_LAST_FRAME_WIDTH 9

// sync_cmd -- Writing queues a sync search for one receiver (for a second pass over a residual spectrogram; the searches at the triggers and at the slot end start by themselves).
`define FT8_SYNC_CMD_ADDR 32'h00000014
`define FT8_SYNC_CMD_ABS_ADDR (`FT8_BASE + `FT8_SYNC_CMD_ADDR)
`define FT8_SYNC_CMD_RESET 32'h00000000
`define FT8_SYNC_CMD_RX_LSB 0
`define FT8_SYNC_CMD_RX_MSB 2
`define FT8_SYNC_CMD_RX_WIDTH 3
`define FT8_SYNC_CMD_ROWS_LSB 8
`define FT8_SYNC_CMD_ROWS_MSB 16
`define FT8_SYNC_CMD_ROWS_WIDTH 9

// sync_clocks -- Length of the last sync search in 120 MHz clocks.
`define FT8_SYNC_CLOCKS_ADDR 32'h00000018
`define FT8_SYNC_CLOCKS_ABS_ADDR (`FT8_BASE + `FT8_SYNC_CLOCKS_ADDR)
`define FT8_SYNC_CLOCKS_RESET 32'h00000000

// p2_frame -- Second pass: frames of the residual's spectrogram written so far.
`define FT8_P2_FRAME_ADDR 32'h0000001C
`define FT8_P2_FRAME_ABS_ADDR (`FT8_BASE + `FT8_P2_FRAME_ADDR)
`define FT8_P2_FRAME_RESET 32'h00000000
`define FT8_P2_FRAME_VALUE_LSB 0
`define FT8_P2_FRAME_VALUE_MSB 8
`define FT8_P2_FRAME_VALUE_WIDTH 9

// cand_cmd -- Writing starts a candidate command on the two lanes (only while status.cand_busy = 0).
`define FT8_CAND_CMD_ADDR 32'h00000020
`define FT8_CAND_CMD_ABS_ADDR (`FT8_BASE + `FT8_CAND_CMD_ADDR)
`define FT8_CAND_CMD_RESET 32'h00000000
`define FT8_CAND_CMD_PASS2_LSB 0
`define FT8_CAND_CMD_PASS2_MSB 0
`define FT8_CAND_CMD_PASS2_WIDTH 1
`define FT8_CAND_CMD_LANES_LSB 1
`define FT8_CAND_CMD_LANES_MSB 2
`define FT8_CAND_CMD_LANES_WIDTH 2

// cand_cap_base -- Pass 1: base of the audio ring to replay (a receiver's cap_base, or a ring of residual audio the CPU wrote: 4 samples of 16 bits per lane word, 2^19 samples).
`define FT8_CAND_CAP_BASE_ADDR 32'h00000024
`define FT8_CAND_CAP_BASE_ABS_ADDR (`FT8_BASE + `FT8_CAND_CAP_BASE_ADDR)
`define FT8_CAND_CAP_BASE_RESET 32'h00000000

// cand_first_sample -- Pass 1: ring sample index of the slot's first sample (the receiver's slot_boundary).
`define FT8_CAND_FIRST_SAMPLE_ADDR 32'h00000028
`define FT8_CAND_FIRST_SAMPLE_ABS_ADDR (`FT8_BASE + `FT8_CAND_FIRST_SAMPLE_ADDR)
`define FT8_CAND_FIRST_SAMPLE_RESET 32'h00000000

// cand_clocks -- Length of the last candidate command in 120 MHz clocks.
`define FT8_CAND_CLOCKS_ADDR 32'h0000002C
`define FT8_CAND_CLOCKS_ABS_ADDR (`FT8_BASE + `FT8_CAND_CLOCKS_ADDR)
`define FT8_CAND_CLOCKS_RESET 32'h00000000

// p2_cmd -- Second pass (docs/FT8_PASS2.md). Writing starts it: the spectrogram engine transforms the slot of residual audio in the area at p2_base into the area's spectrogram part (372 frames, between the live frames), then the sync engine searches that spectrogram and writes its records to the area's record part; irq_status.p2_done when they are in DDR3. Write p2_base first. Ignored while status.p2_busy.
`define FT8_P2_CMD_ADDR 32'h00000030
`define FT8_P2_CMD_ABS_ADDR (`FT8_BASE + `FT8_P2_CMD_ADDR)
`define FT8_P2_CMD_RESET 32'h00000000
`define FT8_P2_CMD_RX_LSB 0
`define FT8_P2_CMD_RX_MSB 2
`define FT8_P2_CMD_RX_WIDTH 3

// p2_base -- Second pass: the 4 MB area of DDR3 it works in, a lane-word address that is a multiple of 2^19 (the low 19 bits are not stored and read 0). In lane words from the base: 0 the residual audio the CPU wrote (180,000 samples from slot sample 0, 4 samples of 16 bits per lane word, 45,000 lane words; also cand_cap_base, with cand_first_sample = 0, for the second pass's candidates); 0x1_0000 the residual's spectrogram (372 frames x 512 lane words); 0x4_0000 its sync records (4 lane words per carrier bin from band.ia of p2_cmd.rx).
`define FT8_P2_BASE_ADDR 32'h00000034
`define FT8_P2_BASE_ABS_ADDR (`FT8_BASE + `FT8_P2_BASE_ADDR)
`define FT8_P2_BASE_RESET 32'h00000000
`define FT8_P2_BASE_VALUE_LSB 0
`define FT8_P2_BASE_VALUE_MSB 26
`define FT8_P2_BASE_VALUE_WIDTH 27

// cand_inc -- Per lane. Pass 1: NCO increment round((f0 + 21.875 Hz) x 2^32 / 12,000). Pass 2: rotation increment round((21.875 Hz - delf) x 2^32 / 200).
`define FT8_CAND_INC_OFFSET 32'h00000040
`define FT8_CAND_INC_STRIDE 32'h00000010
`define FT8_CAND_INC_COUNT 2
`define FT8_CAND_INC_ADDR(i) (`FT8_CAND_INC_OFFSET + (i)*`FT8_CAND_INC_STRIDE)
`define FT8_CAND_INC_ABS_ADDR(i) (`FT8_BASE + `FT8_CAND_INC_ADDR(i))
`define FT8_CAND_INC_RESET 32'h00000000

// cand_i0 -- Per lane, pass 2: start sample in the baseband.
`define FT8_CAND_I0_OFFSET 32'h00000044
`define FT8_CAND_I0_STRIDE 32'h00000010
`define FT8_CAND_I0_COUNT 2
`define FT8_CAND_I0_ADDR(i) (`FT8_CAND_I0_OFFSET + (i)*`FT8_CAND_I0_STRIDE)
`define FT8_CAND_I0_ABS_ADDR(i) (`FT8_BASE + `FT8_CAND_I0_ADDR(i))
`define FT8_CAND_I0_RESET 32'h00000000
`define FT8_CAND_I0_VALUE_LSB 0
`define FT8_CAND_I0_VALUE_MSB 15
`define FT8_CAND_I0_VALUE_WIDTH 16

// cand_bb_base -- Per lane: the candidate's baseband, 3,200 lane words {im, re} (pass 1 writes it, pass 2 reads it).
`define FT8_CAND_BB_BASE_OFFSET 32'h00000048
`define FT8_CAND_BB_BASE_STRIDE 32'h00000010
`define FT8_CAND_BB_BASE_COUNT 2
`define FT8_CAND_BB_BASE_ADDR(i) (`FT8_CAND_BB_BASE_OFFSET + (i)*`FT8_CAND_BB_BASE_STRIDE)
`define FT8_CAND_BB_BASE_ABS_ADDR(i) (`FT8_BASE + `FT8_CAND_BB_BASE_ADDR(i))
`define FT8_CAND_BB_BASE_RESET 32'h00000000

// cand_sym_base -- Per lane, pass 2: where the 632 soft-symbol lane words {im, re} go (79 symbols x 8 tones).
`define FT8_CAND_SYM_BASE_OFFSET 32'h0000004C
`define FT8_CAND_SYM_BASE_STRIDE 32'h00000010
`define FT8_CAND_SYM_BASE_COUNT 2
`define FT8_CAND_SYM_BASE_ADDR(i) (`FT8_CAND_SYM_BASE_OFFSET + (i)*`FT8_CAND_SYM_BASE_STRIDE)
`define FT8_CAND_SYM_BASE_ABS_ADDR(i) (`FT8_BASE + `FT8_CAND_SYM_BASE_ADDR(i))
`define FT8_CAND_SYM_BASE_RESET 32'h00000000

// ctrl -- Per receiver: capture and spectrogram on, power shift.
`define FT8_CTRL_OFFSET 32'h00000200
`define FT8_CTRL_STRIDE 32'h00000040
`define FT8_CTRL_COUNT 8
`define FT8_CTRL_ADDR(i) (`FT8_CTRL_OFFSET + (i)*`FT8_CTRL_STRIDE)
`define FT8_CTRL_ABS_ADDR(i) (`FT8_BASE + `FT8_CTRL_ADDR(i))
`define FT8_CTRL_RESET 32'h00001000
`define FT8_CTRL_ENABLE_LSB 0
`define FT8_CTRL_ENABLE_MSB 0
`define FT8_CTRL_ENABLE_WIDTH 1
`define FT8_CTRL_PWR_SHIFT_LSB 8
`define FT8_CTRL_PWR_SHIFT_MSB 12
`define FT8_CTRL_PWR_SHIFT_WIDTH 5

// cap_base -- Per receiver: base of the audio capture ring (2^17 lane words = 1 MB, 4 samples per word).
`define FT8_CAP_BASE_OFFSET 32'h00000204
`define FT8_CAP_BASE_STRIDE 32'h00000040
`define FT8_CAP_BASE_COUNT 8
`define FT8_CAP_BASE_ADDR(i) (`FT8_CAP_BASE_OFFSET + (i)*`FT8_CAP_BASE_STRIDE)
`define FT8_CAP_BASE_ABS_ADDR(i) (`FT8_BASE + `FT8_CAP_BASE_ADDR(i))
`define FT8_CAP_BASE_RESET 32'h00000000

// spec_base -- Per receiver: base of the spectrogram (372 frames x 512 lane words = 1.5 MB, two 32-bit power words per lane word).
`define FT8_SPEC_BASE_OFFSET 32'h00000208
`define FT8_SPEC_BASE_STRIDE 32'h00000040
`define FT8_SPEC_BASE_COUNT 8
`define FT8_SPEC_BASE_ADDR(i) (`FT8_SPEC_BASE_OFFSET + (i)*`FT8_SPEC_BASE_STRIDE)
`define FT8_SPEC_BASE_ABS_ADDR(i) (`FT8_BASE + `FT8_SPEC_BASE_ADDR(i))
`define FT8_SPEC_BASE_RESET 32'h00000000

// slot_boundary -- Per receiver: capture sample count (cap_wr_ptr units) of the slot's first sample. Writing it starts a new slot: frame counter to 0, sync triggers re-armed.
`define FT8_SLOT_BOUNDARY_OFFSET 32'h0000020C
`define FT8_SLOT_BOUNDARY_STRIDE 32'h00000040
`define FT8_SLOT_BOUNDARY_COUNT 8
`define FT8_SLOT_BOUNDARY_ADDR(i) (`FT8_SLOT_BOUNDARY_OFFSET + (i)*`FT8_SLOT_BOUNDARY_STRIDE)
`define FT8_SLOT_BOUNDARY_ABS_ADDR(i) (`FT8_BASE + `FT8_SLOT_BOUNDARY_ADDR(i))
`define FT8_SLOT_BOUNDARY_RESET 32'h00000000

// rec_base -- Per receiver: where the sync records go, 4 lane words per carrier bin from band.ia (8 x 32-bit words, docs/ARCHITECTURE.md 3.12 (c)).
`define FT8_REC_BASE_OFFSET 32'h00000210
`define FT8_REC_BASE_STRIDE 32'h00000040
`define FT8_REC_BASE_COUNT 8
`define FT8_REC_BASE_ADDR(i) (`FT8_REC_BASE_OFFSET + (i)*`FT8_REC_BASE_STRIDE)
`define FT8_REC_BASE_ABS_ADDR(i) (`FT8_BASE + `FT8_REC_BASE_ADDR(i))
`define FT8_REC_BASE_RESET 32'h00000000

// band -- Per receiver: sync search band in 3.125 Hz bins.
`define FT8_BAND_OFFSET 32'h00000214
`define FT8_BAND_STRIDE 32'h00000040
`define FT8_BAND_COUNT 8
`define FT8_BAND_ADDR(i) (`FT8_BAND_OFFSET + (i)*`FT8_BAND_STRIDE)
`define FT8_BAND_ABS_ADDR(i) (`FT8_BASE + `FT8_BAND_ADDR(i))
`define FT8_BAND_RESET 32'h03C00020
`define FT8_BAND_IA_LSB 0
`define FT8_BAND_IA_MSB 9
`define FT8_BAND_IA_WIDTH 10
`define FT8_BAND_IB_LSB 16
`define FT8_BAND_IB_MSB 25
`define FT8_BAND_IB_WIDTH 10

// trig -- Per receiver: early sync searches, started when that many frames of the slot are written (0 = off). The search over all 372 always runs.
`define FT8_TRIG_OFFSET 32'h00000218
`define FT8_TRIG_STRIDE 32'h00000040
`define FT8_TRIG_COUNT 8
`define FT8_TRIG_ADDR(i) (`FT8_TRIG_OFFSET + (i)*`FT8_TRIG_STRIDE)
`define FT8_TRIG_ABS_ADDR(i) (`FT8_BASE + `FT8_TRIG_ADDR(i))
`define FT8_TRIG_RESET 32'h00000000
`define FT8_TRIG_TRIG1_LSB 0
`define FT8_TRIG_TRIG1_MSB 8
`define FT8_TRIG_TRIG1_WIDTH 9
`define FT8_TRIG_TRIG2_LSB 16
`define FT8_TRIG_TRIG2_MSB 24
`define FT8_TRIG_TRIG2_WIDTH 9

// cap_wr_ptr -- Per receiver: audio samples captured since reset (the ring position is this mod 2^19).
`define FT8_CAP_WR_PTR_OFFSET 32'h0000021C
`define FT8_CAP_WR_PTR_STRIDE 32'h00000040
`define FT8_CAP_WR_PTR_COUNT 8
`define FT8_CAP_WR_PTR_ADDR(i) (`FT8_CAP_WR_PTR_OFFSET + (i)*`FT8_CAP_WR_PTR_STRIDE)
`define FT8_CAP_WR_PTR_ABS_ADDR(i) (`FT8_BASE + `FT8_CAP_WR_PTR_ADDR(i))
`define FT8_CAP_WR_PTR_RESET 32'h00000000

// frame_ptr -- Per receiver: spectrogram frames of the current slot written so far.
`define FT8_FRAME_PTR_OFFSET 32'h00000220
`define FT8_FRAME_PTR_STRIDE 32'h00000040
`define FT8_FRAME_PTR_COUNT 8
`define FT8_FRAME_PTR_ADDR(i) (`FT8_FRAME_PTR_OFFSET + (i)*`FT8_FRAME_PTR_STRIDE)
`define FT8_FRAME_PTR_ABS_ADDR(i) (`FT8_BASE + `FT8_FRAME_PTR_ADDR(i))
`define FT8_FRAME_PTR_RESET 32'h00000000
`define FT8_FRAME_PTR_VALUE_LSB 0
`define FT8_FRAME_PTR_VALUE_MSB 8
`define FT8_FRAME_PTR_VALUE_WIDTH 9

// sync_rows -- Per receiver: rows of the sync search that set irq_status.sync_done last.
`define FT8_SYNC_ROWS_OFFSET 32'h00000224
`define FT8_SYNC_ROWS_STRIDE 32'h00000040
`define FT8_SYNC_ROWS_COUNT 8
`define FT8_SYNC_ROWS_ADDR(i) (`FT8_SYNC_ROWS_OFFSET + (i)*`FT8_SYNC_ROWS_STRIDE)
`define FT8_SYNC_ROWS_ABS_ADDR(i) (`FT8_BASE + `FT8_SYNC_ROWS_ADDR(i))
`define FT8_SYNC_ROWS_RESET 32'h00000000
`define FT8_SYNC_ROWS_VALUE_LSB 0
`define FT8_SYNC_ROWS_VALUE_MSB 8
`define FT8_SYNC_ROWS_VALUE_WIDTH 9

`endif // SDR_REGMAP_FT8_VH
