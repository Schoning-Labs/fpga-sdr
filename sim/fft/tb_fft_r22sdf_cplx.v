// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Test of the streaming FFT rtl/fft/fft_r22sdf.v in the configurations that the full-band test
// tb_fft_r22sdf.v does not reach (docs/F1_FFT.md): complex input, and a size that is not an even
// power of 4. The FFT (see docs/learn/GLOSSARY.md) is built from stage pairs, each pair being two
// radix-2 butterfly stages with a twiddle multiplier between them, so an odd LOG_N ends with one
// single radix-2 stage that behaves a little differently, and that is the reason for the
// second instance. Two instances run side by side on the same reset and clock, each fed its own
// random stream:
//   * LOG_N = 12, IW = 17: the FFT of the zoom spectrum, complex input, all stage pairs;
//   * LOG_N = 11, IW = 16: an odd size, which ends with a single radix-2 stage.
// The valid signal is high on a random 60 % of the clocks. Each instance is fed four frames of
// N complex samples: two of random samples with a magnitude up to the documented limit
// 2^(IW-1) - 1 (the most that the FFT guarantees not to overflow on), one of a complex tone with
// a frequency of -37.25 bins at 90 % of that limit, and one of zeros that only pushes the
// tone frame out of the pipeline.
//
// Pass criterion: for each of the three checked frames the signal-to-error ratio between the
// RTL's output and a double-precision FFT of the same input must be at least 80 dB, which
// means the error is at rounding level and no output has overflowed (an overflow would make the
// error as large as the signal), and the tone frame must peak in bin N - 37. The bench prints
// "PASS" on success and "FAIL: ..." lines otherwise, plus the ratio of every frame.
//
// Self-contained. Run it from the repository root, as tools/check.sh does: iverilog -g2012 -o
// out.vvp sim/fft/tb_fft_r22sdf_cplx.v, then vvp out.vvp.

`timescale 1ns / 1ps
`include "rtl/fft/fft_delay.v"
`include "rtl/fft/fft_bf.v"
`include "rtl/fft/fft_mul.v"
`include "rtl/fft/fft_twmul.v"
`include "rtl/fft/fft_r22sdf.v"

