// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Done-test of the transmit chain rtl/tx/tx_chain.v, which turns 48 kHz complex baseband samples into the
// 12-bit samples that go to the HL2's DAC at 76.8 Msps: a FIR interpolator by 4, a CIC interpolator by 400,
// an NCO mixer that moves the signal up to the carrier, then rounding and saturation to 12 bits, with an
// enable and a trip input that force the output to zero (docs/ARCHITECTURE.md section 3.6, docs/X1_TX.md, and
// docs/learn/GLOSSARY.md for the terms). The bench is self-contained: it includes its DUT and every module it
// needs, by paths relative to the repository root.
//
// Stimulus: a two-tone baseband signal (+6 and -7 FFT bins away from the carrier, 9,000 of 32,767 full scale
// each), delivered one sample per bb_req, and an NCO frequency of 14.1 MHz. The test frequencies are chosen
// so that both output tones and the carrier fall exactly on bins of a 65,536-point FFT of the 76.8 Msps
// output (see "bin-exact test frequencies" below), which avoids window functions and spectral leakage, so
// the measurement is exact and not an estimate.
//
// Two checks, both required for PASS:
//
// 1. Spectral purity: the FFT of the output must show both tones at the expected bins (the two largest
//    peaks), and every other bin from 0 to 38.4 MHz must be at least 70 dB below the weaker tone (the
//    spurious threshold in docs/DECISIONS.md). The tone levels and the worst spur are printed.
//
// 2. Safety: the output goes to exactly zero within 1 output sample of enable going low or trip going high,
//    and returns within 1 sample of enable going back high.
//
// The bench prints PASS, or FAIL lines naming the check that failed.
//
// How to run: from the repository root, `iverilog -g2012 -o tb.vvp sim/tx/tb_tx_chain.v && vvp tb.vvp`, or
// `bash tools/check.sh`, which does this for every sim/**/tb_*.v. It takes a few seconds: about 370,000
// simulated output samples (filter settling plus one 65,536-point FFT capture), plus the FFT itself
// (radix-2, computed in real arithmetic in this bench).

