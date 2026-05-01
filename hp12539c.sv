`timescale 1ns/1ps
// set to 50 decimal for 2116 with real 1 MHz. Use 10MHz for speeded up 2116.
localparam logic [5:0] DOWN_SCALER = 6'd4;

module hp12539c #(
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
  // Device command signal. 
  // Position A: Bit 5 is always 0.
  // Position B: Bit 5 is same as bit 4 and reflect the error flag
  input  string        jumper_w1,
  // Test jumper. 
  // Position A: Normal
  // Position B: Bypass three stages of decade counters to make testing easier.
  input  string        jumper_w2  
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
  logic        error_flag_ff;
  logic        time_flag_ff;
  logic        time_flag_ff_delayed;

  logic        [2:0] timebase_selector_register;
  logic        clk_1MHz;
  logic        clk_100kHz;
  logic        clk_10kHz;
  logic        clk_1kHz;
  logic        clk_100Hz;
  logic        clk_10Hz;
  logic        clk_1Hz;
  logic        clk_100mHz;
  logic        clk_10mHz;
  logic        clk_1mHz;  

  logic        timebase_10kHz;
  logic        timebase_1kHz;
  logic        timebase_100Hz;
  logic        timebase_10Hz;
  logic        timebase_1Hz;
  logic        timebase_100mHz;
  logic        timebase_10mHz;
  logic        timebase_1mHz;                
  logic        timebase;
  logic        [5:0] scaler;
  logic        [3:0] decade_divider_100kHz;
  logic        [3:0] decade_divider_10kHz;
  logic        [3:0] decade_divider_1kHz;
  logic        [3:0] decade_divider_100Hz;
  logic        [3:0] decade_divider_10Hz;  
  logic        [3:0] decade_divider_1Hz;
  logic        [3:0] decade_divider_100mHz;
  logic        [3:0] decade_divider_10mHz;
  logic        [3:0] decade_divider_1mHz; 

  logic        time_flag_gate;
  logic        time_flag_gate_delayed;   

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
    if (do_ioi) iob_in [4] = error_flag_ff;

    if (jumper_w1 == "A") begin
      if (do_ioi) iob_in [5] = 1'b0;  
    end
    else begin
      if (do_ioi) iob_in [5] = error_flag_ff; 
    end

    clk_1MHz = (scaler == DOWN_SCALER);
    clk_100kHz = (decade_divider_100kHz == 4'd9) & clk_1MHz & control_ff & ~ioo;
    clk_10kHz = (decade_divider_10kHz == 4'd9) & clk_1MHz & clk_100kHz & control_ff & ~ioo;
    clk_1kHz = (decade_divider_1kHz == 4'd9) & clk_1MHz & clk_100kHz & clk_10kHz & control_ff & ~ioo;
    clk_100Hz = (decade_divider_100Hz == 4'd9) & clk_1MHz & clk_100kHz & clk_10kHz & clk_1kHz & control_ff & ~ioo;
    if (jumper_w2 == "A") begin
      clk_10Hz = (decade_divider_10Hz == 4'd9) & clk_1MHz & clk_100kHz & clk_10kHz & clk_1kHz & clk_100Hz & control_ff & ~ioo;
    end else begin 
      clk_10Hz = clk_10kHz;
    end
    clk_1Hz = (decade_divider_1Hz == 4'd9) & clk_1MHz & clk_100kHz & clk_10kHz & clk_1kHz & clk_100Hz & clk_10Hz & control_ff & ~ioo;
    clk_100mHz = (decade_divider_100mHz == 4'd9) & clk_1MHz & clk_100kHz & clk_10kHz & clk_1kHz & clk_100Hz & clk_10Hz & clk_1Hz & control_ff & ~ioo;
    clk_10mHz = (decade_divider_10mHz == 4'd9) & clk_1MHz & clk_100kHz & clk_10kHz & clk_1kHz & clk_100Hz & clk_10Hz & clk_1Hz & clk_100mHz & control_ff & ~ioo;
    clk_1mHz = (decade_divider_1mHz == 4'd9) & clk_1MHz & clk_100kHz & clk_10kHz & clk_1kHz & clk_100Hz & clk_10Hz & clk_1Hz & clk_100mHz & clk_10mHz & control_ff & ~ioo;
  
    timebase_10kHz = (decade_divider_10kHz == 4'd9) || (decade_divider_10kHz == 4'd8);
    timebase_1kHz = (decade_divider_1kHz == 4'd9) || (decade_divider_1kHz == 4'd8);
    timebase_100Hz = (decade_divider_100Hz == 4'd9) || (decade_divider_100Hz == 4'd8);    
    timebase_10Hz = (decade_divider_10Hz == 4'd9) || (decade_divider_10Hz == 4'd8);
    timebase_1Hz = (decade_divider_1Hz == 4'd9) || (decade_divider_1Hz == 4'd8);
    timebase_100mHz = (decade_divider_100mHz == 4'd9) || (decade_divider_100mHz == 4'd8);
    timebase_10mHz = (decade_divider_10mHz == 4'd9) || (decade_divider_10mHz == 4'd8);        
    timebase_1mHz = (decade_divider_1mHz == 4'd9) || (decade_divider_1mHz == 4'd8);        

    case (timebase_selector_register)
      3'd0: timebase = timebase_10kHz;
      3'd1: timebase = timebase_1kHz;
      3'd2: timebase = timebase_100Hz;
      3'd3: timebase = timebase_10Hz;
      3'd4: timebase = timebase_1Hz;
      3'd5: timebase = timebase_100mHz;
      3'd6: timebase = timebase_10mHz;
      3'd7: timebase = timebase_1mHz;                  
    endcase 

    time_flag_gate = ~time_flag_ff & control_ff & ~flag_ff;

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
      time_flag_ff <= 1'b0;
      error_flag_ff <= 1'b0;
      timebase_selector_register <= 3'o0;
      end else begin
        //--------------------------------------------------------------------
        // Simple flip-flop controls
        //--------------------------------------------------------------------


        // flag buffer flip/flop
        if (do_clf |  (iak & irq_ff)) flag_buffer_ff <= 1'b0;
        else if (do_stf) flag_buffer_ff <= 1'b1;
        else if (time_flag_gate & ~time_flag_gate_delayed) flag_buffer_ff <= ~flag_ff;

        // flag flip/flop
        if (flag_buffer_ff & enf) flag_ff <= 1'b1;
        else if (do_clf) flag_ff <= 1'b0;


        // time flag flip/flop
        if (sir) time_flag_ff <= timebase;

        time_flag_ff_delayed <= time_flag_ff;

        // error flag is clocked on the positive edge of the time_flag_ff
        if (do_stc) error_flag_ff <= 1'b0;
        else if (time_flag_ff & ~time_flag_ff_delayed) error_flag_ff <= flag_ff;

        time_flag_gate_delayed <= time_flag_gate;

        // irq flip/flop
        if (sir & prh & flag_buffer_ff & ien & flag_ff & control_ff) irq_ff <= 1'b1;
        else if (enf) irq_ff <= 1'b0;
        // control flip/flip
        if (do_clc | crs | do_ioo) control_ff <= 1'b0;
        else if (do_stc) control_ff <= 1'b1;

        if (do_ioo) timebase_selector_register <= iob_out[2:0];

        // Downscaler to get to 1MHz oscilator of the original 12539C
        if (scaler == DOWN_SCALER) begin 
          scaler <= 6'd0;
        end 
        else begin 
          scaler <= scaler + 6'd1;
        end

        // 100 kHz timebase
        if (~control_ff | ioo) decade_divider_100kHz <= 4'o00;
        else if (clk_1MHz) begin
          if (decade_divider_100kHz < 4'd09) begin
            decade_divider_100kHz <= decade_divider_100kHz + 4'd1;
          end 
          else begin
            decade_divider_100kHz <= 4'd0;
          end
        end

        // 10 kHz timebase
        if (~control_ff | ioo) decade_divider_10kHz <= 4'o00;
        else if (clk_100kHz) begin
          if (decade_divider_10kHz < 4'd09) begin
            decade_divider_10kHz <= decade_divider_10kHz + 4'd1;
          end 
          else begin
            decade_divider_10kHz <= 4'd0;
          end
        end

        // 1 kHz timebase
        if (~control_ff | ioo) decade_divider_1kHz <= 4'o00;
        else if (clk_10kHz) begin
          if (decade_divider_1kHz < 4'd09) begin
            decade_divider_1kHz <= decade_divider_1kHz + 4'd1;
          end 
          else begin
            decade_divider_1kHz <= 4'd0;
          end
        end

        // 100 Hz timebase
        if (~control_ff | ioo) decade_divider_100Hz <= 4'o00;
        else if (clk_1kHz) begin
          if (decade_divider_100Hz < 4'd09) begin
            decade_divider_100Hz <= decade_divider_100Hz + 4'd1;
          end 
          else begin
            decade_divider_100Hz <= 4'd0;
          end
        end

        if (~control_ff | ioo) decade_divider_10Hz <= 4'o00;
        else if (clk_100Hz) begin
          if (decade_divider_10Hz < 4'd09) begin
            decade_divider_10Hz <= decade_divider_10Hz + 4'd1;
          end 
          else begin
            decade_divider_10Hz <= 4'd0;
          end
        end

        if (~control_ff | ioo) decade_divider_1Hz <= 4'o00;
        else if (clk_10Hz) begin
          if (decade_divider_1Hz < 4'd09) begin
            decade_divider_1Hz <= decade_divider_1Hz + 4'd1;
          end 
          else begin
            decade_divider_1Hz <= 4'd0;
          end
        end

        if (~control_ff | ioo) decade_divider_100mHz <= 4'o00;
        else if (clk_1Hz) begin
          if (decade_divider_100mHz < 4'd09) begin
            decade_divider_100mHz <= decade_divider_100mHz + 4'd1;
          end 
          else begin
            decade_divider_100mHz <= 4'd0;
          end
        end

        if (~control_ff | ioo) decade_divider_10mHz <= 4'o00;
        else if (clk_100mHz) begin
          if (decade_divider_10mHz < 4'd09) begin
            decade_divider_10mHz <= decade_divider_10mHz + 4'd1;
          end 
          else begin
            decade_divider_10mHz <= 4'd0;
          end
        end

        if (~control_ff | ioo) decade_divider_1mHz <= 4'o00;
        else if (clk_10mHz) begin
          if (decade_divider_1mHz < 4'd09) begin
            decade_divider_1mHz <= decade_divider_1mHz + 4'd1;
          end 
          else begin
            decade_divider_1mHz <= 4'd0;
          end
        end

      end
    end

endmodule
