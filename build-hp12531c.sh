#!/bin/bash
docker run --rm -it \
  --entrypoint bash \
  -v "$PWD":/work -w /work \
    verilator/verilator:latest \
  -lc '
    verilator -Wall -Wno-fatal -Wno-UNUSEDSIGNAL \
      --sv --timing --trace-vcd \
      --cc tb_hp12531c.sv hp12531c.sv hostif.sv \
      --exe sim_main.cpp hostif_dpi.c \
      --top-module tb_hp12531c && \
    make -C obj_dir -j -f Vtb_hp12531c.mk Vtb_hp12531c && \
    ./obj_dir/Vtb_hp12531c
  '
