`timescale 1ns/1ps

module hp12531c #(
  parameter int unsigned CLOCK_HZ  = 50_000_000,
  parameter int unsigned BAUD      = 1_250_000,
  parameter int unsigned STOP_BITS = 2
) (
  input  logic         clk,
  input  logic         crs,

  // Kodkommentar: Prioritets- och flaggkedja mot bakplanet.
  output logic         prl,
  output logic         flgl,
  input  logic         sfc,
  output logic         irql,
  input  logic         clf,
  input  logic         ien,
  input  logic         stf,
  input  logic         iak,
  input  logic         t3,
  output logic         skf,

  // Kodkommentar: Select code för nedre adresshalvan. 12531C använder dessa.
  input  logic         scm_l,
  input  logic         scl_l,

  input  logic         iog,
  input  logic         popio,

  // Kodkommentar: Specialsignal från bussarket. Används inte i denna första modell.
  input  logic         iob16_or_bios_n,

  output logic         srq,
  input  logic         ioo,
  input  logic         clc,
  input  logic         stc,
  input  logic         prh,
  input  logic         ioi,
  input  logic         sfs,

  // Kodkommentar: Högre select code används inte av 12531C men finns i kontakten.
  input  logic         irqh,
  input  logic         scl_h,
  input  logic         scm_h,

  input  logic [15:0]  iob_out,
  output logic [15:0]  iob_in,

  input  logic         sir,
  input  logic         enf,
  output logic         flgh,

  input  logic         run,

  output logic         edt,
  input  logic         pon,
  input  logic         bioo_n,
  input  logic         sfsb_or_bioi_n,
  input  logic         uart_rx,
  output logic         uart_tx  
);

  //--------------------------------------------------------------------------
  // Selection / decoded local strobes
  //--------------------------------------------------------------------------
  logic sel_l;
  logic do_ioi;
  logic do_ioo;
  logic do_stc;
  logic do_clc;
  logic do_clf;
  logic do_stf;
  logic do_sfs;
  logic do_sfc;

  //--------------------------------------------------------------------------
  // Internal state
  //--------------------------------------------------------------------------
  logic        flag_ff;
  logic        flag_buffer_ff;
  logic        control_ff;
  logic        inout_ff;      
  logic        print_ff;
  logic        punch_ff;
  logic        irq_ff;
  logic        clock_enable_ff;
  logic        counter_reset_ff;
  logic        read_ff;
  logic        serial_in_or_flag;
  logic [12:0] baudrategen;
  logic A, B, C, D, E, F, G;

  logic [6:0]   phase_cnt;
  logic [10:0]  shift_reg;
  logic in_phase_hit;
  logic out_phase_hit;  
  logic stop_condition;  
  logic  shift_enable;
  logic baudrategen_clock_enable;


  always_comb begin
    // Kodkommentar: 12531C använder endast nedre select code.
    sel_l  = iog && scm_l && scl_l;

    do_ioi = sel_l && ioi;
    do_ioo = sel_l && ioo;
    do_stc = sel_l && stc;
    do_clc = sel_l && clc;
    do_clf = sel_l && clf;
    do_stf = sel_l && stf;
    do_sfs = sel_l && sfs;
    do_sfc = sel_l && sfc;
  end


  //--------------------------------------------------------------------------
  // Backplane outputs
  //--------------------------------------------------------------------------
  always_comb begin
    // Kodkommentar: I denna första modell driver vi bara lägre flagglinje.
    flgl = irq_ff;
    flgh = 1'b0;

    // Kodkommentar: Skip-ledningen drivs endast när kortet är valt.
    skf  = (do_sfs && flag_ff) || (do_sfc && !flag_ff);

    // Kodkommentar: Service request / interrupt request från kortet.
    srq  = flag_ff;
    irql = irq_ff;

    prl  = prh & ~(flag_ff & ien & control_ff);



    // Kodkommentar: EDT används inte i denna modell.
    edt  = 1'b0;

    serial_in_or_flag = uart_rx | flag_ff;

  end

    // Koppla ut de gamla stegnamnen till den synkrona räknaren
    assign A = phase_cnt[0];
    assign B = phase_cnt[1];
    assign C = phase_cnt[2];
    assign D = phase_cnt[3];
    assign E = phase_cnt[4];
    assign F = phase_cnt[5];
    assign G = phase_cnt[6];


    // IN-klockan kommer från Q på steg C.
    // Det motsvarar en puls när C går 0->1.
    // I en synkron räknare händer det när de gamla lägsta tre bitarna är 011.
    assign in_phase_hit = (phase_cnt[2:0] == 3'b011);

    // OUT-klockan kommer från /Q på steg C.
    // Det motsvarar en puls när /C går 0->1, alltså när C går 1->0.
    // I en synkron räknare händer det när de gamla lägsta tre bitarna är 111.
    assign out_phase_hit = (phase_cnt[2:0] == 3'b111);

    // Stoppvillkor från gamla logiken: när D, E och G är sanna ska kedjan resetas.
    // I den synkrona versionen stoppar vi sekvensen och återställer fasräknaren.
    assign stop_condition = D && E && G;

    assign shift_enable = ((inout_ff && in_phase_hit) || (~inout_ff && out_phase_hit));

    assign iob_in[7:0] = shift_reg[8:1];
    assign iob_in[14:8] = 7'h00;
    assign iob_in[15] = clock_enable_ff;
    assign baudrategen_clock_enable = (baudrategen == 13'd4);

    assign uart_tx = ~ ((~shift_reg[0] & ~inout_ff & (print_ff | punch_ff)) | (~serial_in_or_flag & (print_ff | punch_ff) & inout_ff));

  //--------------------------------------------------------------------------
  // Main sequential logic
  //--------------------------------------------------------------------------
  always_ff @(posedge clk or posedge crs) begin
    if (crs) begin
      flag_ff       <= 1'b0;
      flag_buffer_ff <= 1'b1;
      irq_ff        <= 1'b0;
      control_ff    <= 1'b0;
      inout_ff      <= 1'b1;
      print_ff      <= 1'b0;
      punch_ff      <= 1'b0;
      read_ff       <= 1'b0;
      phase_cnt     <= 7'd0;
      shift_reg     <= '0;
      clock_enable_ff <= 1'b0;
      counter_reset_ff <= 1'b0;
      baudrategen <= 13'd0;

      end else begin
        //--------------------------------------------------------------------
        // Simple flip-flop controls
        //--------------------------------------------------------------------
        // flag buffer flip/flop
        if (do_clf |  (iak & irq_ff)) flag_buffer_ff <= 1'b0;
        else if (popio | do_stf | (~counter_reset_ff & sir)) flag_buffer_ff <= 1'b1;

        // flag flip/flop
        if (flag_buffer_ff & enf) flag_ff <= 1'b1;
        if (do_clf) flag_ff <= 1'b0;

        // irq flip/flop
        if (sir & prh & flag_ff & ien & control_ff & flag_buffer_ff) irq_ff <= 1'b1;
        if (~enf) irq_ff <= 1'b0;
        // control flip/flip
        if (do_clc) control_ff <= 1'b0;
        if (do_stc) control_ff <= 1'b1;


        if (do_ioo & iob_out[15]) inout_ff <= iob_out[14];
        if (do_ioo & iob_out[15]) print_ff <= iob_out[13];
        if (do_ioo & iob_out[15]) punch_ff <= iob_out[12];


        if (stop_condition & t3) counter_reset_ff <= 1'b0;
        else if (enf) counter_reset_ff <= 1'b1;

        if (~counter_reset_ff & sir) begin
            phase_cnt <= 7'd0;
        end else if (clock_enable_ff & baudrategen_clock_enable) begin
            phase_cnt <= phase_cnt + 7'd1;
        end

        if (baudrategen_clock_enable) baudrategen <= 13'd0;    
        else baudrategen <= baudrategen + 13'd1;

        if ((do_stc & ~inout_ff) || (~serial_in_or_flag & inout_ff)) clock_enable_ff <= 1'b1;
        else if (~counter_reset_ff & sir) clock_enable_ff <= 1'b0;

        if (do_stc & inout_ff) read_ff <= 1'b1;
        else if (~uart_rx) read_ff <= 1'b0;

        if (ioo & t3) shift_reg[10] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[10] <= serial_in_or_flag;

        if (ioo & t3) shift_reg[9] <= 1'b0;
        else if (iob_out[7] & ioo) shift_reg[9] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[9] <= shift_reg[10];

        if (ioo & t3) shift_reg[8] <= 1'b0;
        else if (iob_out[6] & ioo) shift_reg[8] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[8] <= shift_reg[9];

        if (ioo & t3) shift_reg[7] <= 1'b0;
        else if (iob_out[5] & ioo) shift_reg[7] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[7] <= shift_reg[8];            

        if (ioo & t3) shift_reg[6] <= 1'b0;
        else if (iob_out[4] & ioo) shift_reg[6] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[6] <= shift_reg[7];            

        if (ioo & t3) shift_reg[5] <= 1'b0;
        else if (iob_out[3] & ioo) shift_reg[5] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[5] <= shift_reg[6]; 

        if (ioo & t3) shift_reg[4] <= 1'b0;
        else if (iob_out[2] & ioo) shift_reg[4] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[4] <= shift_reg[5]; 

        if (ioo & t3) shift_reg[3] <= 1'b0;
        else if (iob_out[1] & ioo) shift_reg[3] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[3] <= shift_reg[4];   

        if (ioo & t3) shift_reg[2] <= 1'b0;
        else if (iob_out[0] & ioo) shift_reg[2] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[2] <= shift_reg[3];  

        if (~clock_enable_ff) shift_reg[1] <= 1'b0;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[1] <= shift_reg[2];  

        if (~clock_enable_ff) shift_reg[0] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[0] <= shift_reg[1]; 

      end
    end

endmodule
