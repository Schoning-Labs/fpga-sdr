// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Test of the streaming 16,384 point FFT rtl/fft/fft_r22sdf.v in the configuration the receiver
// uses for the full-band spectrum: real input, 15 bit input words (a 12 bit ADC sample times a
// Blackman-Harris window with 3 fraction bits), docs/F1_FFT.md. An FFT (fast Fourier transform,
// see docs/learn/GLOSSARY.md) turns a block of N samples into N frequency bins. This one takes
// one sample per valid clock, has no start signal, treats every block of 16,384 valid samples as
// the next frame, and delivers its bins in bit-reversed order. The window reduces the leakage of
// a strong tone into its neighbor bins, which is what makes a spurious-free range of 85 dB
// possible with a 12 bit input.
//
// The ADC samples at 76.8 MHz, so a bin is 76.8 MHz / 16,384 = 4.6875 kHz wide, and the
// frequencies named below follow from that (bin 1515.3 is 7.103 MHz). Six frames go through back
// to back, as one continuous stream:
//   0  tone, bin 1515.3 (7.103 MHz), -1 dBFS, windowed, valid on a random 51 % of the clocks
//   1  Gaussian noise, sigma 4 ADC LSB, windowed, valid on a random 51 % of the clocks
//   2  full-scale DC (-2048 on every sample), no window: the largest possible output
//   3  full-scale tone on bin 4096 (19.2 MHz), no window, valid on every clock
//   4  tone, bin 6399.71 (29.999 MHz), -1 dBFS, windowed, valid on every clock
//   5  zeros, which only push frame 4 out of the pipeline
// Every output frame is compared with a double-precision FFT of the same integer input, computed
// in this file. The checks are the peak in the expected bin, the spurious-free dynamic range
// (SFDR, the distance in dB from the tone to the largest other bin) of the tone frames, the
// arithmetic error of the FFT outside the tone's main lobe, the FFT's own noise against the
// input noise floor, Parseval's theorem (output power equals input power times N, because
// the FFT has no scaling), and that nothing overflows at full scale.
//
// Pass criterion: the limits listed next to the localparams below. The bench prints "PASS" on
// success and "FAIL: ..." lines otherwise, together with the measured figures of every frame
// and the pipeline delay of the FFT in clocks.
//
// Self-contained. Run it from the repository root, as tools/check.sh does: iverilog -g2012 -o
// out.vvp sim/fft/tb_fft_r22sdf.v, then vvp out.vvp (add +dump to write fft_dump.txt for
// tools/fft_r22sdf.py compare).

`timescale 1ns / 1ps
`include "rtl/fft/fft_delay.v"
`include "rtl/fft/fft_bf.v"
`include "rtl/fft/fft_mul.v"
`include "rtl/fft/fft_twmul.v"
`include "rtl/fft/fft_r22sdf.v"

module tb_fft_r22sdf;

    // 2^14 points, 15 bit input (12 bit ADC sample times 8), so the full-precision output is
    // IW + LOG_N = 29 bits. FRAC is the number of fraction bits of the window, NF the frames fed
    // (the last one only flushes) and NCHK the frames compared.
    localparam integer LOG_N = 14;
    localparam integer N     = 1 << LOG_N;
    localparam integer IW    = 15;
    localparam integer OW    = IW + LOG_N;
    localparam integer FRAC  = 3;             // window output fraction bits
    localparam integer NF    = 6;             // frames fed
    localparam integer NCHK  = 5;             // frames checked
    localparam real    PI    = 3.14159265358979323846;

    // Pass limits, explained in docs/F1_FFT.md. SFDR_MIN and FFTERR_MAX apply to the tone frames,
    // NOISE_MIN to the noise frame (how far the FFT's own rounding noise must lie below the input
    // noise), PARSEVAL_DB is the allowed power mismatch, and FS_REL bounds the error of the
    // full-scale frames relative to their peak (plus 64 counts).
    localparam real SFDR_MIN    = 85.0;       // dBc, tone frames, 12-bit input
    localparam real FFTERR_MAX  = -100.0;     // dBc, FFT error outside the main lobe
    localparam real NOISE_MIN   = 30.0;       // dB, FFT noise below the input noise floor
    localparam real PARSEVAL_DB = 0.01;
    localparam real FS_REL      = 1.0e-4;     // full scale: |err| <= FS_REL * peak + 64

    // The 150 MHz DSP clock is 6.666 ns per period, 3.333 ns per half period.
    reg clk = 1'b0;
    always #3.333 clk = ~clk;                 // 150 MHz, clk_dsp
    reg rst = 1'b1;

    // DUT input, with the imaginary part tied to zero (REAL_IN = 1), and its output stream:
    // out_index counts 0 .. N - 1 within a frame and out_bin is the frequency of that word.
    reg               in_valid = 1'b0;
    reg  [IW-1:0]     in_re = 0;
    wire              out_valid, out_first;
    wire [LOG_N-1:0]  out_index, out_bin;
    wire [OW-1:0]     out_re, out_im;

