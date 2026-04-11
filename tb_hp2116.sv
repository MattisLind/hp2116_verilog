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
  logic [7:0] ptr_datain;
  logic [7:0] ptr_dataout;  
  logic ptr_feedhole;
  logic ptr_read; 

    // Kodkommentar: Filhandtag och temporärvariabel för pappersremsläsaren.
  integer ptr_fd;
  integer ptr_c;

  // Kodkommentar: Standardfil för pappersremsan. Kan överskuggas med +PTR_FILE=...
  string ptr_filename;   

  // CPU instance
  hp2116_cpu #(
  ) cpu (
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
    .uart_tx(uart_tx),
    .ptr_datain(ptr_datain),
    .ptr_dataout(ptr_dataout),  
    .ptr_feedhole(ptr_feedhole),
    .ptr_read(ptr_read)     
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
      bit_time = 400ns;

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
    ref  logic serial_line,
    output logic [7:0] data
  );
    time bit_time;
    int i;
    begin
      // Kodkommentar: Beräkna bittiden i ns utifrån vald baudrate.
      bit_time = 400ns;

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
    ref logic serial_line,
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


  // Kodkommentar: Mata in en byte till den simulerade pappersremsläsaren.
  // Kodkommentar: Datan görs stabil före feedhole och feedhole hålls aktiv över
  // Kodkommentar: en positiv klockkant så att DUT säkert latchar byten.
  task automatic ptr_feed_byte(input logic [7:0] value);
    begin
      ptr_datain = value;

      // Kodkommentar: Gör datan stabil före aktiv samplingskant.
      @(negedge clk);
      ptr_feedhole = 1'b1;

      // Kodkommentar: Håll feedhole aktiv över en positiv flank.
      @(negedge clk);
      ptr_feedhole = 1'b0;
    end
  endtask

  // ------------------------------------------------------------
  // Utility: drive a clean 1-cycle pulse for a button
  // ------------------------------------------------------------
  // Kodkommentar: Detta representerar en debouncad knapp (en ren puls).
  task automatic pulse_btn(ref logic btn);
    begin
      btn = 1'b1;
      @(posedge clk);   // DUT får sampla knappen här
      @(negedge clk);   // Vänta tills efter samplingskanten
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

        // Kodkommentar: Första shift/rotate-operationen från bitfält [8:6].
        if (tr[9]) begin
            part = fmt_rotate_shift(tr[8:6], tr[11]);
            result = append_part(result, part);
        end

        // Kodkommentar: CLE läggs till om bit 5 är satt.
        if (tr[5]) begin
            result = append_part(result, "CLE");
        end

        // Kodkommentar: SLA eller SLB läggs till om bit 3 är satt.
        if (tr[3]) begin
            if (tr[11])
                result = append_part(result, "SLB");
            else
                result = append_part(result, "SLA");
        end

        // Kodkommentar: Sista shift/rotate-operationen från bitfält [2:0].
        if (tr[4]) begin
            part = fmt_rotate_shift(tr[2:0], tr[11]);
            result = append_part(result, part);
        end

        // Kodkommentar: Om inget delkommando hittades, returnera en reservtext.
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
    endcase
    if (tr[5]) result = append_part(result, "SEZ");
    case (tr[7:6])
      2'o1: result = append_part(result, "CLE");
      2'o2: result = append_part(result, "CME");
      2'o3: result = append_part(result, "CCE");
    endcase 
    if (tr[4]) result = append_part(result, $sformatf("SS%s", acc));
    if (tr[3]) result = append_part(result, $sformatf("SL%s", acc));
    if (tr[2]) result = append_part(result, $sformatf("IN%s", acc)); 
    if (tr[1]) result = append_part(result, $sformatf("SZ%s", acc));
    if (tr[0]) result = append_part(result, "RSS");
    end
  return result;
endfunction

// Kodkommentar: Minimal första version av disassemblern.
// Kodkommentar: Disassembler med lokal operandsträng för minnesreferenser.
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


// Kodkommentar: Returnera en tom fastbreddssträng för icke-minnesreferensinstruktioner.
function automatic string blank_memref_info();
    return "                 ";  // 19 tecken: samma bredd som "M=001405 D=055555"
endfunction


