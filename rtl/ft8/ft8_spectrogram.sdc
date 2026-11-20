// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Timing exceptions for the FT8 spectrogram engine's FFT (rtl/ft8/ft8_frame_core.v, instance
// u_ft8fft of rtl/fft/fft_r22sdf.v; Gowin SDC), to be added to the project's constraints next to
// the clk_dsp clock (gowin/res.sh --sdc, gowin/p1/build.sh). docs/F5_FT8SPEC.md section 4.
//
// ft8_frame_core.v feeds this FFT one sample every FEED_PERIOD = 8 clocks (never less than 2),
// and every stage passes its `valid` on at the same spacing. Inside one butterfly
// (rtl/fft/fft_bf.v with its delay line, fft_delay.v) every register is loaded only in a clock
// with in_valid: the counter, `phase`, `rot`, the delay line's registers and write pointer, and
// the outputs. So a path that starts at the counter, phase, rot or a delay-line register and ends
// in the same butterfly has at least FEED_PERIOD clocks. (The delay line's memory read register
// is loaded every clock, from an address that settles one clock after in_valid; its value is
// only used at the next in_valid.) Paths that start at a butterfly's out_re / out_im / out_valid
// go to the next stage, which loads them one clock later: those stay one-clock paths and are not
// named here, with one exception:
//
// out_valid -> the twiddle ROM's output register (fft_twmul.v rom_q). In the clock with in_valid
// the ROM address is the next sample's; from the clock after, it is the same address from the
// advanced registers. rom_q is read only in a clock with in_valid, so a value that settles one
// clock late is in time.
//
// The patterns name the instance u_ft8fft, which exists once in the chip; "*" matches across
// hierarchy levels. They do not match the full-band spectrum's FFT, which gets a sample per clock.
set_multicycle_path -from [get_regs {*u_ft8fft/*u_bf/cnt*}] -setup -end 2
set_multicycle_path -from [get_regs {*u_ft8fft/*u_bf/cnt*}] -hold -start 1
set_multicycle_path -from [get_regs {*u_ft8fft/*u_bf/phase*}] -setup -end 2
set_multicycle_path -from [get_regs {*u_ft8fft/*u_bf/phase*}] -hold -start 1
set_multicycle_path -from [get_regs {*u_ft8fft/*u_bf/rot*}] -setup -end 2
set_multicycle_path -from [get_regs {*u_ft8fft/*u_bf/rot*}] -hold -start 1
set_multicycle_path -from [get_regs {*u_ft8fft/*u_bf/*u_dl/*}] -setup -end 2
set_multicycle_path -from [get_regs {*u_ft8fft/*u_bf/*u_dl/*}] -hold -start 1
set_multicycle_path -from [get_regs {*u_ft8fft/*u_bf/out_valid*}] -to [get_regs {*u_ft8fft/*u_mul/rom_q*}] -setup -end 2
set_multicycle_path -from [get_regs {*u_ft8fft/*u_bf/out_valid*}] -to [get_regs {*u_ft8fft/*u_mul/rom_q*}] -hold -start 1
