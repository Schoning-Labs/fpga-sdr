// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Names for the 8b/10b symbols that the PCS and its testbenches use, written as the byte that the coder
// and decoder take in: the {y[2:0], x[4:0]} packing in which a symbol Dx.y or Kx.y is the 5-bit number x
// in the low bits and the 3-bit number y above it (so K28.5 is x = 28, y = 5, which is 0xBC). See
// sfp_enc20.v for what 8b/10b is. These localparams only give names to the bytes. The codes themselves
// are in rtl/n1/tab_8b10b.vh (generated from the IEEE 802.3 clause 36 tables, with a self test of the
// comma property and of the round trip in the script that makes it).

localparam [7:0] N1_K_COMMA  = 8'hBC; // K28.5 (x=28,y=5): comma, used alone as the AN/idle marker
localparam [7:0] N1_K_SOP    = 8'hFB; // K27.7 (x=27,y=7): /S/, start-of-packet
localparam [7:0] N1_K_EOP    = 8'hFD; // K29.7 (x=29,y=7): /T/, end-of-packet
localparam [7:0] N1_K_CEXT   = 8'hF7; // K23.7 (x=23,y=7): /R/, carrier-extend / end-of-packet fill

localparam [7:0] N1_D_IDLE1  = 8'hC5; // D5.6  (x=5, y=6): /I1/, idle when current RD is +
localparam [7:0] N1_D_IDLE2  = 8'h50; // D16.2 (x=16,y=2): /I2/, idle when current RD is -
localparam [7:0] N1_D_CFG1   = 8'hB5; // D21.5 (x=21,y=5): /C1/ ability data code-group
localparam [7:0] N1_D_CFG2   = 8'h42; // D2.2  (x=2, y=2): /C2/ ability data code-group, sent by sfp_pcs.v in
                                       // alternation with /C1/
