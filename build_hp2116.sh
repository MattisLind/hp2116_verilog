#!/bin/bash
docker run --rm -it \
  --entrypoint bash \
  -v "$PWD":/work -w /work \
  verilator/verilator:latest \
  -lc '
    rm -rf obj_dir &&
    verilator -Wall -Wno-fatal -Wno-UNUSEDSIGNAL --no-sched-zero-delay \
      --sv --timing --binary --trace-fst \
      tb_hp2116.sv hp2116_cpu.sv hp12531c.sv hp12597a.sv \
      --top-module tb_hp2116 && \
    ./obj_dir/Vtb_hp2116 +PTR_FILE=24396-1.abs
  '
