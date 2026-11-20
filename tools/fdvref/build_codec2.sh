#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Builds the reference tools of codec2 1.2.0 (c2enc, c2dec, freedv_tx, freedv_rx, ch) with plain gcc, for the test vectors of
# docs/FREEDV.md section 4 (see tools/fdvref/README.md). It does by hand what the CMakeLists of codec2 does, so cmake is not
# needed: generate_codebook makes the eight codebook sources, config.h and codec2/version.h are written, the library sources
# are compiled with the flags that cmake uses for a Linux release build (-O3 -fPIC -D_GNU_SOURCE=1), and the tools are linked
# against the static library. Nothing is installed; everything goes to the build folder, which is deleted first.
#
# Usage: build_codec2.sh /path/to/codec2-1.2.0-checkout /path/to/build-folder
# Needs gcc, ar and bash (Git Bash or MSYS on Windows) and a checkout of codec2 1.2.0. No Gowin EDA, no board.
set -euo pipefail
SRC=$1; B=$2
rm -rf $B; mkdir -p $B/codec2; cd $B
cat > config.h <<E2
#define SIZEOF_INT 4
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_FLOOR 1
#define HAVE_CEIL 1
#define HAVE_MEMSET 1
#define HAVE_POW 1
#define HAVE_SQRT 1
#define HAVE_SIN 1
#define HAVE_COS 1
#define HAVE_ATAN2 1
#define HAVE_LOG10 1
#define HAVE_ROUND 1
#define HAVE_GETOPT 1
E2
cat > codec2/version.h <<E2
#ifndef CODEC2_HAVE_VERSION
#define CODEC2_HAVE_VERSION
#define CODEC2_VERSION_MAJOR 1
#define CODEC2_VERSION_MINOR 2
#define CODEC2_VERSION_PATCH 0
#define CODEC2_VERSION "1.2.0"
#endif
E2
# The flags of cmake's Linux release build, plus -w because the codec2 sources are not ours to fix.
CF="-O3 -fPIC -D_GNU_SOURCE=1 -DGIT_HASH=\"None\" -std=gnu99 -w"
D=$SRC/src/codebook
# The generator turns the text codebooks of codec2 into the C sources that the library includes.
gcc $CF -o generate_codebook $SRC/src/generate_codebook.c -lm
./generate_codebook lsp_cb $D/lsp{1,2,3,4,5,6,7,8,9,10}.txt > codebook.c
./generate_codebook lsp_cbd $D/dlsp{1,2,3,4,5,6,7,8,9,10}.txt > codebookd.c
./generate_codebook lsp_cbjmv $D/lspjmv{1,2,3}.txt > codebookjmv.c
./generate_codebook ge_cb $D/gecb.txt > codebookge.c
./generate_codebook newamp1vq_cb $D/train_120_1.txt $D/train_120_2.txt > codebooknewamp1.c
./generate_codebook newamp1_energy_cb $D/newamp1_energy_q.txt > codebooknewamp1_energy.c
./generate_codebook newamp2vq_cb $D/codes_450.txt > codebooknewamp2.c
./generate_codebook newamp2_energy_cb $D/newamp2_energy_q.txt > codebooknewamp2_energy.c
# The library sources (file names without .c); each is compiled in the background and the `wait` below ends the loops.
S="dump lpc nlp postfilter sine codec2 codec2_fft cohpsk codec2_fifo fdmdv fm fsk fmfsk kiss_fft kiss_fftr linreg interp lsp mbest newamp1 ofdm ofdm_mode phase quantise pack golay23 freedv_api freedv_1600 freedv_700 freedv_2020 freedv_fsk freedv_vhf_framing freedv_data_channel varicode modem_stats mpdecode_core phi0 gp_interleaver interldpc filter HRA_112_112 HRA_56_56 HRAb_396_504 H_256_768_22 H_256_512_4 HRAa_1536_512 H_128_256_5 H_2064_516_sparse H_4096_8192_3d H_16200_9720 H_1024_2048_4f H_212_158 ldpc_codes lpcnet_freq reliable_text"
OBJS=""
for f in $S; do gcc $CF -I$SRC/src -I. -c $SRC/src/$f.c -o $f.o & OBJS="$OBJS $f.o"; done
for f in codebook codebookd codebookjmv codebookge codebooknewamp1 codebooknewamp1_energy codebooknewamp2 codebooknewamp2_energy; do gcc $CF -I$SRC/src -I. -c $f.c -o $f.o & OBJS="$OBJS $f.o"; done
wait
# One static library from all objects, then each tool linked against it.
ar rcs libcodec2.a $OBJS
for t in c2enc c2dec freedv_tx freedv_rx ch; do gcc $CF -I$SRC/src -I. $SRC/src/$t.c libcodec2.a -lm -o $t; done
ls -la c2enc c2dec freedv_tx freedv_rx ch