// One test instance: parameters pick the FFT size, the input width and the random seed.
// It drives the stream, captures three output frames and reports its error count and a done
// flag to the top module at the end of this file.
module tb_fft_cplx_one #(
    parameter integer LOG_N = 12,
    parameter integer IW    = 17,
    parameter integer SEED  = 1
) (
    input  wire clk,
    input  wire rst,
    output reg  done,
    output integer errors
);
    // N points, OW = IW + LOG_N output bits (full precision, no scaling). NF = 4 frames fed:
    // three that are checked and one that flushes the pipeline.
    localparam integer N  = 1 << LOG_N;
    localparam integer OW = IW + LOG_N;
    localparam integer NF = 4;                // 3 checked + 1 flush
    localparam real    PI = 3.14159265358979323846;

    // xr and xi are the real and imaginary input samples of all frames.
    integer xr [0:NF*N-1];
    integer xi [0:NF*N-1];
    integer seed = SEED, seed_v = SEED + 100;
    integer i, k;
    real    amp, ph, lim;

    // Frames 0 and 1: random complex samples, with uniform magnitude from 0 to lim and a
    // uniformly distributed phase, so that some samples reach the largest allowed value.
    initial begin
        lim = (1 << (IW - 1)) - 1.0;
        for (i = 0; i < 2*N; i = i + 1) begin
            amp = lim * ($unsigned($random(seed)) % 1000001) / 1000000.0;
            ph  = 2.0 * PI * ($unsigned($random(seed)) % 1000000) / 1000000.0;
            xr[i] = $rtoi($floor(amp * $cos(ph) + 0.5));
            xi[i] = $rtoi($floor(amp * $sin(ph) + 0.5));
        end
        // Frame 2: a complex tone at 90 % of the limit.
        for (i = 0; i < N; i = i + 1) begin
            ph = -2.0 * PI * 37.25 * i / N;           // negative frequency: bin N - 37
            xr[2*N+i] = $rtoi($floor(0.9 * lim * $cos(ph) + 0.5));
            xi[2*N+i] = $rtoi($floor(0.9 * lim * $sin(ph) + 0.5));
        end
        // Frame 3: zeros.
        for (i = 3*N; i < NF*N; i = i + 1) begin xr[i] = 0; xi[i] = 0; end
    end

    // DUT input and output streams. out_index counts 0 .. N - 1 within a frame and out_bin is
    // the frequency bin of that word.
    reg              in_valid = 1'b0;
    reg  [IW-1:0]    in_re = 0, in_im = 0;
    wire             out_valid, out_first;
    wire [LOG_N-1:0] out_index, out_bin;
    wire [OW-1:0]    out_re, out_im;

    fft_r22sdf #(.LOG_N(LOG_N), .IW(IW), .REAL_IN(0)) dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_re(in_re), .in_im(in_im),
        .out_valid(out_valid), .out_first(out_first), .out_index(out_index), .out_bin(out_bin),
        .out_re(out_re), .out_im(out_im)
    );

    // Driver: a sample is presented on a random 60 % of the clocks, the data input is unknown
    // (x) on the others, which the DUT must not use.
    integer nin = 0;
    always @(posedge clk) begin
        if (rst || nin >= NF*N) begin
            in_valid <= 1'b0;
        end else if (($unsigned($random(seed_v)) % 100) < 60) begin
            in_valid <= 1'b1;
            in_re    <= xr[nin];
            in_im    <= xi[nin];
            nin      <= nin + 1;
        end else begin
            in_valid <= 1'b0;
            in_re    <= {IW{1'bx}};
            in_im    <= {IW{1'bx}};
        end
    end

    // Capture: stores the output words of the three checked frames by bin.
    real    ore [0:3*N-1];
    real    oim [0:3*N-1];
    integer fout = -1, nout = 0;
    always @(posedge clk) begin
        if (out_valid && nout < 3*N) begin
            if (out_first) fout = fout + 1;
            ore[fout*N + out_bin] = $itor($signed(out_re));
            oim[fout*N + out_bin] = $itor($signed(out_im));
            nout = nout + 1;
        end
    end

    // Reference: the textbook iterative radix-2 FFT in double precision, from bit-reversed input.
    real rr [0:N-1];
    real ri [0:N-1];
    // Reverses the order of the LOG_N bits of a.
    function integer brev(input integer a);
        integer b2;
        begin
            brev = 0;
            for (b2 = 0; b2 < LOG_N; b2 = b2 + 1) brev = brev | (((a >> b2) & 1) << (LOG_N - 1 - b2));
        end
    endfunction
    task ref_fft(input integer fr);
        integer a, b, len, half, j2;
        real tr, ti, ur, ui, c, s;
        begin
            for (a = 0; a < N; a = a + 1) begin
                rr[brev(a)] = xr[fr*N + a];
                ri[brev(a)] = xi[fr*N + a];
            end
            for (len = 2; len <= N; len = len * 2) begin
                half = len / 2;
                for (j2 = 0; j2 < half; j2 = j2 + 1) begin
                    c = $cos(2.0 * PI * j2 / len);
                    s = -$sin(2.0 * PI * j2 / len);
                    for (a = 0; a < N; a = a + len) begin
                        b  = a + j2 + half;
                        tr = rr[b] * c - ri[b] * s;
                        ti = rr[b] * s + ri[b] * c;
                        ur = rr[a + j2];
                        ui = ri[a + j2];
                        rr[a + j2] = ur + tr;  ri[a + j2] = ui + ti;
                        rr[b]      = ur - tr;  ri[b]      = ui - ti;
                    end
                end
            end
        end
    endtask

    // Compares every frame: sig is the energy of the reference, fe the energy of the error, pk
    // and kpk the strongest output bin.
    real sig, fe, pk, e2;
    integer f, kpk;
    initial begin
        errors = 0;
        done   = 1'b0;
        wait (nout == 3*N);
        for (f = 0; f < 3; f = f + 1) begin
            ref_fft(f);
            sig = 0.0; fe = 0.0; pk = -1.0; kpk = -1;
            for (k = 0; k < N; k = k + 1) begin
                sig = sig + rr[k]*rr[k] + ri[k]*ri[k];
                e2  = (ore[f*N+k]-rr[k])*(ore[f*N+k]-rr[k]) + (oim[f*N+k]-ri[k])*(oim[f*N+k]-ri[k]);
                fe  = fe + e2;
                if (ore[f*N+k]*ore[f*N+k] + oim[f*N+k]*oim[f*N+k] > pk) begin
                    pk = ore[f*N+k]*ore[f*N+k] + oim[f*N+k]*oim[f*N+k];
                    kpk = k;
                end
            end
            $display("  N %0d IW %0d frame %0d: signal to FFT-error ratio %.1f dB, peak bin %0d",
                     N, IW, f, 10.0 * $log10(sig / fe), kpk);
            // Random full-scale data: the error must stay at rounding level, far below the
            // signal, because an overflow would give an error comparable to the signal.
            if (10.0 * $log10(sig / fe) < 80.0) begin
                $display("FAIL: N %0d frame %0d error too large", N, f); errors = errors + 1;
            end
            if (f == 2 && kpk != N - 37) begin
                $display("FAIL: N %0d tone in bin %0d, expected %0d", N, kpk, N - 37); errors = errors + 1;
            end
        end
        done = 1'b1;
    end
endmodule

// Top level: one instance with LOG_N = 12 and one with LOG_N = 11 on a shared 150 MHz clock
// (3.333 ns per half period), and a watchdog of 5 ms of simulated time.
module tb_fft_r22sdf_cplx;
    reg clk = 1'b0;
    always #3.333 clk = ~clk;
    reg rst = 1'b1;
    wire d12, d11;
    integer e12, e11;

    tb_fft_cplx_one #(.LOG_N(12), .IW(17), .SEED(5)) t12 (.clk(clk), .rst(rst), .done(d12), .errors(e12));
    tb_fft_cplx_one #(.LOG_N(11), .IW(16), .SEED(9)) t11 (.clk(clk), .rst(rst), .done(d11), .errors(e11));

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        wait (d12 && d11);
        if (e12 + e11 == 0) $display("PASS");
        else $display("FAIL: %0d error(s)", e12 + e11);
        $finish;
    end
    initial begin
        #5_000_000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