`timescale 1ns / 1ps

`include "rtl/tx/CicInterpM5.v"
`include "rtl/rx/nco_mixer.v"
`include "rtl/tx/tx_fir_interp4.v"
`include "rtl/tx/tx_chain.v"

module tb_tx_chain;

    // ---- rates -------------------------------------------------------------------------
    // The output sample rate, which is the sample rate of the HL2's DAC.
    real FS_OUT;
    initial FS_OUT = 76_800_000.0;

    // ---- bin-exact test frequencies -----------------------------------------------------
    // The FFT length is a power of 2 so that an integer NCO phase increment (a multiple of 2^(32 - LOGN))
    // puts the up-converted local oscillator exactly on a bin, and baseband tone offsets of a whole number
    // of bins keep the two wanted tones exactly on bins too, so no window is needed.
    localparam LOGN = 16;
    localparam NFFT = 65536;                    // bin spacing = 76.8 MHz / 65536 = 1171.875 Hz

    // NCO: local oscillator at 14.1 MHz, on a bin (12032 * 1171.875 Hz = 14.1 MHz exactly).
    localparam integer LO_BIN    = 12032;
    localparam integer NCO_FREQ  = LO_BIN * (32'd1 << (32 - LOGN));  // exact phase increment

    // baseband tones: +6 and -7 bins from the LO, well inside the +-12 kHz FIR passband
    localparam integer F1_BIN = 6;    // ->  7,031.25 Hz
    localparam integer F2_BIN = -7;   // -> -8,203.125 Hz
    localparam integer KT1 = LO_BIN + F1_BIN;   // output bin of tone 1 (14,107,031.25 Hz)
    localparam integer KT2 = LO_BIN + F2_BIN;   // output bin of tone 2 (14,091,796.875 Hz)

    localparam real A1 = 9000.0;   // baseband tone amplitudes (int16 full scale = 32767)
    localparam real A2 = 9000.0;

    localparam real PI = 3.14159265358979323846;

    // ---- DUT hookup ----------------------------------------------------------------------
    reg clock = 0;
    reg rst   = 1;
    reg enable = 0;
    reg trip   = 0;
    reg [4:0] gain_shift = 5'd0;

    wire signed [15:0] bb_i, bb_q;
    wire bb_req;
    wire signed [11:0] out_data;
    wire out_valid;

    // The clock period is arbitrary: pace is tied high, so every clock is one output sample at 76.8 Msps, which
    // is equivalent for this module because it only counts samples (see the header of rtl/tx/tx_chain.v). The
    // chip's own pacing from the HL2 link is not part of this bench.
    always #5 clock = ~clock;

    tx_chain #(
        .OUTPUT_SHIFT(15)
    ) dut (
        .clock     (clock),
        .rst       (rst),
        .pace      (1'b1),
        .bb_i      (bb_i),
        .bb_q      (bb_q),
        .bb_valid  (1'b1),
        .bb_req    (bb_req),
        .enable    (enable),
        .trip      (trip),
        .nco_freq  (NCO_FREQ),
        .gain_shift(gain_shift),
        .out_data  (out_data),
        .out_valid (out_valid)
    );

    // ---- baseband two-tone source, one sample per bb_req -------------------------------
    // The baseband runs at 48 kHz, so a new sample is taken only when the DUT's FIR asks for one (bb_req).
    // Each sample is the sum of two complex exponentials (cosine in I, sine in Q) at +6 and -7 bins of
    // FS_OUT / NFFT, which is 7,031.25 Hz and -8,203.125 Hz, well inside the FIR's +-12 kHz passband.
    // ---- baseband two-tone source, one sample per bb_req -------------------------------
    integer n;
    reg signed [15:0] bb_i_r, bb_q_r;
    assign bb_i = bb_i_r;
    assign bb_q = bb_q_r;

    function real bb_sample_i(input integer idx);
        real f1, f2;
        begin
            f1 = FS_OUT / NFFT * F1_BIN;
            f2 = FS_OUT / NFFT * F2_BIN;
            bb_sample_i = A1*$cos(2.0*PI*f1*idx/48000.0) + A2*$cos(2.0*PI*f2*idx/48000.0);
        end
    endfunction

    function real bb_sample_q(input integer idx);
        real f1, f2;
        begin
            f1 = FS_OUT / NFFT * F1_BIN;
            f2 = FS_OUT / NFFT * F2_BIN;
            bb_sample_q = A1*$sin(2.0*PI*f1*idx/48000.0) + A2*$sin(2.0*PI*f2*idx/48000.0);
        end
    endfunction

    // The first sample is loaded during reset, and the next one after each bb_req.
    always @(posedge clock) begin
        if (rst) begin
            n <= 0;
            bb_i_r <= $rtoi(bb_sample_i(0));
            bb_q_r <= $rtoi(bb_sample_q(0));
        end else if (bb_req) begin
            n <= n + 1;
            bb_i_r <= $rtoi(bb_sample_i(n + 1));
            bb_q_r <= $rtoi(bb_sample_q(n + 1));
        end
    end

    // ---- FFT capture buffer and radix-2 FFT (real arithmetic) --------------------------
    // In place radix-2 FFT of NFFT points: a bit reversal reordering first, then log2(NFFT) stages of
    // butterflies with twiddle factors computed with $cos and $sin.
    // ---- FFT capture buffer and radix-2 FFT (real arithmetic) --------------------------
    real xr [0:NFFT-1];
    real xi [0:NFFT-1];

    task automatic fft;
        integer ii, jj, kk, mm, halfm;
        real ang, wr, wi, tr, ti, tmp;
        begin
            jj = 0;
            for (ii = 0; ii < NFFT-1; ii = ii + 1) begin
                if (ii < jj) begin
                    tmp = xr[ii]; xr[ii] = xr[jj]; xr[jj] = tmp;
                    tmp = xi[ii]; xi[ii] = xi[jj]; xi[jj] = tmp;
                end
                kk = NFFT >> 1;
                while (kk <= jj) begin
                    jj = jj - kk;
                    kk = kk >> 1;
                end
                jj = jj + kk;
            end
            for (mm = 2; mm <= NFFT; mm = mm << 1) begin
                halfm = mm >> 1;
                for (kk = 0; kk < NFFT; kk = kk + mm) begin
                    for (jj = 0; jj < halfm; jj = jj + 1) begin
                        ang = -2.0*PI*jj/mm;
                        wr = $cos(ang);
                        wi = $sin(ang);
                        tr = xr[kk+jj+halfm]*wr - xi[kk+jj+halfm]*wi;
                        ti = xr[kk+jj+halfm]*wi + xi[kk+jj+halfm]*wr;
                        xr[kk+jj+halfm] = xr[kk+jj] - tr;
                        xi[kk+jj+halfm] = xi[kk+jj] - ti;
                        xr[kk+jj]       = xr[kk+jj] + tr;
                        xi[kk+jj]       = xi[kk+jj] + ti;
                    end
                end
            end
        end
    endtask

    // ---- main sequence -------------------------------------------------------------------
    integer errors;
    integer i;
    real mag [0:NFFT/2];
    real ref_level, worst_mag, tone1_mag, tone2_mag;
    integer worst_bin, pk1_bin, pk2_bin;
    real worst_dbc;

    // disable/trip response check state
    reg checked_disable_zero, checked_trip_zero, checked_reenable;

    initial begin
        errors = 0;

        // Settle: skip enough output samples for the FIR (40 taps) and the CIC (R = 400, 5 stages, whose
        // group delay is several hundred thousand output samples at this R) to flush their start-up transient
        // before the FFT capture window starts.
        enable = 1'b0;
        trip   = 1'b0;
        repeat (4) @(posedge clock);
        rst = 1'b0;
        repeat (300_000) @(posedge clock);

        // ---- check 1: spectral purity --------------------------------------------------
        // Enable, then capture NFFT output samples (one per clock) as the real part of the FFT input and take
        // the FFT; the magnitudes of bins 0 to NFFT/2 are used below.
        enable = 1'b1;
        @(posedge clock);
        for (i = 0; i < NFFT; i = i + 1) begin
            @(posedge clock);
            xr[i] = $itor($signed(out_data));
            xi[i] = 0.0;
        end

        fft;

        for (i = 0; i <= NFFT/2; i = i + 1)
            mag[i] = $sqrt(xr[i]*xr[i] + xi[i]*xi[i]);

        // Reference level is the weaker of the two tones.
        tone1_mag = mag[KT1];
        tone2_mag = mag[KT2];
        ref_level = (tone1_mag < tone2_mag) ? tone1_mag : tone2_mag;

        // find the actual two largest peaks (sanity check: must be at KT1/KT2)
        pk1_bin = 0; pk2_bin = 0;
        for (i = 1; i <= NFFT/2; i = i + 1) begin
            if (mag[i] > mag[pk1_bin]) begin
                pk2_bin = pk1_bin;
                pk1_bin = i;
            end else if (mag[i] > mag[pk2_bin] && i != pk1_bin) begin
                pk2_bin = i;
            end
        end

        if (!((pk1_bin == KT1 && pk2_bin == KT2) || (pk1_bin == KT2 && pk2_bin == KT1))) begin
            $display("FAIL: largest FFT peaks at bins %0d, %0d; expected %0d, %0d",
                      pk1_bin, pk2_bin, KT1, KT2);
            errors = errors + 1;
        end

        // Worst spur: the largest bin other than the two tones, skipping bin 0 (DC). A real sinusoid of
        // amplitude A gives a magnitude of A * NFFT / 2, which is the scale of the dBFS figures below with
        // A = 2048, the full scale of 12 bits.
        worst_mag = 0.0;
        worst_bin = -1;
        for (i = 1; i <= NFFT/2; i = i + 1) begin
            if (i != KT1 && i != KT2) begin
                if (mag[i] > worst_mag) begin
                    worst_mag = mag[i];
                    worst_bin = i;
                end
            end
        end
        worst_dbc = 20.0*$log10(worst_mag/ref_level);

        $display("Tone 1: bin %0d (%.3f Hz), level %.1f dBFS (code %.1f of 2048)",
                  KT1, KT1*FS_OUT/NFFT, 20.0*$log10(tone1_mag/(2048.0*NFFT/2.0)), tone1_mag);
        $display("Tone 2: bin %0d (%.3f Hz), level %.1f dBFS (code %.1f of 2048)",
                  KT2, KT2*FS_OUT/NFFT, 20.0*$log10(tone2_mag/(2048.0*NFFT/2.0)), tone2_mag);
        $display("Worst spur: bin %0d (%.3f Hz), %.1f dBc", worst_bin, worst_bin*FS_OUT/NFFT, worst_dbc);

        if (worst_dbc > -70.0) begin
            $display("FAIL: worst spur %.1f dBc, need <= -70 dBc", worst_dbc);
            errors = errors + 1;
        end

        // ---- check 2: disable / trip force the output to zero within 1 sample ----------
        checked_disable_zero = 1'b0;
        checked_trip_zero    = 1'b0;
        checked_reenable      = 1'b0;

        // Each step changes enable or trip and looks at out_data two clocks later (the output register adds
        // one clock to the one-sample response).
        enable = 1'b0;
        @(posedge clock); @(posedge clock);
        if (out_data !== 12'sd0) begin
            $display("FAIL: out_data = %0d, not 0, one sample after enable=0", out_data);
            errors = errors + 1;
        end else
            checked_disable_zero = 1'b1;

        enable = 1'b1;
        @(posedge clock); @(posedge clock);
        if (out_data === 12'sd0) begin
            $display("FAIL: out_data stayed 0 one sample after enable=1 (re-enable did not take)");
            errors = errors + 1;
        end else
            checked_reenable = 1'b1;

        trip = 1'b1;
        @(posedge clock); @(posedge clock);
        if (out_data !== 12'sd0) begin
            $display("FAIL: out_data = %0d, not 0, one sample after trip=1", out_data);
            errors = errors + 1;
        end else
            checked_trip_zero = 1'b1;
        trip = 1'b0;

        if (checked_disable_zero && checked_trip_zero && checked_reenable)
            $display("Safety: output zeroed within 1 sample of disable and trip; recovered on re-enable");

        if (errors == 0)
            $display("PASS");
        else
            $display("FAIL: %0d error(s)", errors);

        $finish;
    end

endmodule
