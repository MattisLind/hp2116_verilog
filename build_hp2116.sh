#!/bin/bash

docker run --rm -it \
  --entrypoint bash \
  -v "$PWD":/work -w /work \
  verilator/verilator:latest \
  -lc '
    rm -rf obj_dir &&
    verilator -Wall -Wno-fatal -Wno-UNUSEDSIGNAL --no-sched-zero-delay \
      --sv --timing --binary --trace-fst\
      tb_hp2116.sv hp2116_cpu.sv hp12531c.sv hp12597a.sv \
      --top-module tb_hp2116 && \
    ./obj_dir/Vtb_hp2116 "+PTR_FILE=$1" "+DSN=$2" "+PRETEST=$3" "+TRACE=$4"
  ' bash "$1" "$2" "$3" "$4"
