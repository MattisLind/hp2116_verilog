`timescale 1ns/1ps

module tb_hp12531c;

  // Kodkommentar: Testbench-parametrar som skickas vidare till DUT.
  localparam int unsigned CLOCK_HZ  = 50_000_000;
  localparam int unsigned BAUD      = 1_250_000;
  localparam int unsigned STOP_BITS = 2;

  // Kodkommentar: Klockperiod i ns för 50 MHz.
  localparam time CLK_PERIOD = 20ns;

  // Kodkommentar: DUT-ingångar.
  logic         clk;
  logic         crs;

  logic         sfc;
  logic         clf;
  logic         ien;
  logic         stf;
  logic         iak;
  logic         t3;

  logic         scm_l;
  logic         scl_l;

  logic         iog;
  logic         popio;

  logic         iob16_or_bios_n;

  logic         ioo;
  logic         clc;
  logic         stc;
  logic         prh;
  logic         ioi;
  logic         sfs;

  logic         irqh;
  logic         scl_h;
  logic         scm_h;

  logic [15:0]  iob_out;

  logic         sir;
  logic         enf;
  logic         pon;
  logic         bioo_n;
  logic         sfsb_or_bioi_n;

  // Kodkommentar: DUT-utgångar.
  logic         prl;
  logic         flgl;
  logic         irql;
  logic         skf;
  logic         srq;
  logic [15:0]  iob_in;
  logic         flgh;
  logic         edt;

  // Kodkommentar: Inout-signalen modelleras med tri/state-ansats i testbänk.
  tri           run;

  // Kodkommentar: Om testbänken ibland ska driva 'run' används separat drivsignal.
  logic         run_drv_en;
  logic         run_drv_val;


  // Kodkommentar: Separata UART-signaler för hostif-test.
  //logic hostif_serial_in;
  //logic hostif_serial_out;

  /*hostif #(
    .CLOCK_HZ(CLOCK_HZ),
    .BAUD(BAUD),
    .STOP_BITS(STOP_BITS)
  ) hostif_inst (
    .clk(clk),
    .crs(crs),
    .serial_in(hostif_serial_in),
    .serial_out(hostif_serial_out)
  );*/


  // Kodkommentar: Driv 'run' bara när enable är aktiv, annars högimpedans.
  assign run = run_drv_en ? run_drv_val : 1'bz;

  // Kodkommentar: Instans av DUT.
  hp12531c #(
    .CLOCK_HZ(CLOCK_HZ),
    .BAUD(BAUD),
    .STOP_BITS(STOP_BITS)
  ) dut (
    .clk(clk),
    .crs(crs),

    .prl(prl),
    .flgl(flgl),
    .sfc(sfc),
    .irql(irql),
    .clf(clf),
    .ien(ien),
    .stf(stf),
    .iak(iak),
    .t3(t3),
    .skf(skf),

    .scm_l(scm_l),
    .scl_l(scl_l),

    .iog(iog),
    .popio(popio),

    .iob16_or_bios_n(iob16_or_bios_n),

    .srq(srq),
    .ioo(ioo),
    .clc(clc),
    .stc(stc),
    .prh(prh),
    .ioi(ioi),
    .sfs(sfs),

    .irqh(irqh),
    .scl_h(scl_h),
    .scm_h(scm_h),

    .iob_out(iob_out),
    .iob_in(iob_in),

    .sir(sir),
    .enf(enf),
    .flgh(flgh),

    .run(run),

    .edt(edt),
    .pon(pon),
    .bioo_n(bioo_n),
    .sfsb_or_bioi_n(sfsb_or_bioi_n)
  );

  // Kodkommentar: Klockgenerator.
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD/2) clk = ~clk;
  end


  initial begin
    $dumpfile("tb_hp12531c.vcd");
    @(negedge crs);
    $dumpvars(0, tb_hp12531c);
  end


    // Kodkommentar: Skicka en UART-byte till hostif via hostif_serial_out.
  // Format: 1 startbit, 8 databitar, STOP_BITS stoppbitar, ingen paritet.
  task automatic uart_send_byte(input logic [7:0] data, ref logic output_signal);
    time bit_time;
    int i;
    begin
      // Kodkommentar: Beräkna bittiden i ns utifrån BAUD.
      bit_time = 1_000_000_000ns / BAUD;

      // Kodkommentar: Idle-nivån för UART är hög.
      output_signal = 1'b1;
      #(bit_time);

      // Kodkommentar: Startbit.
      output_signal = 1'b0;
      #(bit_time);

      // Kodkommentar: Skicka databitar LSB först.
      for (i = 0; i < 8; i++) begin
        output_signal = data[i];
        #(bit_time);
      end

      // Kodkommentar: Skicka stoppbitar.
      repeat (STOP_BITS) begin
        output_signal = 1'b1;
        #(bit_time);
      end
    end
  endtask


  // Kodkommentar: Grundläggande initiering av alla insignaler.
  task automatic init_signals();
    begin
      crs               = 1'b0;
      //hostif_serial_out  = 1'b1;
      sfc               = 1'b0;
      clf               = 1'b0;
      ien               = 1'b0;
      stf               = 1'b0;
      iak               = 1'b0;
      //t3                = 1'b0;

      scm_l             = 1'b0;
      scl_l             = 1'b0;

      iog               = 1'b0;
      popio             = 1'b0;

      iob16_or_bios_n   = 1'b1;

      ioo               = 1'b0;
      clc               = 1'b0;
      stc               = 1'b0;
      prh               = 1'b0;
      ioi               = 1'b0;
      sfs               = 1'b0;

      irqh              = 1'b0;
      scl_h             = 1'b0;
      scm_h             = 1'b0;

      iob_out           = 16'h0000;

      //sir               = 1'b0;
      //enf               = 1'b0;
      pon               = 1'b0;
      bioo_n            = 1'b1;
      sfsb_or_bioi_n    = 1'b1;

      run_drv_en        = 1'b0;
      run_drv_val       = 1'b0;
    end
  endtask

  // Kodkommentar: Enkel reset-/power-on-sekvens. Anpassa efter DUT:s verkliga beteende.
  task automatic do_power_on_reset();
    begin
      pon = 1'b1;
      crs = 1'b1;
      repeat (5) @(posedge clk);

      pon = 1'b0;
      crs = 1'b0;
      repeat (5) @(posedge clk);
    end
  endtask

  // Kodkommentar: Hjälptask för att pulsera en signal i en klockcykel.
  task automatic pulse_1clk(ref logic sig);
    begin
      sig = 1'b1;
      @(posedge clk);
      sig = 1'b0;
    end
  endtask

task output_on_bus(input int value);
    @(posedge clk);
    scm_l = 1'b1;
    scl_l = 1'b1;
    ioo = 1'b1;
    iog = 1'b1;
    iob_out = value;
    @(posedge clk);
    iog = 1'b0;
    ioo = 1'b0;
    scm_l = 1'b0;
    scl_l = 1'b0;
endtask

task pulse_a_signal(ref logic sig);
    @(posedge clk);
    scm_l = 1'b1;
    scl_l = 1'b1;
    iog = 1'b1;
    sig = 1'b1;
    @(posedge clk);
    iog = 1'b0;
    scm_l = 1'b0;
    scl_l = 1'b0;
    sig = 1'b0;
endtask

  // Kodkommentar: Exempel på enkel stimulussekvens.
  initial begin
    init_signals();

    // Kodkommentar: Vänta lite innan resetsekvens.
    repeat (2) @(posedge clk);

    do_power_on_reset();

        // Kodkommentar: Vänta lite efter reset innan UART-testet börjar.
    repeat (10) @(posedge clk);

    // Kodkommentar: Skicka ASCII 'A' till hostif så att den skrivs ut via DPI-C.
    //uart_send_byte(8'h41, hostif_serial_out);

    // Kodkommentar: Vänta lite så att hostif hinner ta emot klart innan simuleringen avslutas.
    //repeat (100) @(posedge clk);

    // Kodkommentar: Exempel på några styrpulser.
    //pulse_1clk(clf);
    //pulse_1clk(stf);
    //pulse_1clk(stc);
    //pulse_1clk(clc);

    // Kodkommentar: Exempel på bussdata in till DUT.
    @(posedge clk);

    // Kodkommentar: Exempel på att välja nedre select code.
    output_on_bus(16'o110000);
    output_on_bus(16'h0042);
    pulse_a_signal(clf);
    pulse_a_signal(stc);

    repeat (460) @(posedge clk);
    //pulse_1clk(sir);
    repeat (20) @(posedge clk);
    output_on_bus(16'o160000);
    pulse_a_signal(clf);
    pulse_a_signal(stc);    
    // Kodkommentar: Exempel på att driva inout-signalen 'run' från testbänken.
    //run_drv_en  = 1'b1;
    //run_drv_val = 1'b1;
    @(posedge clk);
    //run_drv_en  = 1'b0;

    // Kodkommentar: Låt simuleringen gå några cykler.
    repeat (20) @(posedge clk);


    repeat (2000) @(posedge clk);
    $finish;
  end


// This block runs forever, independent of others
initial begin
    // Kodkommentar: Definierade startvärden för automatiska styrsignaler.
    sir = 1'b0;
    t3  = 1'b0;
    enf = 1'b0;

    // Kodkommentar: Vänta tills reset och första programmeringen är klar.
    @(negedge crs);
    repeat (2) @(posedge clk);

    forever begin
        repeat (2) @(posedge clk);
        enf = 1'b1;
        @(posedge clk);
        enf = 1'b0;

        repeat (2) @(posedge clk);
        t3 = 1'b1;
        @(posedge clk);
        t3 = 1'b0;

        repeat (4) @(posedge clk);
        sir = 1'b1;
        @(posedge clk);
        sir = 1'b0;
    end
end
  // Kodkommentar: Valfri monitor för snabb felsökning.
  // initial begin
  //  $display("Time      clk crs pon stf clf stc clc | prl flgl irql skf srq flgh edt run iob_in");
  //  $monitor("%0t  %0b   %0b   %0b   %0b   %0b   %0b   %0b  |  %0b    %0b    %0b   %0b   %0b   %0b   %0b   %0b   %h",
  //           $time, clk, crs, pon, stf, clf, stc, clc,
  //           prl, flgl, irql, skf, srq, flgh, edt, run, iob_in);
  //end

endmodule
