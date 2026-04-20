`timescale 1ns/1ps

module hp12566b #(
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
  input  logic [15:0]  datain,
  output logic [15:0]  dataout,
  output logic         command,
  input  logic         flag,
  // Device command signal. 
  // Position A: Ground True command signal
  // Position B: Positive True command signal
  // Position C: Pulsed ground true signal
  input  string        jumper_w1,  
   // Device command ff. 
   // Position A: Device Command FF clears on the positive-going edge of Device Flag signal.
   // Position B: Device Command FF clears on the negative-going edge of Device Flag signal.
   // Position C: ENF signal clears Device Command FF.
  input  string        jumper_w2,
  // DEVICE FLAG SIGNAL
  // Position A: Sets the Flag Buffer FF and strobes input data on the positive-going edge.  
  // Position B: Sets the Flag Buffer FF and strobes input data on the negative-going edge.
  input  string        jumper_w3,
  // OUTPUT DATA REGISTER
  // Position A: Output data is gated by the Data FF
  // Position B: Output data is continuously available to the 1/0 device 
  input  string        jumper_w4,
  // INPUT DATA REGISTER
  // Position IN: Device Flag signal latches listed bits of the input data register. 
  // Position OUT: Listed bits of the input data register follow the input lines from the 1/O device.
  input  string        jumper_w5,
  input  string        jumper_w6,
  input  string        jumper_w7,
  input  string        jumper_w8,
  // DEVICE COMMAND FF
  // Position A: Allows the CLC, CRS, and Device Flag signals to clear the Device Command FF.
  // Position B: Allows only the CRS and Device Flag signals to clear the Device Command FF. This action is required for DMA operations.
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
  logic        inout_ff;
  logic        print_ff;
  logic        punch_ff;
  logic        irq_ff;
  logic        command_ff;
  logic        data_ff;
  logic        party_line_ff;
  logic [15:0]  dataoutreg;
  logic [15:0]  datainreg;
  logic        flag_conditioned;
  logic        flag_d;
  
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

    prl  = prh & ~(flag_ff & ien & control_ff);
    iob_in = 16'h0000;
    if (do_ioi) iob_in [15:0] = datainreg;

    if (jumper_w1 == "A") command = ~command_ff;
    else if (jumper_w1 == "B") command = command_ff;
    else if (jumper_w1 == "C") command = ~party_line_ff;
    // jumper W1 in position C is not yet supported.
    if (jumper_w2 == "A") flag_conditioned = flag;
    else if (jumper_w2 == "B") flag_conditioned = ~flag;
    else if (jumper_w2 == "C") flag_conditioned = enf;

    if (jumper_w4 == "A") begin
      if (~data_ff) dataout = dataoutreg;  
    end else begin
      dataout = dataoutreg; 
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
      command_ff <= 1'b0;
      party_line_ff <= 1'b0;
      data_ff <= 1'b0;
      flag_d <= 1'b0;
      end else begin
        //--------------------------------------------------------------------
        // Simple flip-flop controls
        //--------------------------------------------------------------------

        flag_d <= flag;

        // flag buffer flip/flop
        if (do_clf |  (iak & irq_ff)) flag_buffer_ff <= 1'b0;
        else if (do_stf | ((((jumper_w3 == "A") && (flag & ~flag_d)) || ((jumper_w3 == "B") && (~flag & flag_d))) & ~flag_ff)) flag_buffer_ff <= 1'b1;

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
        if (((do_clc | crs) & (jumper_w9 =="A")) | ((jumper_w9 =="B") & crs) | flag_conditioned ) command_ff <= 1'b0;
        else if (do_stc) command_ff <= 1'b1;

        // data flip/flop
        if (do_stc) data_ff <= 1'b1;
        else if (sir && ~command_ff) data_ff <= 1'b0;

        // party line flip/flop
        if (sir & command_ff) party_line_ff <= 1'b1;
        else if (t3) party_line_ff <= 1'b0;

        if (do_ioo) dataoutreg <= iob_out[15:0];
         
        if (jumper_w5 == "IN") begin
          if (((jumper_w3 == "A") && flag) || ((jumper_w3 == "B") && ~flag)) begin
            datainreg[3:0] <= datain[3:0];
          end  
        end else datainreg[3:0] <= datain[3:0];
        if (jumper_w6 == "IN") begin
          if (((jumper_w3 == "A") && flag) || ((jumper_w3 == "B") && ~flag)) begin
            datainreg[7:4] <= datain[7:4];
          end  
        end else datainreg[7:4] <= datain[7:4];
        if (jumper_w7 == "IN") begin
          if (((jumper_w3 == "A") && flag) || ((jumper_w3 == "B") && ~flag)) begin
            datainreg[11:8] <= datain[11:8];
          end  
        end else datainreg[11:8] <= datain[11:8];
        if (jumper_w7 == "IN") begin
          if (((jumper_w3 == "A") && flag) || ((jumper_w3 == "B") && ~flag)) begin
            datainreg[15:12] <= datain[15:12]; 
          end  
        end else datainreg[15:12] <= datain[15:12]; 

      end
    end

endmodule
