

This is a a project mostly done to learn Verilog a bit. The idea is to make a implementation of the HP 2116 minicomputer from 1966. ChatGPT helped to get me started. At this point it passes the pretest of the HP diagnostic configurator paper tape successfully. Although IO is not yet implemented so much.

I use Vertilator to compile and run the verilog code and the gtkwave to view the resulting wavforms.

```
docker run --rm -it \                                                 
  -v "$PWD":/work -w /work \
  verilator/verilator:latest \
  -Wall -Wno-fatal -Wno-UNUSEDSIGNAL --binary --binary --sv --trace-vcd tb_hp2116.sv hp2116_cpu.sv --top-module tb_hp2116
```

and 

```docker run --rm -it \                                                 
  -v "$PWD":/work -w /work \
  --entrypoint /work/obj_dir/Vtb_hp2116 \
  verilator/verilator:latest
```