`ifdef TB_THIN   // the chip's variant: short delay lines in LUT RAM and one clock less per twiddle multiplier
    fft_r22sdf #(.LOG_N(LOG_N), .IW(IW), .REAL_IN(1), .SR_LUT(1), .TW_M1_ONE(1)) dut (
`else
    fft_r22sdf #(.LOG_N(LOG_N), .IW(IW), .REAL_IN(1)) dut (
`endif
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_re(in_re), .in_im({IW{1'b0}}),
        .out_valid(out_valid), .out_first(out_first), .out_index(out_index), .out_bin(out_bin),
        .out_re(out_re), .out_im(out_im)
    );

    // ---------------- stimulus ----------------
    // xin holds all six frames as integers of 15 bits, win the window, and wsum2 the sum of its
    // squares, which the noise check uses to predict the mean bin power.
    integer xin  [0:NF*N-1];
    real    win  [0:N-1];
    real    wsum2;
    integer seed_n = 7, seed_v = 11;
    integer i, f, k;

    // Rounds a real number to the nearest integer.
    function integer rnd(input real x);
        rnd = $rtoi($floor(x + 0.5));
    endfunction

    // Clips to the range of a 12 bit ADC.
    function integer clip12(input integer a);
        clip12 = (a > 2047) ? 2047 : (a < -2048) ? -2048 : a;
    endfunction

    // Fills frame fr with a tone of the given bin number (fractional bins put it between two bins),
    // level in dBFS relative to the ADC's full scale 2,047 and phase, as an ADC would convert it
    // (rounded to an integer), then windowed or not and scaled by 2^FRAC.
    task make_tone(input integer fr, input real bin, input real dbfs, input real ph,
                   input integer windowed);
        real amp;
        integer adc;
        begin
            amp = 2047.0 * $pow(10.0, dbfs / 20.0);
            for (i = 0; i < N; i = i + 1) begin
                adc = rnd(amp * $cos(2.0 * PI * bin * i / N + ph));
                xin[fr*N + i] = windowed ? rnd(adc * win[i] * (1 << FRAC)) : adc * (1 << FRAC);
            end
        end
    endtask

    // The window is a four term Blackman-Harris, w[n] = 0.35875 - 0.48829 cos(2 pi n / N) +
    // 0.14128 cos(4 pi n / N) - 0.01168 cos(6 pi n / N).
    initial begin
        wsum2 = 0.0;
        for (i = 0; i < N; i = i + 1) begin
            win[i] = 0.35875 - 0.48829 * $cos(2.0 * PI * i / N) + 0.14128 * $cos(4.0 * PI * i / N)
                     - 0.01168 * $cos(6.0 * PI * i / N);
            wsum2 = wsum2 + win[i] * win[i];
        end
        // The frames described in the header.
        make_tone(0, 1515.3, -1.0, 0.3, 1);
        // Noise: Gaussian with sigma 4 ADC counts, clipped to 12 bits.
        for (i = 0; i < N; i = i + 1)
            xin[1*N + i] = rnd(clip12($dist_normal(seed_n, 0, 4)) * win[i] * (1 << FRAC));
        for (i = 0; i < N; i = i + 1) xin[2*N + i] = -2048 * (1 << FRAC);
        // Frame 3 is a 15 bit full-scale cosine in bin 4096 without a window.
        for (i = 0; i < N; i = i + 1) xin[3*N + i] = rnd(16383.0 * $cos(2.0 * PI * 4096.0 * i / N + 0.7));
        make_tone(4, 6399.71, -1.0, 1.1, 1);
        for (i = 0; i < N; i = i + 1) xin[5*N + i] = 0;
    end

    // Driver: frames 0 to 2 are fed on a random 51 % of the clocks, frames 3 to 5 on every clock.
    // On a clock without a valid sample the data input is unknown (x), which the DUT must not use.
    // in_done_cycle is the clock after the last sample of frame 0 went in.
    integer fin = 0, nin = 0;
    integer in_done_cycle = 0;
    integer cyc = 0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (rst || fin >= NF) begin
            in_valid <= 1'b0;
        end else if (fin >= 3 || ($unsigned($random(seed_v)) % 100) < 51) begin
            in_valid <= 1'b1;
            in_re    <= xin[fin*N + nin];
            if (fin == 0 && nin == N - 1) in_done_cycle <= cyc + 1;
            if (nin == N - 1) begin nin <= 0; fin <= fin + 1; end
            else nin <= nin + 1;
        end else begin
            in_valid <= 1'b0;
            in_re    <= {IW{1'bx}};                // not valid: must not be used
        end
    end

    // ---------------- capture ----------------
    // Stores the output words of each checked frame by bin, counts them, remembers the clock of
    // the first output, and raises order_err if the output index is not counting 0 .. N - 1.
    real    ore [0:NCHK*N-1];
    real    oim [0:NCHK*N-1];
    integer fout = -1, nout = 0, first_out_cycle = 0;
    reg     order_err = 1'b0;
    always @(posedge clk) begin
        if (out_valid && fout < NCHK) begin
            if (out_first) begin
                fout = fout + 1;
                if (fout == 0) first_out_cycle = cyc;
            end
            if (fout < 0 || out_index != nout % N) order_err = 1'b1;
            if (fout >= 0 && fout < NCHK) begin
                ore[fout*N + out_bin] = $itor($signed(out_re));
                oim[fout*N + out_bin] = $itor($signed(out_im));
            end
            nout = nout + 1;
        end
    end

    // ---------------- reference FFT (double precision) ----------------
    // ct and st hold cos and -sin of 2 pi i / N, the twiddle factors of a radix-2 transform.
    real rr [0:N-1];
    real ri [0:N-1];
    real ct [0:N/2-1];
    real st [0:N/2-1];

    // Reverses the order of the LOG_N bits of a (the radix-2 transform starts from bit-reversed input).
    function integer brev(input integer a);
        integer b2;
        begin
            brev = 0;
            for (b2 = 0; b2 < LOG_N; b2 = b2 + 1) brev = brev | (((a >> b2) & 1) << (LOG_N - 1 - b2));
        end
    endfunction

    // Reference transform of frame fr: the textbook iterative radix-2 FFT in double precision,
    // from bit-reversed input, with results left in rr and ri.
    task ref_fft(input integer fr);
        integer a, b, len, half, st_, j2;
        real tr, ti, ur, ui;
        begin
            for (a = 0; a < N; a = a + 1) begin
                rr[brev(a)] = xin[fr*N + a];
                ri[brev(a)] = 0.0;
            end
            for (len = 2; len <= N; len = len * 2) begin
                half = len / 2;
                st_  = N / len;
                for (a = 0; a < N; a = a + len) begin
                    for (j2 = 0; j2 < half; j2 = j2 + 1) begin
                        b  = a + j2 + half;
                        tr = rr[b] * ct[j2*st_] - ri[b] * st[j2*st_];
                        ti = rr[b] * st[j2*st_] + ri[b] * ct[j2*st_];
                        ur = rr[a + j2];
                        ui = ri[a + j2];
                        rr[a + j2] = ur + tr;  ri[a + j2] = ui + ti;
                        rr[b]      = ur - tr;  ri[b]      = ui - ti;
                    end
                end
            end
        end
    endtask

    // Power ratio to dB.
    function real db10(input real p);
        db10 = 10.0 * $log10((p > 1.0e-300) ? p : 1.0e-300);
    endfunction

    // ---------------- checks ----------------
    integer errors = 0;
    real pk, spur, ferr, pw, e2, pref_pk, sig, fe, pin, pout, peak_abs, emax;
    integer kpk;
    integer dump_fd;

    // Tone frame: the strongest bin must be the expected one. SFDR is the tone's power over the
    // largest other bin outside +-5 bins of the peak, FFT error is the largest difference between
    // the RTL and the reference outside the same range, relative to the tone.
    task check_tone(input integer fr, input integer exp_bin, input [8*40-1:0] name);
        begin
            ref_fft(fr);
            pk = -1.0; kpk = -1;
            for (k = 0; k < N/2; k = k + 1) begin
                pw = ore[fr*N+k]*ore[fr*N+k] + oim[fr*N+k]*oim[fr*N+k];
                if (pw > pk) begin pk = pw; kpk = k; end
            end
            spur = 0.0; ferr = 0.0;
            for (k = 0; k < N/2; k = k + 1) begin
                if (k < kpk - 5 || k > kpk + 5) begin
                    pw = ore[fr*N+k]*ore[fr*N+k] + oim[fr*N+k]*oim[fr*N+k];
                    e2 = (ore[fr*N+k]-rr[k])*(ore[fr*N+k]-rr[k]) + (oim[fr*N+k]-ri[k])*(oim[fr*N+k]-ri[k]);
                    if (pw > spur) spur = pw;
                    if (e2 > ferr) ferr = e2;
                end
            end
            pref_pk = rr[kpk]*rr[kpk] + ri[kpk]*ri[kpk];
            $display("  %0s: peak bin %0d (expected %0d), level %.2f dBFS, SFDR %.1f dBc, FFT error outside main lobe %.1f dBc, gain vs float %.5f dB",
                     name, kpk, exp_bin,
                     db10(pk) - db10(2047.0 * (1 << FRAC) * (N / 2.0) * 0.35875 * 2047.0 * (1 << FRAC) * (N / 2.0) * 0.35875),
                     db10(pk) - db10(spur), db10(ferr) - db10(pk), db10(pk) - db10(pref_pk));
            if (kpk != exp_bin) begin $display("FAIL: %0s peak in bin %0d, expected %0d", name, kpk, exp_bin); errors = errors + 1; end
            if (db10(pk) - db10(spur) < SFDR_MIN) begin $display("FAIL: %0s SFDR below %.0f dBc", name, SFDR_MIN); errors = errors + 1; end
            if (db10(ferr) - db10(pk) > FFTERR_MAX) begin $display("FAIL: %0s FFT error above %.0f dBc", name, FFTERR_MAX); errors = errors + 1; end
        end
    endtask

    // Noise frame: the error power summed over all bins against the signal power gives how far
    // the FFT's rounding noise lies below the noise of the input, and the output power against
    // N times the input power is Parseval's theorem. The mean bin power is also printed next to
    // the theoretical value sigma^2 x sum of w^2 x 2^(2 FRAC) for comparison.
    task check_noise(input integer fr);
        begin
            ref_fft(fr);
            sig = 0.0; fe = 0.0; pout = 0.0; pin = 0.0;
            for (k = 0; k < N; k = k + 1) begin
                sig  = sig  + rr[k]*rr[k] + ri[k]*ri[k];
                pout = pout + ore[fr*N+k]*ore[fr*N+k] + oim[fr*N+k]*oim[fr*N+k];
                fe   = fe   + (ore[fr*N+k]-rr[k])*(ore[fr*N+k]-rr[k]) + (oim[fr*N+k]-ri[k])*(oim[fr*N+k]-ri[k]);
            end
            for (k = 0; k < N; k = k + 1) pin = pin + 1.0 * xin[fr*N+k] * xin[fr*N+k];
            $display("  noise: mean bin power %.2f dB (theory for sigma 4 LSB: %.2f dB), FFT noise %.1f dB below the input noise floor, Parseval error %.4f dB",
                     db10(pout / N), db10(16.0 * wsum2 * (1 << (2*FRAC))), db10(sig) - db10(fe), db10(pout) - db10(pin * N));
            if (db10(sig) - db10(fe) < NOISE_MIN) begin $display("FAIL: FFT noise less than %.0f dB below input noise", NOISE_MIN); errors = errors + 1; end
            if (db10(pout) - db10(pin * N) > PARSEVAL_DB || db10(pout) - db10(pin * N) < -PARSEVAL_DB) begin
                $display("FAIL: Parseval"); errors = errors + 1;
            end
        end
    endtask

    // Full-scale frame: the largest output (|re| + |im|) must be in the expected bin, below the
    // limit of the output word, and the error against the reference must stay small.
    task check_fullscale(input integer fr, input integer exp_bin, input [8*40-1:0] name);
        begin
            ref_fft(fr);
            peak_abs = 0.0; emax = 0.0; kpk = -1;
            for (k = 0; k < N; k = k + 1) begin
                pw = (rr[k] < 0.0 ? -rr[k] : rr[k]) + (ri[k] < 0.0 ? -ri[k] : ri[k]);
                if (pw > peak_abs) begin peak_abs = pw; kpk = k; end
                e2 = ore[fr*N+k] - rr[k]; if (e2 < 0.0) e2 = -e2; if (e2 > emax) emax = e2;
                e2 = oim[fr*N+k] - ri[k]; if (e2 < 0.0) e2 = -e2; if (e2 > emax) emax = e2;
            end
            $display("  %0s: largest output %.0f (limit %0d), bin %0d, max |error| %.0f = %.2e of peak",
                     name, peak_abs, 1 << (OW - 1), kpk, emax, emax / peak_abs);
            if (kpk != exp_bin) begin $display("FAIL: %0s peak bin", name); errors = errors + 1; end
            if (emax > FS_REL * peak_abs + 64.0) begin $display("FAIL: %0s overflow or error", name); errors = errors + 1; end
        end
    endtask

        // Twiddle tables for the reference, then release reset and wait for all checked frames.
    initial begin
        for (i = 0; i < N/2; i = i + 1) begin
            ct[i] = $cos(2.0 * PI * i / N);
            st[i] = -$sin(2.0 * PI * i / N);
        end
        repeat (5) @(posedge clk);
        rst = 1'b0;
        wait (fout == NCHK - 1 && nout == NCHK * N);
        @(posedge clk);
        // Prints the pipeline delay, the number of clocks from the last input sample of frame 0 to
        // the first output word.
        $display("tb_fft_r22sdf: %0d-point FFT, IW %0d, OW %0d, pipeline delay after the last input sample of a frame: %0d cycles",
                 N, IW, OW, first_out_cycle - in_done_cycle);
        if (order_err) begin $display("FAIL: output order or framing"); errors = errors + 1; end
        if ($test$plusargs("dump")) begin
            // input and output of every checked frame, for tools/fft_r22sdf.py compare
            dump_fd = $fopen("fft_dump.txt", "w");
            for (f = 0; f < NCHK; f = f + 1)
                for (k = 0; k < N; k = k + 1)
                    $fdisplay(dump_fd, "%0d %0d %.0f %.0f", f, xin[f*N+k], ore[f*N+k], oim[f*N+k]);
            $fclose(dump_fd);
            $display("  wrote fft_dump.txt");
        end
        // Run the frame checks. The bin numbers are those of the tones, rounded.
        check_tone(0, 1515, "tone 7.103 MHz, bursty");
        check_noise(1);
        check_fullscale(2, 0, "full-scale DC");
        check_fullscale(3, 4096, "full-scale 19.2 MHz");
        check_tone(4, 6400, "tone 29.999 MHz, continuous");
        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    // Watchdog: 20 ms of simulated time.
    initial begin
        #20_000_000;
        $display("FAIL: timeout (fout %0d, nout %0d)", fout, nout);
        $finish;
    end

endmodule
