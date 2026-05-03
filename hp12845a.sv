`timescale 1ns/1ps

module hp12845a #(
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
  output logic [6:0]   dataoutreg,
  output logic         controlbit,
  output logic         information_ready,
  output logic         master_reset,
  input  logic         output_resume,
  input  logic         line_ready,
  input  logic         paper_out,
  input  logic         ready,
  input  string        jumper_w1,  
  input  string        jumper_w2,
  input  string        jumper_w3,
  input  string        jumper_w4,
  input  string        jumper_w5,
  input  string        jumper_w6,
  input  string        jumper_w7,
  input  string        jumper_w8,
  input  string        jumper_w9
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
  logic        irq_ff;
  logic        information_ready_ff;
  logic        ready_ff;
  logic        paper_out_ff;

  logic        controlbit_ff;
  logic        enf_delayed;
  logic        combined_ready;
  logic        command_ack;
  logic        command_ack_delayed;
  logic        line_ready_ff;
  
  always_comb begin
    // The 12597A uses only the lower select code.
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

    prl  = prh & ~(flag_ff & ien & control_ff & ( (jumper_w1 == "IN") | ~ien ) );
    iob_in = 16'h0000;
    if (do_ioi) iob_in[15] = ready_ff;
    if (do_ioi) iob_in[14] = paper_out_ff;
    if (do_ioi) iob_in[0] = line_ready_ff;
    controlbit = controlbit_ff;
    information_ready = information_ready_ff;
    master_reset = crs;
    if (jumper_w7 == "IN") begin
      combined_ready = ( ~line_ready | output_resume);
      command_ack = combined_ready;
    end
    else begin
      command_ack = ~output_resume;
      combined_ready = ~line_ready;
    end
  end

  //--------------------------------------------------------------------------
  // Main sequential logic
  //--------------------------------------------------------------------------
  always_ff @(posedge clk or popio) begin
    if (popio) begin
      flag_ff       <= 1'b0;
      flag_buffer_ff <= 1'b1;
      irq_ff        <= 1'b0;
      control_ff    <= 1'b0;
      information_ready_ff <= 1'b0;
      ready_ff <= 1'b0;
      paper_out_ff <= 1'b0;
      line_ready_ff <= 1'b0;
      end else begin
        //--------------------------------------------------------------------
        // Simple flip-flop controls
        //--------------------------------------------------------------------

        enf_delayed <= enf;


        // flag buffer flip/flop
        if (do_clf |  (iak & irq_ff)) flag_buffer_ff <= 1'b0;
        else if (do_stf | ((~command_ack & command_ack_delayed) & ~flag_ff)) flag_buffer_ff <= 1'b1;

        // flag flip/flop
        if (flag_buffer_ff & enf) flag_ff <= 1'b1;
        else if (do_clf) flag_ff <= 1'b0;

        // irq flip/flop
        if (sir & prh & flag_buffer_ff & ien & flag_ff & control_ff) irq_ff <= 1'b1;
        else if (enf) irq_ff <= 1'b0;
        // control flip/flip
        if (do_clc | crs) control_ff <= 1'b0;
        else if (do_stc) control_ff <= 1'b1;
        // command flip/flop
        if ((do_clc && (jumper_w5 == "IN"))| crs | ((jumper_w6 == "IN") & (command_ack & ~command_ack_delayed) )  ) information_ready_ff <= 1'b0;
        else if (do_stc) information_ready_ff <= 1'b1;

        if (do_ioo) dataoutreg <= iob_out[6:0];
        if (do_ioo) controlbit_ff <= iob_out[15]; 

        if (~enf & enf_delayed) begin
          ready_ff <= ready;
          paper_out_ff <= paper_out;
          line_ready_ff <= (jumper_w8 =="IN")?~command_ack : 1'b1;
        end
        command_ack_delayed <=  command_ack;

      end
    end

endmodule
