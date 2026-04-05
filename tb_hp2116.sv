//------------------------------------------------------------------------------
// tb_hp2116.sv
//
// - 32K x 16 memory
// - HP 21xx ABS loader (your confirmed format) + range tracker
// - Optional fill whole memory with HALT (octal 102000)
// - Debounced pushbuttons modeled as 1-cycle pulses
// - Switch register (16 toggles) modeled as a TB variable "sw"
//
// Debounce here is simplified: we generate clean 1-cycle pulses directly.
// If you want a more "physical" model (bouncy waveform -> debounce filter),
// say so and I’ll swap it to an actual debounce filter.
//------------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_hp2116;

  localparam int MEM_WORDS = 1 << 15;

  localparam logic [15:0] INSTR_HALT = 16'o102000;

  logic clk, rst_n;

  // Switch register
  logic [15:0] sw;

  // Debounced panel pulses
  logic preset_btn, run_btn, halt_btn, load_mem_btn, load_a_btn, load_b_btn,
        load_addr_btn, disp_mem_btn, single_cycle_btn;

  // CPU <-> memory
  logic [15-1:0] mem_addr;
  logic [16-1:0] mem_wdata;
  logic [16-1:0] mem_rdata;
  logic mem_we;

  logic run_ff, ien_ff;

  // Memory array
  logic [16-1:0] mem [0:MEM_WORDS-1];
  logic uart_rx;
  logic uart_tx;

  // CPU instance
  hp2116_cpu #(
  ) dut (
    .clk(clk),
    .rst_n(rst_n),

    .sw(sw),

    .preset_btn(preset_btn),
    .run_btn(run_btn),
    .halt_btn(halt_btn),
    .load_mem_btn(load_mem_btn),
    .load_a_btn(load_a_btn),
    .load_b_btn(load_b_btn),
    .load_addr_btn(load_addr_btn),
    .disp_mem_btn(disp_mem_btn),
    .single_cycle_btn(single_cycle_btn),

    .run_ff(run_ff),
    .ien_ff(ien_ff),

    .mem_addr(mem_addr),
    .mem_wdata(mem_wdata),
    .mem_rdata(mem_rdata),
    .mem_we(mem_we),

    .uart_rx(uart_rx),
    .uart_tx(uart_tx)
  );

  // Clock
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // Synchronous memory model
  // Kodkommentar: read-data uppdateras på posedge för att få deterministisk timing.
  always_ff @(posedge clk) begin
    if (mem_we) begin
      mem[mem_addr] <= mem_wdata;
    end
    mem_rdata <= mem[mem_addr];
  end

  // Kodkommentar: Starta dump först efter reset för mindre VCD-fil.
  initial begin
    $dumpfile("tb_hp2116.fst");
    @(posedge rst_n);
    $dumpvars(0, tb_hp2116);
  end

  task automatic uart_send_byte(
    input logic [7:0] data,
    ref   logic serial_line
  );
    time bit_time;
    int i;
    begin
      // Kodkommentar: Beräkna bittiden i ns utifrån vald baudrate.
      bit_time = 1_000_000_000ns / 1_250_000;

      // Kodkommentar: Idle-nivån är hög.
      serial_line = 1'b1;
      #(bit_time);

      // Kodkommentar: Startbit.
      serial_line = 1'b0;
      #(bit_time);

      // Kodkommentar: Skicka databitar LSB först.
      for (i = 0; i < 8; i++) begin
        serial_line = data[i];
        #(bit_time);
      end

      // Kodkommentar: Två stoppbitar.
      serial_line = 1'b1;
      #(bit_time);
      serial_line = 1'b1;
      #(bit_time);
    end
  endtask

  task automatic uart_recv_byte(
    input  logic serial_line,
    output logic [7:0] data
  );
    time bit_time;
    int i;
    begin
      // Kodkommentar: Beräkna bittiden i ns utifrån vald baudrate.
      bit_time = 1_000_000_000ns / 1_250_000;

      // Kodkommentar: Vänta på startbit.
      @(negedge serial_line);

      // Kodkommentar: Gå till mitten av första databiten.
      #(bit_time + bit_time/2);

      // Kodkommentar: Sampla 8 databitar, LSB först.
      for (i = 0; i < 8; i++) begin
        data[i] = serial_line;
        #(bit_time);
      end

      // Kodkommentar: Hoppa över stoppbitarna.
      #(2 * bit_time);
    end
  endtask


  task automatic uart_expect_byte(
    input logic serial_line,
    input logic [7:0] expected
  );
    logic [7:0] received;
    begin
      // Kodkommentar: Ta emot en byte från DUT och jämför mot förväntat värde.
      uart_recv_byte(serial_line, received);

      if (received !== expected) begin
        $error("UART mismatch: expected 0x%02h got 0x%02h at time %0t",
               expected, received, $time);
      end
      else begin
        $display("UART OK: 0x%02h at time %0t", received, $time);
      end
    end
  endtask

  initial begin
    logic [7:0] ch;

    forever begin
      // Kodkommentar: Vänta på en byte från DUT:s sändare.
      uart_recv_byte(uart_tx, ch);
      $display("UART TX byte: 0x%02h (%s) at time %0t",
               ch,
               (ch >= 8'h20 && ch <= 8'h7e) ? {byte'(ch)} : ".",
               $time);
    end
  end

  // ------------------------------------------------------------
  // Utility: drive a clean 1-cycle pulse for a button
  // ------------------------------------------------------------
  // Kodkommentar: Detta representerar en debouncad knapp (en ren puls).
  task automatic pulse_btn(ref logic btn);
    begin
      btn = 1'b1;
      @(posedge clk);
      btn = 1'b0;
    end
  endtask

  // ------------------------------------------------------------
  // Fill memory with HALT instructions (optional safety net)
  // ------------------------------------------------------------
  task automatic fill_memory_with_halt();
    int i;
    begin
      for (i = 0; i < MEM_WORDS; i++) begin
        mem[i] = INSTR_HALT;
      end
    end
  endtask

  // ------------------------------------------------------------
  // ABS loader helpers
  // ------------------------------------------------------------
  function automatic int f_getc(input int fd);
    int c;
    c = $fgetc(fd);
    return c;
  endfunction

  // ------------------------------------------------------------
  // Helper: read one 16-bit word, big-endian (MSB first)
  // ------------------------------------------------------------
  // Kodkommentar: Vi maskar ner till exakt 8 bitar för att undvika
  // breddvarningar i Verilator.
  function automatic bit read_word_be(input int fd, output logic [15:0] word);
    int hi, lo;
    logic [7:0] hi8;
    logic [7:0] lo8;
    begin
      hi = f_getc(fd);
      if (hi < 0) return 0;

      lo = f_getc(fd);
      if (lo < 0) return 0;

      hi8 = hi[7:0];
      lo8 = lo[7:0];
      word = {hi8, lo8};

      return 1;
    end
  endfunction

  // ------------------------------------------------------------
  // HP 21xx ABS loader
  //
  // Record:
  //   word0: {count, 8'o000}
  //   word1: address
  //   next:  count data words
  //   last:  checksum
  //
  // Stop rule:
  //   Efter en tillräckligt lång följd av 0000-ord antar vi att
  //   själva tape-datan är slut och att eventuell trailer/text
  //   därefter inte ska laddas.
  // ------------------------------------------------------------
  task automatic load_hp21xx_abs(input string filename, input bit do_fill_halt);
    int fd;
    logic [15:0] hdr, addr_w, data_w, chk_w;
    logic [7:0] count;
    int i, rec;
    logic [14:0] load_addr;
    bit any_loaded;
    logic [14:0] min_addr, max_addr;
    int total_loaded;

    logic [15:0] sum, sum_twos;

    // Kodkommentar: Antal nollord i följd som tolkas som "slut på tape-data".
    localparam int END_ZERO_WORDS = 64;
    int zero_run;

    fd = $fopen(filename, "rb");
    if (fd == 0) $fatal(1, "Could not open ABS file: %s", filename);

    if (do_fill_halt) fill_memory_with_halt();

    any_loaded = 0;
    min_addr = 15'o77777;
    max_addr = 15'o00000;
    total_loaded = 0;
    rec = 0;
    zero_run = 0;

    forever begin
      if (!read_word_be(fd, hdr)) begin
        $display("ABS loader: EOF");
        break;
      end

      // Kodkommentar: Räkna sammanhängande 0000-ord.
      if (hdr == 16'o000000) begin
        zero_run++;

        // Kodkommentar: En lång följd av nollor markerar slut på själva
        // ABS-innehållet. Då avslutar vi innan eventuell text-trailer.
        if (zero_run >= END_ZERO_WORDS) begin
          $display("ABS loader: end of tape data after %0d consecutive zero words.", zero_run);
          break;
        end

        continue;
      end

      // Kodkommentar: Så fort vi ser ett icke-nollord återställs nollräknaren.
      zero_run = 0;

      // Kodkommentar: Ett giltigt record-headerord måste ha low byte = 00.
      if (hdr[7:0] != 8'o000) begin
        $display("ABS loader: non-record word %04h at rec=%0d, stopping.", hdr, rec);
        break;
      end

      count = hdr[15:8];

      if (!read_word_be(fd, addr_w)) begin
        $fatal(1, "ABS loader: EOF while reading address rec=%0d", rec);
      end

      sum = 16'o000000;
      sum = sum + addr_w;

      for (i = 0; i < count; i++) begin
        if (!read_word_be(fd, data_w)) begin
          $fatal(1, "ABS loader: EOF while reading data rec=%0d i=%0d", rec, i);
        end

        // Kodkommentar: Explicit 15-bitars adress för att undvika breddvarningar.
        load_addr = addr_w[14:0] + i[14:0];

        mem[load_addr] = data_w;
        $display("mem[%05o]=%06o",load_addr,data_w);
        any_loaded = 1;
        if (load_addr < min_addr) min_addr = load_addr;
        if (load_addr > max_addr) max_addr = load_addr;
        total_loaded++;

        sum = sum + data_w;
      end

      if (!read_word_be(fd, chk_w)) begin
        $fatal(1, "ABS loader: EOF while reading checksum rec=%0d", rec);
      end

      sum_twos = (~sum) + 16'o000001;

      // Kodkommentar: Behåll din befintliga tolerans för checksum-format.
      if ((chk_w !== sum) && (chk_w !== sum_twos)) begin
        $display("ABS loader: checksum mismatch rec=%0d addr=%0o count=%0d",
                 rec, addr_w[14:0], count);
        $display("  file=%06o (hex %04h)  sum=%06o (hex %04h)  -sum=%06o (hex %04h)",
                 chk_w, chk_w, sum, sum, sum_twos, sum_twos);
      end

      rec++;
    end

    $fclose(fd);

    if (any_loaded) begin
      $display("ABS loader: loaded %0d words, range [%0o .. %0o] (hex [%04h..%04h])",
               total_loaded, min_addr, max_addr, min_addr, max_addr);
    end else begin
      $display("ABS loader: loaded 0 words");
    end
  endtask

  // ------------------------------------------------------------
  // Test sequence demonstrating panel operations
  // ------------------------------------------------------------
  initial begin
    // Init
    rst_n = 1'b0;
    sw = 16'o000000;
    uart_rx = 1'b1;

    preset_btn = 0; run_btn = 0; halt_btn = 0;
    load_mem_btn = 0; load_a_btn = 0; load_b_btn = 0;
    load_addr_btn = 0; disp_mem_btn = 0; single_cycle_btn = 0;

    mem_rdata = '0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;

    // Fill with HALT then load ABS
    load_hp21xx_abs("24296.abs", /*do_fill_halt=*/1'b1);

    // PRESET
    pulse_btn(preset_btn);

    // Example: set address via switches and LOAD ADDRESS
    sw = 16'o040000;
    pulse_btn(load_addr_btn);

    // DISPLAY MEMORY (reads mem[M] into T, increments M and P)
    pulse_btn(disp_mem_btn);

    // LOAD A with switches
    sw = 16'o055555;
    pulse_btn(load_a_btn);
    
    // LOAD A with switches
    sw = 16'o122222;
    pulse_btn(load_b_btn);    

   // Example: set address via switches and LOAD ADDRESS
    sw = 16'o000002;
    pulse_btn(load_addr_btn);    

    // Enable single-cycle mode and do two phase-steps
    //pulse_btn(single_cycle_btn); // enter single mode + arm one phase
    pulse_btn(run_btn);          // RUN
    repeat (50000000) @(posedge clk);  // CPU will advance one phase and stop (armed consumed)

    //pulse_btn(single_cycle_btn); // arm another phase
    repeat (50) @(posedge clk);

    // HALT front-panel
    pulse_btn(halt_btn);

    repeat (20) @(posedge clk);
    $finish;
  end

  // Optional trace
  always_ff @(posedge clk) begin
    // Kodkommentar: Undvik att använda rst_n här för att slippa
    // SYNCASYNCNET-varningen i Verilator.
    if (mem_we) begin
      $display("[%0t] MEM WRITE addr=%0o data=%0o (hex %04h)", $time, mem_addr, mem_wdata, mem_wdata);
    end
  end

endmodule
