`timescale 1ns/1ps

module hp12597a #(
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
  input  logic [7:0]   datain,
  output logic [7:0]   dataout,  
  input  logic         feedhole,
  output logic         read

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
  logic [7:0]  dataoutreg;
  logic [7:0]  datainreg;



  always_comb begin
    // Kodkommentar: 12597A använder endast nedre select code.
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

    edt  = 1'b0;
    if (do_ioo) iob_in [7:0] = datainreg;

  end

    assign dataout = dataoutreg;
    assign read = command_ff;

  //--------------------------------------------------------------------------
  // Main sequential logic
  //--------------------------------------------------------------------------
  always_ff @(posedge clk or posedge crs) begin
    if (crs) begin
      flag_ff       <= 1'b0;
      flag_buffer_ff <= 1'b1;
      irq_ff        <= 1'b0;
      control_ff    <= 1'b0;
      command_ff <= 1'b0;

      end else begin
        //--------------------------------------------------------------------
        // Simple flip-flop controls
        //--------------------------------------------------------------------
        // flag buffer flip/flop
        if (do_clf |  (iak & irq_ff)) flag_buffer_ff <= 1'b0;
        else if (popio | do_stf | (feedhole & ~flag_ff)) flag_buffer_ff <= 1'b1;

        // flag flip/flop
        if (flag_buffer_ff & enf) flag_ff <= 1'b1;
        else if (do_clf) flag_ff <= 1'b0;

        // irq flip/flop
        if (sir & prh & flag_buffer_ff & ien & flag_ff & control_ff) irq_ff <= 1'b1;
        else if (enf) irq_ff <= 1'b0;
        // control flip/flip
        if (do_clc | crs) control_ff <= 1'b0;
        else if (do_stc) control_ff <= 1'b1;

        if (do_clc | feedhole) command_ff <= 1'b0;
        else if (do_stc) command_ff <= 1'b1;

        if (do_ioo) dataoutreg <= iob_out[7:0];

        if (feedhole) datainreg <= datain;

      end
    end

endmodule