// Kodkommentar: Avgör om instruktionen är en minnesreferensinstruktion.
function automatic logic is_memref_instr(input logic [15:0] tr);
    logic [5:0] ir;
    logic [3:0] op4;

    begin
        ir  = tr[15:10];
        op4 = ir[4:1];

        // Kodkommentar: Shift/rotate-grupp är inte minnesreferens.
        if ((ir[5:2] == 4'o00) && !ir[0])
            return 1'b0;

        // Kodkommentar: Alter/skip-grupp är inte minnesreferens.
        if ((ir[5:2] == 4'o00) && ir[0])
            return 1'b0;

        // Kodkommentar: I/O-grupp är inte minnesreferens.
        if ((ir[5:2] == 4'o10) && ir[0])
            return 1'b0;

        // Kodkommentar: MAC/övriga specialgrupper behandlas här som ej minnesreferens.
        if ((ir[5:2] == 4'o10) && !ir[0])
            return 1'b0;

        // Kodkommentar: Endast de riktiga minnesreferensinstruktionerna returnerar sant.
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


// Kodkommentar: Läs ett operandord på samma sätt som CPU:n gör i INDIRECT/EXECUTE T1.
// Kodkommentar: Adress 0 betyder A-register och adress 1 betyder B-register.
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


// Kodkommentar: Beräkna operandinformation för minnesreferensinstruktioner.
// Kodkommentar: Returnerar
// Kodkommentar:   "M=xxxxxx D=xxxxxx" för lyckad upplösning
// Kodkommentar:   "M=ERROR  D=ERROR " vid fel i indirektionskedjan
// Kodkommentar:   blanksträng för icke-minnesreferensinstruktioner
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
        // Kodkommentar: Returnera bara blankt fält om detta inte är en minnesreferensinstruktion.
        if (!is_memref_instr(tr))
            return blank_memref_info();

        // Kodkommentar: Plocka ut instruktionsfälten.
        indirect     = tr[15];
        current_page = tr[10];
        off10        = tr[9:0];

        // Kodkommentar: Samma direktadressregel som i CPU:n:
        // Kodkommentar: TR[10] = 1 => current page, annars zero page.
        if (current_page)
            eff_addr = {p_val[14:10], off10};
        else
            eff_addr = {5'b00000, off10};

        // Kodkommentar: Följ indirektionskedjan upp till 10 nivåer.
        for (level = 0; level < 10; level++) begin
            data_word = read_operand_word(eff_addr, a_val, b_val);

            // Kodkommentar: Om vi inte längre är indirekta är detta den slutliga operanden.
            if (!indirect)
                return $sformatf("M=%06o D=%06o", eff_addr, data_word);

            // Kodkommentar: Nästa länk i kedjan tas från det hämtade ordet.
            indirect = data_word[15];
            eff_addr = data_word[14:0];
        end

        // Kodkommentar: Om vi fortfarande är indirekta efter 10 nivåer betraktas det som fel.
        return "M=ERROR  D=ERROR ";
    end
endfunction

// Kodkommentar: Ta emot exakt en sträng från DUT över UART.
// Kodkommentar: Varje mottagen byte jämförs direkt mot förväntad text.
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


// Kodkommentar: Skicka en hel sträng till DUT över UART.
// Kodkommentar: Mellan varje tecken väntar vi en programmerbar extra fördröjning.
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

            // Kodkommentar: Extra paus mellan tecken om så önskas.
            if (inter_char_delay != 0)
                #(inter_char_delay);
        end
    end
endtask


// Kodkommentar: Vänta på en prompt från DUT och skicka sedan ett svar.
task automatic uart_expect_and_respond(
    ref logic dut_tx,
    ref logic tb_rx,
    input string expected_prompt,
    input string response,
    input time inter_char_delay,
    input time after_match_delay
);
    begin
        uart_expect_string(dut_tx, expected_prompt);
        if (after_match_delay != 0)
            #(after_match_delay);
        $display("UART sending response: \"%s\" at time %0t", response, $time);
        uart_send_string(tb_rx, response, inter_char_delay);
    end
endtask



initial begin
    // Kodkommentar: Vänta tills reset är släppt.
    wait (rst_n == 1'b1);

    // Kodkommentar: Första tomraden.
    // uart_expect_string(uart_tx, "\r\n");

    // Kodkommentar: Konfigurationsraden.
    // uart_expect_string(uart_tx, "2116, NO DMA, NO MPRT, 32K MEMORY\r\n");

    // Kodkommentar: Andra tomraden.
    // uart_expect_string(uart_tx, "\r\n");

    // Kodkommentar: Vänta på prompten och svara.
    // Kodkommentar: Exempelresponsen här är bara ett exempel — byt till det
    // Kodkommentar: exakt svar som diagnostikprogrammet förväntar sig.
    uart_expect_and_respond(
        uart_tx,
        uart_rx,
        "\r\n2116, NO DMA, NO MPRT, 32K MEMORY\r\n\r\nLINE PRINTER (NO.,SC)........",
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
        "101100\r",
        4_000ns,
        20_000ns
    );
    $display("Finished scripted UART exchange at time %0t", $time);
end


// Kodkommentar: Skriv ut disassembly-strängen med tydliga avgränsare
// Kodkommentar: så att dolda tecken blir lättare att upptäcka.
always @(posedge clk) begin
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


  // Kodkommentar: Simulerad HP12597A-pappersremsläsare som matar byten från fil.
  // Kodkommentar: När interfacet sätter READ aktivt läses nästa byte från filen
  // Kodkommentar: och FEEDHOLE pulsas så att interfacet latchar datan.
  initial begin : paper_tape_reader
    ptr_datain   = 8'h00;
    ptr_feedhole = 1'b0;

    // Kodkommentar: Tillåt att filnamnet skickas in som plusarg:
    // Kodkommentar:   +PTR_FILE=min_tape.bin
    if (!$value$plusargs("PTR_FILE=%s", ptr_filename))
      ptr_filename = "paper_tape.bin";

    ptr_fd = $fopen(ptr_filename, "rb");
    if (ptr_fd == 0) begin
      $display("PTR: no tape file opened (%s). Reader simulator disabled.", ptr_filename);
      disable paper_tape_reader;
    end

    $display("PTR: opened tape file %s", ptr_filename);

    forever begin
      // Kodkommentar: Vänta tills läsaren begär nästa tecken.
      @(posedge ptr_read);

      // Kodkommentar: Läs nästa byte ur värdfilen.
      ptr_c = $fgetc(ptr_fd);

      if (ptr_c < 0) begin
        $display("PTR: EOF on %s at time %0t", ptr_filename, $time);

        // Kodkommentar: Vid EOF matar vi inte fler byten.
        disable paper_tape_reader;
      end

      $display("PTR: byte %03o (0x%02h) at time %0t",
               ptr_c[7:0], ptr_c[7:0], $time);

      ptr_feed_byte(ptr_c[7:0]);
    end
  end

  // ------------------------------------------------------------
  // Test sequence demonstrating panel operations
  // ------------------------------------------------------------
  initial begin
    // Init
    rst_n = 1'b0;
    sw = 16'o000000;
    uart_rx = 1'b1;
    ptr_datain = 8'h00;
    ptr_feedhole = 1'b0;
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
    sw = 16'o000000;
    pulse_btn(load_a_btn);
    
    // LOAD B with switches
    sw = 16'o000000;
    pulse_btn(load_b_btn);    

   // Example: set address via switches and LOAD ADDRESS
    //sw = 16'o000002;  // run pre-test
    sw = 16'o000100;    // skip pre-test and go directly to configurator in conversational mode.
    pulse_btn(load_addr_btn);    
    sw = 16'o00010;
    // Enable single-cycle mode and do two phase-steps
    //pulse_btn(single_cycle_btn); // enter single mode + arm one phase
    pulse_btn(run_btn);          // RUN
    repeat (200000000) @(posedge clk);  // CPU will advance one phase and stop (armed consumed)

    //pulse_btn(single_cycle_btn); // arm another phase
    repeat (50) @(posedge clk);

    // HALT front-panel
    pulse_btn(halt_btn);

    repeat (20) @(posedge clk);
    $finish;
  end

  // Övervaka när CPU:n stannar
  always @(negedge cpu.run_ff) begin
      // Rapportera CPU-status vid halt
      $display("TIME %0t: CPU HALTED P=%06o IR=%06o TR=%06o A=%06o B=%06o",
              $time, cpu.P, cpu.IR, cpu.TR, cpu.A, cpu.B);

      if (cpu.P == 16'o000445) begin
          // Vänta lite så att haltläget hinner stabiliseras
          #1;

          // Lägg in värdet i switchregistret
          sw = 16'o177777;
          $display("TIME %0t: Loaded switch register with %06o", $time, sw);

          // Vänta lite innan run-knappen pulsas
          #1;

          // Starta CPU:n igen
          pulse_btn(run_btn);
          $display("TIME %0t: Pulsed run button", $time);
      end
      if (cpu.P == 16'o000452) begin
          // Vänta lite så att haltläget hinner stabiliseras
          #1;

          // Lägg in värdet i switchregistret
          sw = 16'o000000;
          $display("TIME %0t: Loaded switch register with %06o", $time, sw);

          // Vänta lite innan run-knappen pulsas
          #1;

          // Starta CPU:n igen
          pulse_btn(run_btn);
          $display("TIME %0t: Pulsed run button", $time);
      end 
      if (cpu.P == 16'o077237) begin
          // Vänta lite så att haltläget hinner stabiliseras
          #1;

          // Lägg in värdet i switchregistret
          pulse_btn(preset_btn);
          sw = 16'o000100;
          pulse_btn(load_addr_btn);
          sw = 16'o000000;
          pulse_btn(load_a_btn);
          pulse_btn(load_b_btn);
          pulse_btn(run_btn);

          // Vänta lite innan run-knappen pulsas
          #1;

          // Starta CPU:n igen
          pulse_btn(run_btn);
          $display("TIME %0t: Pulsed run button", $time);
      end            
  end

endmodule
