`timescale 1ns/1ps

module hp12531c #(
) (
  input  logic         clk,
  input  logic         crs,

  // Priority and flag chain toward the backplane.
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

  // Select code for the lower address half. These are used by the interface.
  input  logic         scm_l,
  input  logic         scl_l,

  input  logic         iog,
  input  logic         popio,

  // Special signal from the bus sheet. Not used in this first model.
  input  logic         iob16_or_bios_n,

  output logic         srq,
  input  logic         ioo,
  input  logic         clc,
  input  logic         stc,
  input  logic         prh,
  input  logic         ioi,
  input  logic         sfs,

  // The higher select code is not used by the interface but is present on the connector.
  output logic         irqh,
  input  logic         scl_h,
  input  logic         scm_h,

  input  logic [15:0]  iob_out,
  output logic [15:0]  iob_in,

  input  logic         sir,
  input  logic         enf,
  output logic         flgh,

  input  logic         run,

  input  logic         edt,
  input  logic         pon,
  input  logic         bioo_n,
  input  logic         sfsb_or_bioi_n,
  input  logic         uart_rx,
  output logic         uart_tx,
  output logic         read_command
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
    // The 12531C uses only the lower select code.
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
    // In this first model only the lower flag line is driven.
    flgl = irq_ff;
    flgh = 1'b0;
    irqh = 1'b0;
    // The skip line is driven only when the card is selected.
    skf  = (do_sfs && flag_ff) || (do_sfc && !flag_ff);

    // Service request / interrupt request from the card.
    srq  = flag_ff;
    irql = irq_ff;

    prl  = prh & ~(flag_ff & ien & control_ff);


    serial_in_or_flag = uart_rx | flag_ff;
    read_command = read_ff;
  end

    // Map the old step names onto the synchronous counter
    assign A = phase_cnt[0];
    assign B = phase_cnt[1];
    assign C = phase_cnt[2];
    assign D = phase_cnt[3];
    assign E = phase_cnt[4];
    assign F = phase_cnt[5];
    assign G = phase_cnt[6];

    // The IN clock comes from Q on step C.
    // That corresponds to a pulse when C goes 0->1.
    // In a synchronous counter this happens when the previous lowest three bits are 011.
    assign in_phase_hit = (phase_cnt[2:0] == 3'b011);

    // The OUT clock comes from /Q on step C.
    // That corresponds to a pulse when /C goes 0->1, meaning C goes 1->0.
    // In a synchronous counter this happens when the previous lowest three bits are 111.
    assign out_phase_hit = (phase_cnt[2:0] == 3'b111);

    // Stop condition from the old logic: when D, E, and G are true, the chain resets.
    // In the synchronous version the sequence stops and the phase counter is reset.
    assign stop_condition = E && G;

    assign shift_enable = ((inout_ff && in_phase_hit) || (~inout_ff && out_phase_hit));

    assign iob_in[7:0] = do_ioi ? shift_reg[9:2] : 8'h00;
    assign iob_in[14:8] = 7'h00;
    assign iob_in[15] = clock_enable_ff & do_ioi;
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
        if (enf) irq_ff <= 1'b0;
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

        if (do_ioo & t3) shift_reg[10] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[10] <= serial_in_or_flag;

        if (do_ioo & t3) shift_reg[9] <= 1'b0;
        else if (iob_out[7] & do_ioo) shift_reg[9] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[9] <= shift_reg[10];

        if (do_ioo & t3) shift_reg[8] <= 1'b0;
        else if (iob_out[6] & do_ioo) shift_reg[8] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[8] <= shift_reg[9];

        if (do_ioo & t3) shift_reg[7] <= 1'b0;
        else if (iob_out[5] & do_ioo) shift_reg[7] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[7] <= shift_reg[8];

        if (do_ioo & t3) shift_reg[6] <= 1'b0;
        else if (iob_out[4] & do_ioo) shift_reg[6] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[6] <= shift_reg[7];

        if (do_ioo & t3) shift_reg[5] <= 1'b0;
        else if (iob_out[3] & do_ioo) shift_reg[5] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[5] <= shift_reg[6];

        if (do_ioo & t3) shift_reg[4] <= 1'b0;
        else if (iob_out[2] & do_ioo) shift_reg[4] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[4] <= shift_reg[5];

        if (do_ioo & t3) shift_reg[3] <= 1'b0;
        else if (iob_out[1] & do_ioo) shift_reg[3] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[3] <= shift_reg[4];

        if (do_ioo & t3) shift_reg[2] <= 1'b0;
        else if (iob_out[0] & do_ioo) shift_reg[2] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[2] <= shift_reg[3];

        if (~clock_enable_ff) shift_reg[1] <= 1'b0;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[1] <= shift_reg[2];

        if (~clock_enable_ff) shift_reg[0] <= 1'b1;
        else if (shift_enable & baudrategen_clock_enable) shift_reg[0] <= shift_reg[1];

      end
    end

endmodule
