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

  localparam logic [15:0] INSTR_HALT    = 16'o102000;
  localparam time         UART_BIT_TIME = 400ns;

  logic clk, rst_n;
  logic [15:0] saved_A;
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
  logic read_command;
  logic [7:0] ptr_datain;
  logic [7:0] ptr_dataout;
  logic ptr_feedhole;
  logic ptr_read;
  longint cycles;
    // File handle and temporary variable for the paper tape reader.
  integer ptr_fd;
  integer ptr_c;

  // Default paper tape file. Can be overridden with +PTR_FILE=...
  string ptr_filename;
  string DSN;
  string pretest, loadfile;
  string trace;

    // Kodkommentar: Filhantering för simulerad pappersremsa via UART.
  integer tty_punch_fd;
  integer tty_read_fd;
  integer tty_c;

  // Kodkommentar: Tillståndsflaggor för fångst och återläsning.
  logic tty_capture_enable;
  logic tty_playback_active;

  // Kodkommentar: Filnamn för temporär "pappersremsa".
  string tty_tape_filename;

    // Kodkommentar: Styrning för bakgrundsuppspelning av fångad UART-fil.
  logic playback_request;
  time  playback_inter_char_delay;
  int tty_skip_count;
  // Kodkommentar: Styr om återläsning från fil är tillåten eller stoppad.
  logic playback_enable;
  logic loader_protected_switch;
  // CPU instance
  hp2116_cpu #(
  ) cpu (
    .clk(clk),
    .popio(~rst_n),

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
    .uart_tx(uart_tx),
    .read_command(read_command),
    .ptr_datain(ptr_datain),
    .ptr_dataout(ptr_dataout),
    .ptr_feedhole(ptr_feedhole),
    .ptr_read(ptr_read),
    .loader_protected_switch(loader_protected_switch)
  );

  // Clock
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // Synchronous memory model
  // Read data is updated on posedge to get deterministic timing.
  always_ff @(posedge clk) begin
    if (mem_we) begin
      mem[mem_addr] <= mem_wdata;
    end
    mem_rdata <= mem[mem_addr];
  end

  // Start waveform dump only after reset for a smaller dump file.
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
      // Compute the bit time in ns from the selected baud rate.
      bit_time = UART_BIT_TIME;

      // The idle level is high.
      serial_line = 1'b1;
      #(bit_time);

      // Start bit.
      serial_line = 1'b0;
      #(bit_time);

      // Send data bits LSB first.
      for (i = 0; i < 8; i++) begin
        serial_line = data[i];
        #(bit_time);
      end

      // Two stop bits.
      serial_line = 1'b1;
      #(bit_time);
      serial_line = 1'b1;
      #(bit_time);
    end
  endtask

  task automatic uart_recv_byte(
    ref  logic serial_line,
    output logic [7:0] data
  );
    time bit_time;
    int i;
    begin
      // Compute the bit time in ns from the selected baud rate.
      bit_time = UART_BIT_TIME;

      // Wait for the start bit.
      @(negedge serial_line);

      // Move to the middle of the first data bit.
      #(bit_time + bit_time/2);

      // Sample 8 data bits, LSB first.
      for (i = 0; i < 8; i++) begin
        data[i] = serial_line;
        #(bit_time);
      end

      // Skip the stop bits.
      #(2 * bit_time);
    end
  endtask

  task automatic uart_expect_byte(
    ref logic serial_line,
    input logic [7:0] expected
  );
    logic [7:0] received;
    begin
      // Receive one byte from the DUT and compare it with the expected value.
      uart_recv_byte(serial_line, received);

      if (received !== expected) begin
        $error("UART mismatch: expected 0x%02h got 0x%02h at time %0t",
               expected, received, $time);
      end
      else begin
        if (!$value$plusargs("TRACE=%s", trace))
          trace = "NO";
        if (trace == "YES")
          $display("UART OK: 0x%02h at time %0t", received, $time);
      end
    end
  endtask

  initial begin : uart_tx_monitor
    logic [7:0] ch;

    forever begin
      uart_recv_byte(uart_tx, ch);

      $display("UART TX byte: 0x%02h (%s) at time %0t",
               ch,
               (ch >= 8'h20 && ch <= 8'h7e) ? {byte'(ch)} : ".",
               $time);

      if (tty_capture_enable && (tty_punch_fd != 0)) begin
          // Kodkommentar: Hoppa över de första 40 tecknen (leader).
          if (tty_skip_count < 40) begin
              tty_skip_count++;
          end
          else begin
              $fwrite(tty_punch_fd, "%c", ch);
          end
      end
    end
  end


  // Kodkommentar: Läs tillbaka den fångade "pappersremsan" via UART till DUT.
  // Kodkommentar: Varje byte skickas med en extra paus mellan tecknen.
  task automatic tty_playback_file(
    input integer fd,
    input time inter_char_delay
  );
    int c;
    logic [7:0] ch;
    begin
      while (1) begin
        c = $fgetc(fd);
        if (c < 0)
          break;

        ch = c[7:0];

        $display("UART RX playback byte: 0x%02h (%s) at time %0t",
                 ch,
                 (ch >= 8'h20 && ch <= 8'h7e) ? {byte'(ch)} : ".",
                 $time);

        uart_send_byte(ch, uart_rx);

        if (inter_char_delay != 0)
          #(inter_char_delay);
      end
    end
  endtask


  // Kodkommentar: Öppna temporärfil för att fånga UART-utdata.
  task automatic tty_start_capture();
    begin
      if (tty_punch_fd != 0) begin
        $fclose(tty_punch_fd);
        tty_punch_fd = 0;
      end

      tty_punch_fd = $fopen(tty_tape_filename, "wb");
      if (tty_punch_fd == 0) begin
        $fatal(1, "Could not open %s for UART punch output", tty_tape_filename);
      end
      tty_skip_count = 0;
      tty_capture_enable = 1'b1;
      $display("TTY capture started: %s at time %0t", tty_tape_filename, $time);
    end
  endtask


  // Kodkommentar: Stäng fångstfilen och förbered återläsning.
  task automatic tty_stop_capture_and_rewind();
    begin
      tty_capture_enable = 1'b0;

      if (tty_punch_fd != 0) begin
        $fclose(tty_punch_fd);
        tty_punch_fd = 0;
      end

      if (tty_read_fd != 0) begin
        $fclose(tty_read_fd);
        tty_read_fd = 0;
      end

      tty_read_fd = $fopen(tty_tape_filename, "rb");
      if (tty_read_fd == 0) begin
        $fatal(1, "Could not reopen %s for UART playback", tty_tape_filename);
      end

      $display("TTY capture stopped and rewound: %s at time %0t", tty_tape_filename, $time);
    end
  endtask



  // Kodkommentar: Begär att bakgrundsprocessen ska starta uppspelning.
  task automatic tty_request_playback();
    begin
      if (tty_read_fd == 0)
        $fatal(1, "TTY playback requested but no read file is open");
      playback_enable = 1'b1;
      playback_request = 1'b1;
    end
  endtask

task automatic tty_stop_playback();
  begin
    playback_enable = 1'b0;
    $display("TTY playback stopped at time %0t", $time);
  end
endtask

// Kodkommentar: Bakgrundsprocess som utför playback när den begärs.
initial begin : tty_playback_daemon
  forever begin
    @(posedge playback_request);
    playback_request = 1'b0;

    tty_playback_active = 1'b1;
    tty_playback_file_on_demand(tty_read_fd);
    tty_playback_active = 1'b0;

    $display("TTY playback finished at time %0t", $time);
  end
end

  // Kodkommentar: Vänta tills interfacet begär en ny byte.
  task automatic wait_reader_request();
    begin
      if (!read_command)
        @(posedge read_command);
    end
  endtask


  // Kodkommentar: Skicka tillbaka fångad teletype-data en byte i taget,
  // Kodkommentar: styrt av läsarinterfacets read-begäran.
  task automatic tty_playback_file_on_demand(
    input integer fd
  );
    int c;
    logic [7:0] ch;
    begin
      while (1) begin
        wait_reader_request();

        c = $fgetc(fd);
        if (c < 0)
          break;

        ch = c[7:0];

        $display("UART RX on-demand byte: 0x%02h (%s) at time %0t",
                 ch,
                 (ch >= 8'h20 && ch <= 8'h7e) ? {byte'(ch)} : ".",
                 $time);

        uart_send_byte(ch, uart_rx);

        // Kodkommentar: Vänta ut den aktuella read-begäran innan nästa byte.
        while (playback_enable && read_command)
        @(posedge clk);
      end
    end
  endtask

  // Feed one byte into the simulated paper tape reader.
  // The data is made stable before feedhole and feedhole stays active across
  // a positive clock edge so the DUT safely latches the byte.
  task automatic ptr_feed_byte(input logic [7:0] value);
    begin
      ptr_datain = value;

      // Make the data stable before the active sampling edge.
      @(negedge clk);
      ptr_feedhole = 1'b1;

      // Keep feedhole active across a positive edge.
      @(negedge clk);
      @(negedge clk);
      @(negedge clk);
      @(negedge clk);
      ptr_feedhole = 1'b0;
    end
  endtask

  // ------------------------------------------------------------
  // Utility: drive a clean 1-cycle pulse for a button
  // ------------------------------------------------------------
  // This represents a debounced button press (a clean pulse).
  task automatic pulse_btn(ref logic btn);
    begin
      btn = 1'b1;
      @(posedge clk);   // The DUT can sample the button here
      @(negedge clk);   // Wait until after the sampling edge
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
  // Mask down to exactly 8 bits to avoid
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
  //   After a long enough run of 0000 words, assume that
  //   the actual tape data has ended and that any trailer/text
  //   that follows should not be loaded.
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

    // Number of consecutive zero words interpreted as "end of tape data".
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

      // Count consecutive 0000 words.
      if (hdr == 16'o000000) begin
        zero_run++;

        // A long run of zeros marks the end of the actual
        // ABS content. Loading stops before any trailing text.
        if (zero_run >= END_ZERO_WORDS) begin
          $display("ABS loader: end of tape data after %0d consecutive zero words.", zero_run);
          break;
        end

        continue;
      end

      // As soon as a non-zero word is seen, the zero counter is reset.
      zero_run = 0;

      // A valid record header word must have low byte = 00.
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

        // Explicit 15-bit address to avoid width warnings.
        load_addr = addr_w[14:0] + i[14:0];

        mem[load_addr] = data_w;
        //$display("mem[%05o]=%06o",load_addr,data_w);
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

      // Keep the existing checksum-format tolerance.
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
    //mem[15'o4274] = 16'o002002;
  endtask
function automatic string fmt_mem_operand(input logic [15:0] tr);
    logic indirect;
    logic [9:0] addr;

    begin
        indirect = tr[15];
        addr     = tr[9:0];

        if (indirect)
            return $sformatf("%06o,I", addr);
        else
            return $sformatf("%06o", addr);
    end
endfunction

function automatic string append_part(input string base, input string part);
    if (part == "")
        return base;
    else if (base == "")
        return part;
    else
        return {base, ", ", part};
endfunction

function automatic string fmt_rotate_shift(input logic [2:0] code, input logic a);
  string acc;
  if (a) acc="B";
  else acc="A";
  case (code)
    3'o0: return $sformatf("%sLS", acc);
    3'o1: return $sformatf("%sRS", acc);
    3'o2: return $sformatf("R%sL", acc);
    3'o3: return $sformatf("R%sR", acc);
    3'o4: return $sformatf("%sLR", acc);
    3'o5: return $sformatf("ER%s", acc);
    3'o6: return $sformatf("EL%s", acc);
    3'o7: return $sformatf("%sLF", acc);
  endcase
endfunction

function automatic string disasm_srg(input logic [15:0] tr);
    string result;
    string part;

    begin
        result = "";

        // First shift/rotate operation from bit field [8:6].
        if (tr[9]) begin
            part = fmt_rotate_shift(tr[8:6], tr[11]);
            result = append_part(result, part);
        end

        // CLE is added if bit 5 is set.
        if (tr[5]) begin
            result = append_part(result, "CLE");
        end

        // SLA or SLB is added if bit 3 is set.
        if (tr[3]) begin
            if (tr[11])
                result = append_part(result, "SLB");
            else
                result = append_part(result, "SLA");
        end

        // Final shift/rotate operation from bit field [2:0].
        if (tr[4]) begin
            part = fmt_rotate_shift(tr[2:0], tr[11]);
            result = append_part(result, part);
        end

        // If no subcommand was found, return a fallback text.
        if (result == "")
            return "NOP";
        else
            return result;
    end
endfunction

function automatic string disasm_asg (input logic [15:0] tr);
  string acc, result;
  if (tr[11]) acc ="B";
  else acc="A";
  if (tr[9:0] == 10'o0000) result = append_part(result, "NOP");
  else begin
    case (tr[9:8])
      2'o1: result = append_part(result, $sformatf("CL%s", acc));
      2'o2: result = append_part(result, $sformatf("CM%s", acc));
      2'o3: result = append_part(result, $sformatf("CC%s", acc));
      default: result = append_part(result, "");
    endcase
    if (tr[5]) result = append_part(result, "SEZ");
    case (tr[7:6])
      2'o1: result = append_part(result, "CLE");
      2'o2: result = append_part(result, "CME");
      2'o3: result = append_part(result, "CCE");
      default: result = append_part(result, "");
    endcase
    if (tr[4]) result = append_part(result, $sformatf("SS%s", acc));
    if (tr[3]) result = append_part(result, $sformatf("SL%s", acc));
    if (tr[2]) result = append_part(result, $sformatf("IN%s", acc));
    if (tr[1]) result = append_part(result, $sformatf("SZ%s", acc));
    if (tr[0]) result = append_part(result, "RSS");
    end
  return result;
endfunction

// Minimal first version of the disassembler.
// Disassembler with a local operand string for memory references.
function automatic string mini_disasm(input logic [15:0] tr);
    logic [5:0] ir;
    logic [3:0] op4;
    string memop;

    begin
        ir    = tr[15:10];
        op4   = ir[4:1];
        memop = fmt_mem_operand(tr);

        if (ir[5:2] == 4'o00) begin
            if (ir[0])
                return disasm_asg(tr);
            else
                return disasm_srg(tr);
        end
        else if (ir[5:2] == 4'o10) begin
            if (ir[0])
              case (tr[8:6])
                3'o0: begin
                  if (tr[10]) begin
                    if (tr[9]) begin
                      return {"HLT ", $sformatf("%02o,C", tr[5:0])};
                    end else
                      return {"HLT ", $sformatf("%02o", tr[5:0])};
                    end
                  end
                3'o1: begin
                  if (tr[9]) begin
                    return {"CLF ", $sformatf("%02o", tr[5:0])};
                  end
                  else begin
                    return {"STF ", $sformatf("%02o", tr[5:0])};
                  end
                end
                3'o2: begin
                  return {"SFC ", $sformatf("%02o", tr[5:0])};
                end
                3'o3: begin
                  return {"SFS ", $sformatf("%02o", tr[5:0])};
                end
                3'o4: begin
                  if (tr[11]) begin
                    if (tr[9]) begin
                      return {"MIB ", $sformatf("%02o,C", tr[5:0])};
                    end
                    else begin
                      return {"MIB ", $sformatf("%02o", tr[5:0])};
                    end
                  end
                  else begin
                    if (tr[9]) begin
                      return {"MIA ", $sformatf("%02o,C", tr[5:0])};
                    end
                    else begin
                      return {"MIA ", $sformatf("%02o", tr[5:0])};
                    end
                  end

                end
                3'o5: begin
                  if (tr[11]) begin
                    if (tr[9]) begin
                      return {"LIB ", $sformatf("%02o,C", tr[5:0])};
                    end
                    else begin
                      return {"LIB ", $sformatf("%02o", tr[5:0])};
                    end
                  end
                  else begin
                    if (tr[9]) begin
                      return {"LIA ", $sformatf("%02o,C", tr[5:0])};
                    end
                    else begin
                      return {"LIA ", $sformatf("%02o", tr[5:0])};
                    end
                  end
                end
                3'o6: begin
                  if (tr[11]) begin
                      if (tr[9]) begin
                        return {"OTB ", $sformatf("%02o,C", tr[5:0])};
                      end
                      else begin
                        return {"OTB ", $sformatf("%02o", tr[5:0])};
                      end
                  end
                  else begin
                      if (tr[9]) begin
                        return {"OTA ", $sformatf("%02o,C", tr[5:0])};
                      end
                      else begin
                        return {"OTA ", $sformatf("%02o", tr[5:0])};
                      end
                  end
                end
                3'o7: begin
                  if (tr[11]) begin
                      if (tr[9]) begin
                        return {"CLC ", $sformatf("%02o,C", tr[5:0])};
                      end
                      else begin
                        return {"CLC ", $sformatf("%02o", tr[5:0])};
                      end
                  end
                  else begin
                      if (tr[9]) begin
                        return {"STC ", $sformatf("%02o,C", tr[5:0])};
                      end
                      else begin
                        return {"STC ", $sformatf("%02o", tr[5:0])};
                      end
                  end
                end
              endcase
            else
                return "???";
        end
        else begin
            unique case (op4)
                4'o10: return {"ADA ", memop};
                4'o11: return {"ADB ", memop};
                4'o02: return {"AND ", memop};
                4'o12: return {"CPA ", memop};
                4'o13: return {"CPB ", memop};
                4'o06: return {"IOR ", memop};
                4'o07: return {"ISZ ", memop};
                4'o05: return {"JMP ", memop};
                4'o03: return {"JSB ", memop};
                4'o14: return {"LDA ", memop};
                4'o15: return {"LDB ", memop};
                4'o16: return {"STA ", memop};
                4'o17: return {"STB ", memop};
                4'o04: return {"XOR ", memop};
                default: return "???";
            endcase
        end
    end
endfunction

// Return an empty fixed-width string for non-memory-reference instructions.
function automatic string blank_memref_info();
    return "                 ";  // 19 tecken: samma bredd som "M=001405 D=055555"
endfunction

// Determine whether the instruction is a memory-reference instruction.
function automatic logic is_memref_instr(input logic [15:0] tr);
    logic [5:0] ir;
    logic [3:0] op4;

    begin
        ir  = tr[15:10];
        op4 = ir[4:1];

        // The shift/rotate group is not a memory reference.
        if ((ir[5:2] == 4'o00) && !ir[0])
            return 1'b0;

        // The alter/skip group is not a memory reference.
        if ((ir[5:2] == 4'o00) && ir[0])
            return 1'b0;

        // The I/O group is not a memory reference.
        if ((ir[5:2] == 4'o10) && ir[0])
            return 1'b0;

        // MAC and other special groups are treated here as non-memory-reference instructions.
        if ((ir[5:2] == 4'o10) && !ir[0])
            return 1'b0;

        // Only true memory-reference instructions return true.
        unique case (op4)
            4'o02,  // AND
            4'o03,  // JSB
            4'o04,  // XOR
            4'o05,  // JMP
            4'o06,  // IOR
            4'o07,  // ISZ
            4'o10,  // ADA
            4'o11,  // ADB
            4'o12,  // CPA
            4'o13,  // CPB
            4'o14,  // LDA
            4'o15,  // LDB
            4'o16,  // STA
            4'o17:  // STB
                return 1'b1;
            default:
                return 1'b0;
        endcase
    end
endfunction

// Read one operand word the same way the CPU does in INDIRECT/EXECUTE T1.
// Address 0 means register A and address 1 means register B.
function automatic logic [15:0] read_operand_word(
    input logic [14:0] addr,
    input logic [15:0] a_val,
    input logic [15:0] b_val
);
    begin
        if (addr == 15'o00000)
            return a_val;
        else if (addr == 15'o00001)
            return b_val;
        else
            return mem[addr];
    end
endfunction

// Compute operand information for memory-reference instructions.
// Returns
//   "M=xxxxxx D=xxxxxx" for successful resolution
//   "M=ERROR  D=ERROR " on an indirect-chain error
//   a blank string for non-memory-reference instructions
function automatic string memref_info(
    input logic [15:0] tr,
    input logic [14:0] p_val,
    input logic [15:0] a_val,
    input logic [15:0] b_val
);
    logic        indirect;
    logic        current_page;
    logic [9:0]  off10;
    logic [14:0] eff_addr;
    logic [15:0] data_word;
    int          level;

    begin
        // Return only a blank field if this is not a memory-reference instruction.
        if (!is_memref_instr(tr))
            return blank_memref_info();

        // Extract the instruction fields.
        indirect     = tr[15];
        current_page = tr[10];
        off10        = tr[9:0];

        // The same direct-addressing rule as in the CPU:
        // TR[10] = 1 => current page, otherwise zero page.
        if (current_page)
            eff_addr = {p_val[14:10], off10};
        else
            eff_addr = {5'b00000, off10};

        // Follow the indirect chain up to 10 levels.
        for (level = 0; level < 10; level++) begin
            data_word = read_operand_word(eff_addr, a_val, b_val);

            // If the instruction is no longer indirect, this is the final operand.
            if (!indirect)
                return $sformatf("M=%06o D=%06o", eff_addr, data_word);

            // The next link in the chain comes from the fetched word.
            indirect = data_word[15];
            eff_addr = data_word[14:0];
        end

        // If the instruction is still indirect after 10 levels, it is treated as an error.
        return "M=ERROR  D=ERROR ";
    end
endfunction

// Receive exactly one string from the DUT over UART.
// Each received byte is compared directly against the expected text.
task automatic uart_expect_string(
    ref logic serial_line,
    input string expected
);
    logic [7:0] ch;
    int i;
    begin
        for (i = 0; i < expected.len(); i++) begin
            uart_recv_byte(serial_line, ch);

            if (ch !== expected[i]) begin
                $error("UART string mismatch at index %0d: expected 0x%02h ('%s') got 0x%02h ('%s') at time %0t",
                       i,
                       expected[i],
                       (expected[i] >= 8'h20 && expected[i] <= 8'h7e) ? {byte'(expected[i])} : ".",
                       ch,
                       (ch >= 8'h20 && ch <= 8'h7e) ? {byte'(ch)} : ".",
                       $time);
                return;
            end
        end

        $display("UART RX matched string: \"%s\" at time %0t", expected, $time);
    end
endtask

// Send a full string to the DUT over UART.
// A programmable extra delay is inserted between characters.
task automatic uart_send_string(
    ref logic serial_line,
    input string text,
    input time inter_char_delay
);
    int i;
    logic [7:0] ch;
    begin
        for (i = 0; i < text.len(); i++) begin
            ch = text[i][7:0];
            uart_send_byte( ch, serial_line);

            // Extra pause between characters if desired.
            if (inter_char_delay != 0)
                #(inter_char_delay);
        end
    end
endtask

// Wait for a prompt from the DUT and then send a reply.
task automatic uart_expect_and_respond(
    ref logic cpu_tx,
    ref logic tb_rx,
    input string expected_prompt,
    input string response,
    input time inter_char_delay,
    input time after_match_delay
);
    begin
        uart_expect_string(cpu_tx, expected_prompt);
        if (after_match_delay != 0)
            #(after_match_delay);
        $display("UART sending response: \"%s\" at time %0t", response, $time);
        uart_send_string(tb_rx, response, inter_char_delay);
    end
endtask

initial begin
    if (!$value$plusargs("DSN=%s", DSN))
      DSN = "101100";
    // Wait until reset is released.
    wait (rst_n == 1'b1);

    // First blank line.
    // uart_expect_string(uart_tx, "\r\n");

    // Configuration line.
    // uart_expect_string(uart_tx, "2116, NO DMA, NO MPRT, 32K MEMORY\r\n");

    // Second blank line.
    // uart_expect_string(uart_tx, "\r\n");

    // Wait for the prompt and reply.
    // The example response here is only an example — replace it with the
    // exact response expected by the diagnostic program.
    uart_expect_and_respond(
        uart_tx,
        uart_rx,
        "\r\n2116, DMA, NO MPRT, 32K MEMORY\r\n\r\nLINE PRINTER (NO.,SC)........",
        "NONE\r",
        4_000ns,
        20_000ns
    );

    uart_expect_and_respond(
        uart_tx,
        uart_rx,
        "\r\n\r\nDIAG. INPUT DEVICE (NO.,SC)..",
        "2748,11\r",
        4_000ns,
        20_000ns
    );

    uart_expect_and_respond(
        uart_tx,
        uart_rx,
        "\r\n\r\nREADY DIAG. INPUT DEVICE\r\n\r\nDSN(,SEQ.DIAG.EXECUT.).......",
        {DSN, "\r"},
        4_000ns,
        20_000ns
    );
    $display("Finished scripted UART exchange at time %0t", $time);
end

// Print the disassembly string with clear delimiters
// so hidden characters are easier to spot.
always @(posedge clk or negedge rst_n) begin
  if (!$value$plusargs("TRACE=%s", trace))
    trace <= "NO";
  if (trace == "YES") begin
    if (rst_n && cpu.run_ff) begin
        if ((cpu.phase == 3'd0) && (cpu.tstate == 3'd2)) begin
            string a,b, dis, meminfo;
            dis = $sformatf("%-20s", mini_disasm(cpu.TR));
            meminfo = memref_info(cpu.TR, cpu.P, cpu.A, cpu.B);
            a = $sformatf("%06o", cpu.A);
            b = $sformatf("%06o", cpu.B);

            $display("TIME %020t  %s A=%s B=%s EXTEND=%1o OVERFLOW=%1o IE=%1o %06o %06o  %-20s", $time, meminfo, a, b, cpu.EXTEND, cpu.OVERFLOW, cpu.Interrupt_System_Enable, cpu.P, cpu.TR, dis);
        end
    end
  end
end

  // Simulated HP12597A paper tape reader that feeds bytes from a file.
  // When the interface asserts READ, the next byte is read from the file
  // and FEEDHOLE is pulsed so the interface latches the data.
  initial begin : paper_tape_reader
    ptr_datain   = 8'h00;
    ptr_feedhole = 1'b0;

    // Allow the file name to be passed in as a plusarg:
    //   +PTR_FILE=min_tape.bin
    if (!$value$plusargs("PTR_FILE=%s", ptr_filename))
      ptr_filename = "paper_tape.bin";

    ptr_fd = $fopen(ptr_filename, "rb");
    if (ptr_fd == 0) begin
      $display("PTR: no tape file opened (%s). Reader simulator disabled.", ptr_filename);
      disable paper_tape_reader;
    end

    $display("PTR: opened tape file %s", ptr_filename);

    forever begin
      // Wait until the reader requests the next character.
      @(posedge ptr_read);

      // Read the next byte from the host file.
      ptr_c = $fgetc(ptr_fd);

      if (ptr_c < 0) begin
        $display("PTR: EOF on %s at time %0t", ptr_filename, $time);

        // At EOF, no more bytes are fed.
        disable paper_tape_reader;
      end
      if (!$value$plusargs("TRACE=%s", trace))
        trace = "NO";
      if (trace == "YES") begin
        $display("PTR: byte %03o (0x%02h) at time %0t", ptr_c[7:0], ptr_c[7:0], $time);
      end
      ptr_feed_byte(ptr_c[7:0]);
    end
  end

  // ------------------------------------------------------------
  // Test sequence demonstrating panel operations
  // ------------------------------------------------------------
  initial begin
    if (!$value$plusargs("PRETEST=%s", pretest) || pretest == "") 
      pretest = "NO";
    if (!$value$plusargs("LOADFILE=%s", loadfile) || loadfile == "")
      loadfile = "diagnostics/24296-60001_DSN000200_DIAGNOSTIC_CONFIGURATOR.abin";      
    $display("LOADFILE=%s", loadfile);  
    // Init
    rst_n = 1'b0;
    sw = 16'o000000;
    uart_rx = 1'b1;
    ptr_datain = 8'h00;
    ptr_feedhole = 1'b0;
    preset_btn = 0; run_btn = 0; halt_btn = 0;
    load_mem_btn = 0; load_a_btn = 0; load_b_btn = 0;
    load_addr_btn = 0; disp_mem_btn = 0; single_cycle_btn = 0;
    tty_punch_fd       = 0;
    tty_read_fd        = 0;
    tty_capture_enable = 1'b0;
    tty_playback_active = 1'b0;
    tty_tape_filename  = "tty_punch.tmp";
    mem_rdata = '0;
    playback_request = 1'b0;
    playback_inter_char_delay = 0ns;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    tty_skip_count = 0;
    playback_enable = 1'b0;
    // Fill with HALT then load ABS
    load_hp21xx_abs(loadfile, /*do_fill_halt=*/1'b1);

    // PRESET
    pulse_btn(preset_btn);

    // Example: set address via switches and LOAD ADDRESS
    sw = 16'o040000;
    pulse_btn(load_addr_btn);

    // DISPLAY MEMORY (reads mem[M] into T, increments M and P)
    pulse_btn(disp_mem_btn);

    // LOAD A with switches
    sw = 16'o000000;
    pulse_btn(load_a_btn);

    // LOAD B with switches
    sw = 16'o000000;
    pulse_btn(load_b_btn);

   // Example: set address via switches and LOAD ADDRESS
    if (pretest == "YES")
      sw = 16'o000002;  // run pre-test or diag
    else
      sw = 16'o000100;    // skip pre-test and go directly to configurator in conversational mode.
    pulse_btn(load_addr_btn);
    sw = 16'o00010;
    if (loadfile =="diagnostics/24185-60001_Rev-A.abin") begin
      loader_protected_switch = 1'b1;
      sw = 16'o000112;
    end
    // Enable single-cycle mode and do two phase-steps
    //pulse_btn(single_cycle_btn); // enter single mode + arm one phase
    pulse_btn(run_btn);          // RUN


// Kodkommentar: Sätt hur många cykler som ska köras.
    cycles = 64'd60000000000;

    // Kodkommentar: Vänta på exakt angivet antal klockcykler.
    for (longint i = 0; i < cycles; i++) begin
        @(posedge clk);
    end

    //pulse_btn(single_cycle_btn); // arm another phase
    repeat (50) @(posedge clk);

    // HALT front-panel
    pulse_btn(halt_btn);

    repeat (20) @(posedge clk);
    $finish;
  end

  // Monitor when the CPU stops
  always @(negedge cpu.run_ff) begin
      // Report CPU status at halt
      $display("TIME %0t: CPU HALTED P=%06o IR=%06o TR=%06o A=%06o B=%06o",
              $time, cpu.P, cpu.IR, cpu.TR, cpu.A, cpu.B);

      if (cpu.P == 15'o000445) begin
          // Wait a little so the halt state can settle
          #1;

          // Load the value into the switch register
          sw <= 16'o177777;
          $display("TIME %0t: Loaded switch register with %06o", $time, sw);

          // Wait a little before pulsing the RUN button
          #1;

          // Start the CPU again
          pulse_btn(run_btn);
          $display("TIME %0t: Pulsed run button", $time);
      end else
      if (cpu.P == 15'o000452) begin
          // Wait a little so the halt state can settle
          #1;

          // Load the value into the switch register
          sw <= 16'o000000;
          $display("TIME %0t: Loaded switch register with %06o", $time, sw);

          // Wait a little before pulsing the RUN button
          #1;

          // Start the CPU again
          pulse_btn(run_btn);
          $display("TIME %0t: Pulsed run button", $time);
      end else
      if ((cpu.TR == 16'o102077) && (cpu.P == 15'o077237)) begin
          // Wait a little so the halt state can settle
          #1;

          // Load the value into the switch register
          pulse_btn(preset_btn);
          sw <= 16'o000100;
          pulse_btn(load_addr_btn);
          sw <= 16'o000000;
          saved_A <= cpu.A;
          pulse_btn(load_a_btn);
          pulse_btn(load_b_btn);
          pulse_btn(run_btn);
          $display("A=%06o", saved_A);
          if (saved_A == 16'o104003) sw <= 16'o000010;
          else if (saved_A == 16'o146200) sw <= 16'o000011;
          else if (saved_A == 16'o101220) sw <= 16'o000012;
          else if (saved_A == 16'o143300) sw <= 16'o000012; 
          else if (saved_A == 16'o101105) sw <= 16'o000012;
          else sw <= 16'o000000;
          $display("sw=%06o", sw);
          // Wait a little before pulsing the RUN button
          #1;

          // Start the CPU again
          pulse_btn(run_btn);
          $display("TIME %0t: Pulsed run button", $time);
      end
      else if ((cpu.TR == 16'o102077) && (cpu.P != 15'o077237)) begin
        #1;
        repeat (20) @(posedge clk);
        $display("Diag passed", $time);
        $finish;
      end else if (cpu.TR == 16'o102074) begin
        if (DSN == "101220") begin
          sw <= 16'o000400; 
        end if (DSN == "143300") begin
          sw <= 16'o006400; 
        end else begin
          sw <= 16'o000000; 
        end
        #1
        pulse_btn(run_btn);
        #1;
      end else if ((cpu.TR == 16'o102024) && (DSN=="104003")) begin 
        pulse_btn(preset_btn);
        #1
        pulse_btn(run_btn);
      end else if ((cpu.TR == 16'o102030) && (DSN=="104003")) begin 
        #1
        tty_start_capture();
        #1
        pulse_btn(run_btn);
        $display("TIME %0t: Started TTY capture and resumed CPU", $time);
      end else if ((cpu.TR == 16'o102031) && (DSN=="104003")) begin 
        #1
        pulse_btn(run_btn);
        #1
        tty_request_playback();
        $display("TIME %0t: Started TTY playback and resumed CPU", $time);
      end else if ((cpu.TR == 16'o102045) && (DSN=="104003")) begin 
        #1
        tty_stop_capture_and_rewind();
        #1
        pulse_btn(run_btn);
        #1
        $display("TIME %0t: Set punch OFF", $time);
      end else if ((cpu.TR == 16'o102046) && (DSN=="104003")) begin 
        #1
        tty_stop_playback();
        #1
        pulse_btn(run_btn);
        #1
        $display("TIME %0t: Set reader OFF", $time);
      end else if ((cpu.TR == 16'o102027) && (DSN=="101105")) begin 
        #1
        pulse_btn(preset_btn);
        #1
        $display("TIME %0t:Press PRESET BUTTON", $time);
        pulse_btn(run_btn);
        #1;
      end else if ((cpu.TR == 16'o107076) && (loadfile =="diagnostics/24185-60001_Rev-A.abin")) begin
        #1;
        sw <= 16'b0000111011000000;
        #1;
        pulse_btn(run_btn);
        #1;        
      end else if ((cpu.TR == 16'o107077) && (loadfile =="diagnostics/24185-60001_Rev-A.abin")) begin
        #1;
        sw <= 16'o000100; 
        #1;
        pulse_btn(load_addr_btn);
        #1;
        sw <= 16'o005101;
        #1
        pulse_btn(preset_btn);
        #1;
        pulse_btn(run_btn);
        #1;        
      end else if ((cpu.TR == 16'o103013) && (loadfile =="diagnostics/24185-60001_Rev-A.abin")) begin
        #1;
        sw <= 16'o000012;
        #1
        //pulse_btn(preset_btn);
        #1;
        pulse_btn(run_btn);
        #1;        
      end else if ((cpu.TR == 16'o103014) && (loadfile =="diagnostics/24185-60001_Rev-A.abin")) begin
        #1;
        sw <= 16'b0000111010000000;
        #1
        //pulse_btn(preset_btn);
        #1;
        pulse_btn(run_btn);
        #1;        
      end else begin
        $display("Diag failed", $time);
        $finish;
      end
  end

endmodule
