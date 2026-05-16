//------------------------------------------------------------------------------
// hp2116_cpu.sv
//
// Simplified HP 2116 CPU skeleton with timing model updated to better match
// the original machine:
//
// - tstate is a free-running modulo-8 counter while RUN is active
// - PRESET resets phase to FETCH and tstate to T0
// - All phases share the same T0..T7 timing states
// - IR stores T[15:10] (instruction field) so decode is stable even if T is
//   reused later
// - Direct JMP completes in FETCH/T7
// - Indirect JMP completes in INDIRECT/T7
// - HALT is decoded as 1020xx and recognized in FETCH/T7
//
// Notes:
// - This is still a functional skeleton, not yet a full HP 2116.
// - I/O instructions and most execute micro-operations remain to be added.
// - Memory bus is modeled with M as address register and T as data register.
//------------------------------------------------------------------------------
`timescale 1ns/1ps

module hp2116_cpu #(
) (
  input  logic         clk,
  input  logic         popio,

  // Switch register (stable)
  input  logic [15:0]  sw,

  // Debounced front-panel button signals
  input  logic         preset_btn,
  input  logic         run_btn,
  input  logic         halt_btn,
  input  logic         load_mem_btn,
  input  logic         load_a_btn,
  input  logic         load_b_btn,
  input  logic         load_addr_btn,
  input  logic         disp_mem_btn,
  input  logic         single_cycle_btn,
  input  logic         loader_protected_switch,

  // Observability
  output logic         run_ff,
  output logic         ien_ff,

  // Memory bus
  output logic [14:0]  mem_addr,
  output logic [15:0]  mem_wdata,
  input  logic [15:0]  mem_rdata,
  output logic         mem_we,
  input  logic         uart_rx,
  output logic         uart_tx,
  output logic         read_command,
  input  logic [7:0]   ptr_datain,
  output logic [7:0]   ptr_dataout,
  input  logic         ptr_feedhole,
  output logic         ptr_read,
  input  logic [7:0]   ptp_datain,
  output logic [7:0]   ptp_dataout,
  output logic         ptp_punch,  
  input  logic         ptp_flag,
  input  logic         stm32_fsmc_ne,
  input  logic         stm32_fsmc_nadv,
  input  logic         stm32_fsmc_nwe,
  input  logic         stm32_fsmc_noe,
  inout  logic [15:0]        stm32_fsmc_ad,
  output logic        stm32_irq,
  output logic        stm32_drq,
  output logic [6:0]  lpt_data,
  output logic        lpt_info_ready,
  output logic        lpt_master_reset,
  input  logic        lpt_output_resume,
  input  logic        lpt_line_ready,
  input  logic        lpt_paper_out,
  input  logic        lpt_ready,
  output logic        lpt_controlbit  
);

  logic ptp_dummy;

  //--------------------------------------------------------------------------
  // Registers
  //--------------------------------------------------------------------------
  logic [15:0] A, B;
  logic [15:0] TR;          // Memory data buffer / T register
  logic [14:0] P;          // Program counter
  logic [14:0] M;          // Memory address register
  logic [4:0] clk_scale;
  logic [5:0] central_interrupt_register; // should not be present on a 2116 but since SimH is cheating I have to do the same to be compatible.
  logic        EXTEND;
  logic        OVERFLOW;
  logic        CARRY;
  logic Interrupt_System_Enable;
  logic Interrupt_Control;

  // The I register stores only instruction bits 15..10.
  logic [5:0]  IR;

  logic RUN;
  logic iog;
  logic prl;
  logic flgl;
  logic flgl11, flgl12, flgl13, flgl15, flgl16, flgl20;
  logic sfc;
  logic irq10;
  logic clf;
  logic ien;
  logic stf;
  logic iak;
  logic t3;
  logic skf;
  logic flgh_dummy1, flgh_dummy2, flgh_dummy3, flgh_dummy4, flgh_dummy5, flgh_dummy6, flgh_dummy7;;

  logic ioo;
  logic clc;
  logic stc;
  logic ioi;
  logic sfs;

  logic irqh_dummy1;
  logic irqh_dummy2;
  logic irqh_dummy3;
  logic irqh_dummy5;
  logic irqh_dummy6;  
  logic irqh_dummy7;   
  logic srq10, srq11, srq12, srq13, srq14, srq15, srq16, srq17, srq20, srq21, srq22, srq23, srq24, srq25, srq26, srq27;
  logic [15:0] iob_out;
  logic [15:0] iob_in10, iob_in11, iob_in12, iob_in_internal, dummy, iob_in16, iob_in17, iob_in20, iob_in22;

  logic sir;
  logic enf;


  logic edt;
  logic pon;
  logic interrupt;

  logic crs;
  logic prl11;
  logic irq11, irq12,  irq16, irq17, irq20, irq22, irq23;
  logic skf10, skf12, skf16, skf17, skf20, skf22;
  logic skf11;
  logic ptr_read_dummy;
  logic [7:0] ptr_dataout_dummy;
  logic prl12;
  assign run_ff = RUN;
  assign ien_ff = Interrupt_System_Enable;
  logic [15:0] testconnector;

  logic unprotected;
  logic state34;
  logic state45;
  logic dma_phase;

  logic [1:0] eau_phase;  
  logic eau_mpy;
  logic eau_div;
  logic eau_dld;
  logic eau_dst;
  logic eau_as;
  logic eau_ls;
  logic eau_ro;
  logic eau_rt;
  logic eau_mem_ref;
  logic eau_divide_by_zero;
  logic extrabit_TR;
  logic extrabit_A;
  logic extrabit_BA;

  logic divisor_sign;
  logic dividend_sign;
  logic skip_to_end;

  logic scale_clock_enable;
  
  //--------------------------------------------------------------------------
  // T-state enum: T0..T7
  //--------------------------------------------------------------------------
typedef enum logic [2:0] {
  T0 = 3'b000,
  T1 = 3'b001,
  T2 = 3'b011,
  T3 = 3'b010,
  T4 = 3'b110,
  T5 = 3'b111,
  T6 = 3'b101,
  T7 = 3'b100
} tstate_t;


typedef enum logic [4:0] {
  EAU_STEP0 = 5'o03,
  EAU_STEP1 = 5'o02,
  EAU_STEP2 = 5'o06,
  EAU_STEP3 = 5'o07,
  EAU_STEP4 = 5'o05,
  EAU_STEP5 = 5'o04,
  EAU_STEP6 = 5'o10,
  EAU_STEP7 = 5'o11,
  EAU_STEP8 = 5'o13,
  EAU_STEP9 = 5'o12,
  EAU_STEP10 = 5'o16,
  EAU_STEP11 = 5'o17,
  EAU_STEP12 = 5'o15,
  EAU_STEP13 = 5'o14,
  EAU_STEP14 = 5'o20,
  EAU_STEP15 = 5'o21,
  EAU_STEP16 = 5'o23,
  EAU_STEP17 = 5'o22,
  EAU_STEP18 = 5'o26,
  EAU_STEP19 = 5'o27,
  EAU_STEP20 = 5'o25,
  EAU_STEP21 = 5'o24      
} eau_step_t;

  eau_step_t eau_step;

  tstate_t tstate;

// HP12531C teleprinter interface
hp12531c serial (
  .clk(clk),
  .crs(crs),

  .prl(prl11),
  .flgl(flgl),
  .sfc(sfc),
  .irql(irq16),
  .clf(clf),
  .ien(Interrupt_System_Enable),
  .stf(stf),
  .iak(iak),
  .t3(t3),
  .skf(skf16),

  .scm_l(msc1),
  .scl_l(lsc6),

  .iog(iog),
  .popio(popio | preset_btn),

  .iob16_or_bios_n(1'b0),

  .srq(srq16),
  .ioo(ioo),
  .clc(clc),
  .stc(stc),
  .prh(prl_out_from_12),
  .ioi(ioi),
  .sfs(sfs),

  .irqh(irqh_dummy1),
  .scl_h(1'b0),
  .scm_h(1'b0),

  .iob_out(iob_out),
  .iob_in(iob_in16),

  .sir(sir),
  .enf(enf),
  .flgh(flgh_dummy1),

  .run(RUN),

  .edt(edt),
  .pon(pon),
  .bioo_n(1'b0),
  .sfsb_or_bioi_n(1'b0),
  .uart_rx(uart_rx),
  .uart_tx(uart_tx),
  .read_command(read_command)
);

hp12597a ptr (
  .clk(clk),
  .crs(crs),

  .prl(prl12),
  .flgl(flgl11),
  .sfc(sfc),
  .irql(irq10),
  .clf(clf),
  .ien(Interrupt_System_Enable),
  .stf(stf),
  .iak(iak),
  .t3(t3),
  .skf(skf10),

  .scm_l(msc1),
  .scl_l(lsc0),

  .iog(iog),
  .popio(popio | preset_btn),

  .iob16_or_bios_n(1'b0),

  .srq(srq10),
  .ioo(ioo),
  .clc(clc),
  .stc(stc),
  .prh(prl_out_from_dma_2),
  .ioi(ioi),
  .sfs(sfs),

  .irqh(irqh_dummy2),
  .scl_h(1'b0),
  .scm_h(1'b0),

  .iob_out(iob_out),
  .iob_in(iob_in10),

  .sir(sir),
  .enf(enf),
  .flgh(flgh_dummy2),

  .run(RUN),

  .edt(edt),
  .pon(pon),
  .bioo_n(1'b0),
  .sfsb_or_bioi_n(1'b0),
  .datain(ptr_datain),
  .dataout(ptr_dataout),
  .flag(ptr_feedhole),
  .devicecommand(ptr_read),
  .jumper_w4(1'b1),
  .jumper_w9(1'b0)
);



hp12566b dmatest (
  .clk(clk),
  .crs(crs),

  .prl(prl_out_from_12),
  .flgl(flgl12),
  .sfc(sfc),
  .irql(irq12),
  .clf(clf),
  .ien(Interrupt_System_Enable),
  .stf(stf),
  .iak(iak),
  .t3(t3),
  .skf(skf12),

  .scm_l(msc1),
  .scl_l(lsc2),

  .iog(iog),
  .popio(popio | preset_btn),

  .iob16_or_bios_n(1'b0),

  .srq(srq12),
  .ioo(ioo),
  .clc(clc),
  .stc(stc),
  .prh(prl_out_from_16),
  .ioi(ioi),
  .sfs(sfs),

  .irqh(irqh_dummy3),
  .scl_h(1'b0),
  .scm_h(1'b0),

  .iob_out(iob_out),
  .iob_in(iob_in12),

  .sir(sir),
  .enf(enf),
  .flgh(flgh_dummy3),

  .run(RUN),

  .edt(edt),
  .pon(pon),
  .bioo_n(1'b0),
  .sfsb_or_bioi_n(1'b0),
  .datain(testconnector),
  .dataout(testconnector),
  .flag(ptr_read_dummy),
  .command(ptr_read_dummy),
/*
For the older 12578 DMA test - potentially the jumpers are for the 12556A board and not the 12566B board.
They might differ??
*/
  .jumper_w1("B"), //  Position B: Positive True command signal
  .jumper_w2("C"), //  Position C: ENF signal clears Device Command FF.
  .jumper_w3("B"), //  Position B: Sets the Flag Buffer FF and strobes input data on the negative-going edge.
  .jumper_w4("B"), //  Position B: Output data is continuously available to the 1/0 device 
  .jumper_w5("IN"), // Position IN: Device Flag signal latches listed bits of the input data register. 
  .jumper_w6("IN"), // Position IN: Device Flag signal latches listed bits of the input data register. 
  .jumper_w7("IN"), // Position IN: Device Flag signal latches listed bits of the input data register. 
  .jumper_w8("IN"), // Position IN: Device Flag signal latches listed bits of the input data register. 
  .jumper_w9("A")   // Position A: Allows the CLC, CRS, and Device Flag signals to clear the Device Command FF.  
/*
  .jumper_w1("C"), //  Position C: Pulsed ground true signal
  .jumper_w2("B"), //  Position B: Device Command FF clears on the negative-going edge of Device Flag signal.
  .jumper_w3("B"), //  Position B: Sets the Flag Buffer FF and strobes input data on the negative-going edge.
  .jumper_w4("B"), //  Position B: Output data is continuously available to the 1/0 device 
  .jumper_w5("IN"), // Position IN: Device Flag signal latches listed bits of the input data register. 
  .jumper_w6("IN"), // Position IN: Device Flag signal latches listed bits of the input data register. 
  .jumper_w7("IN"), // Position IN: Device Flag signal latches listed bits of the input data register. 
  .jumper_w8("IN"), // Position IN: Device Flag signal latches listed bits of the input data register. 
  .jumper_w9("A")  //  Position A: Allows the CLC, CRS, and Device Flag signals to clear the Device Command FF.
*/
);


hp13210a disk7900 (
  .clk(clk),
  .crs(crs),

  .prl(prl_out_from_14),
  .flgl(flgl13),
  .sfc(sfc),
  .irql(irq22),
  .clf(clf),
  .ien(Interrupt_System_Enable),
  .stf(stf),
  .iak(iak),
  .t3(t3),
  .skf(skf22),

  .scm_l(msc2),
  .scl_l(lsc2),

  .iog(iog),
  .popio(popio | preset_btn),

  .iob16_or_bios_n(1'b0),

  .srq(srq22),
  .ioo(ioo),
  .clc(clc),
  .stc(stc),
  .prh(prl),
  .ioi(ioi),
  .sfs(sfs),

  .irqh(irq23),
  .scl_h(msc2),
  .scm_h(lsc3),

  .iob_out(iob_out),
  .iob_in(iob_in22),

  .sir(sir),
  .enf(enf),
  .flgh(flgh_dummy4),

  .run(RUN),

  .edt(edt),
  .pon(pon),
  .bioo_n(1'b0),
  .sfsb_or_bioi_n(1'b0),
  .stm32_fsmc_ne(stm32_fsmc_ne),
  .stm32_fsmc_nadv(stm32_fsmc_nadv),
  .stm32_fsmc_nwe(stm32_fsmc_nwe),
  .stm32_fsmc_noe(stm32_fsmc_noe),
  .stm32_fsmc_ad(stm32_fsmc_ad),
  .stm32_drq(stm32_drq),
  .stm32_irq(stm32_irq)
);


hp12597a ptp (
  .clk(clk),
  .crs(crs),

  .prl(prl_out_from_15),
  .flgl(flgl15),
  .sfc(sfc),
  .irql(irq17),
  .clf(clf),
  .ien(Interrupt_System_Enable),
  .stf(stf),
  .iak(iak),
  .t3(t3),
  .skf(skf17),

  .scm_l(msc1),
  .scl_l(lsc7),

  .iog(iog),
  .popio(popio | preset_btn),

  .iob16_or_bios_n(1'b0),

  .srq(srq17),
  .ioo(ioo),
  .clc(clc),
  .stc(stc),
  .prh(prl11),
  .ioi(ioi),
  .sfs(sfs),

  .irqh(irqh_dummy5),
  .scl_h(1'b0),
  .scm_h(1'b0),

  .iob_out(iob_out),
  .iob_in(iob_in17),

  .sir(sir),
  .enf(enf),
  .flgh(flgh_dummy5),

  .run(RUN),

  .edt(edt),
  .pon(pon),
  .bioo_n(1'b0),
  .sfsb_or_bioi_n(1'b0),
  .datain(ptp_datain),
  .dataout(ptp_dataout),
  .flag(ptp_flag),
  .devicecommand(ptp_punch),
  .jumper_w4(1'b1),
  .jumper_w9(1'b0)
);


hp12539c tbg (
  .clk(clk),
  .crs(crs),

  .prl(prl_out_from_16),
  .flgl(flgl16),
  .sfc(sfc),
  .irql(irq11),
  .clf(clf),
  .ien(Interrupt_System_Enable),
  .stf(stf),
  .iak(iak),
  .t3(t3),
  .skf(skf11),

  .scm_l(msc1),
  .scl_l(lsc1),

  .iog(iog),
  .popio(popio | preset_btn),

  .iob16_or_bios_n(1'b0),

  .srq(srq11),
  .ioo(ioo),
  .clc(clc),
  .stc(stc),
  .prh(prl12),
  .ioi(ioi),
  .sfs(sfs),

  .irqh(irqh_dummy6),
  .scl_h(1'b0),
  .scm_h(1'b0),

  .iob_out(iob_out),
  .iob_in(iob_in11),

  .sir(sir),
  .enf(enf),
  .flgh(flgh_dummy6),

  .run(RUN),

  .edt(edt),
  .pon(pon),
  .bioo_n(1'b0),
  .sfsb_or_bioi_n(1'b0),
  .jumper_w1("A"), //  Position A: Bit 5 is always 0.
  .jumper_w2("B") //  Position A: Normal mode

);

hp12845a lpt (
  .clk(clk),
  .crs(crs),

  .prl(prl),
  .flgl(flgl20),
  .sfc(sfc),
  .irql(irq20),
  .clf(clf),
  .ien(Interrupt_System_Enable),
  .stf(stf),
  .iak(iak),
  .t3(t3),
  .skf(skf20),

  .scm_l(msc2),
  .scl_l(lsc0),

  .iog(iog),
  .popio(popio | preset_btn),

  .iob16_or_bios_n(1'b0),

  .srq(srq20),
  .ioo(ioo),
  .clc(clc),
  .stc(stc),
  .prh(prl_out_from_15),
  .ioi(ioi),
  .sfs(sfs),

  .irqh(irqh_dummy7),
  .scl_h(1'b0),
  .scm_h(1'b0),

  .iob_out(iob_out),
  .iob_in(iob_in20),

  .sir(sir),
  .enf(enf),
  .flgh(flgh_dummy7),

  .run(RUN),

  .edt(edt),
  .pon(pon),
  .bioo_n(1'b0),
  .sfsb_or_bioi_n(1'b0),
  .dataoutreg(lpt_data),
  .information_ready(lpt_info_ready),
  .master_reset(lpt_master_reset),
  .output_resume(lpt_output_resume),
  .line_ready(lpt_line_ready),
  .paper_out(lpt_paper_out),
  .controlbit(lpt_controlbit),
  .ready(lpt_ready),
  .jumper_w1("IN"), 
  .jumper_w2("IN"), 
  .jumper_w3("IN"), 
  .jumper_w4("IN"), 
  .jumper_w5("IN"),  
  .jumper_w6("IN"), 
  .jumper_w7("IN"), 
  .jumper_w8("IN"), 
  .jumper_w9("IN")   
);

assign scale_clock_enable = (clk_scale == 5'd1);

  //--------------------------------------------------------------------------
  // Helper: next T-state
  //--------------------------------------------------------------------------
  // Workaround: Verilator does not like plain arithmetic directly on enum values,
  // so an explicit function is used instead.
  function automatic tstate_t next_tstate(input tstate_t s);
    begin
      case (s)
        T0:      next_tstate = T1;
        T1:      next_tstate = T2;
        T2:      next_tstate = T3;
        T3:      next_tstate = T4;
        T4:      next_tstate = T5;
        T5:      next_tstate = T6;
        T6:      next_tstate = T7;
        default: next_tstate = T0;
      endcase
    end
  endfunction

  //--------------------------------------------------------------------------
  // Phase enum
  //--------------------------------------------------------------------------
  typedef enum logic [2:0] {
    PH_FETCH     = 3'd0,
    PH_INDIRECT  = 3'd1,
    PH_EXECUTE   = 3'd2,
    PH_INTERRUPT = 3'd3
  } phase_t;

  phase_t phase, saved_phase;

  //--------------------------------------------------------------------------
  // Decode fields
  //--------------------------------------------------------------------------
  logic [3:0]  op4;
  logic        cz;
  logic        ind;
  logic [9:0]  off10;
  logic [14:0] direct_addr;

  logic        is_halt_instr;
  logic        is_io_instr;
  logic        is_mac_instr;
  logic        is_srg_instr;
  logic        is_asg_instr;
  logic        is_mem_ref;
  logic        is_jmp, is_jsb;
  logic        msc0, msc1,msc2,msc3,msc4,msc5,msc6,msc7,lsc0,lsc1,lsc2,lsc3,lsc4,lsc5,lsc6,lsc7;
  logic        skip_on_overflow;
  logic        sfs_intp, sfc_intp, skip_intp, skip_io, skip_dma6, skip_dma7;
  logic [5:0] sc;
  logic set_control, clear_control, clear_flag, set_flag, set_overflow, clear_overflow, set_interrupt_control, clear_interrupt_control, set_interrupt_system_enable, clear_interrupt_system_enable;
  logic normal_instruction_execution;
  logic [5:0] sc_mux;
  always_comb begin
    ptp_dummy = 0'b0;
    // The decoder uses the I register (IR) for the control field.
    op4 = IR[4:1];
    cz  = IR[0];
    ind = TR[15];
    is_jmp = (op4 == 4'o5);
    is_jsb = (op4 == 4'o3);    
    // The low address bits come from the T register.
    off10 = TR[9:0];
    normal_instruction_execution = ~(dma_phase || (phase == PH_INTERRUPT));
    // The current page comes from P[14:10].
    direct_addr = cz ? {P[14:10], off10} : {5'b00000, off10};

    // HALT decodes as 1020xx. Since IR only stores bits 15..10, it is enough
    // to compare against the top field.

    is_io_instr = (IR[5:2] == 4'o10) & IR[0] & (phase== PH_FETCH);
    is_mac_instr = (IR[5:2] == 4'o10) & ~IR[0];
    is_srg_instr = (IR[5:2] == 4'o00) & ~IR[0];  // Shift / Rotate group
    is_asg_instr = (IR[5:2] == 4'o00) & IR[0];  // Alter / Skip group
    is_mem_ref = ~(is_srg_instr | is_asg_instr | is_io_instr | is_mac_instr);
    is_halt_instr = is_io_instr & (TR[8:6] == 3'o0);
    iog = is_io_instr | dma_phase;
    sc = TR[5:0];
    if (dma_phase) begin
      if (dma_1_cycle_request_ff) begin
        sc_mux = dma_1_program_control_word[5:0];
      end 
      else if (dma_2_cycle_request_ff) begin
        sc_mux = dma_2_program_control_word[5:0];
      end 
      else begin
        sc_mux = 6'o00;
      end 
    end else begin
       sc_mux = TR[5:0];
    end
    msc0 = sc_mux[5:3] == 3'o0;
    msc1 = sc_mux[5:3] == 3'o1;
    msc2 = sc_mux[5:3] == 3'o2;
    msc3 = sc_mux[5:3] == 3'o3;
    msc4 = sc_mux[5:3] == 3'o4;
    msc5 = sc_mux[5:3] == 3'o5;
    msc6 = sc_mux[5:3] == 3'o6;
    msc7 = sc_mux[5:3] == 3'o7;
    lsc0 = sc_mux[2:0] == 3'o0;
    lsc1 = sc_mux[2:0] == 3'o1;
    lsc2 = sc_mux[2:0] == 3'o2;
    lsc3 = sc_mux[2:0] == 3'o3;
    lsc4 = sc_mux[2:0] == 3'o4;
    lsc5 = sc_mux[2:0] == 3'o5;
    lsc6 = sc_mux[2:0] == 3'o6;
    lsc7 = sc_mux[2:0] == 3'o7;
    state34 = tstate[1] & ~tstate[0];
    state45 = tstate[2] & tstate[1];
    // iog signal is the same as is_io_instr
    set_control = is_io_instr & ~IR[1] & (TR[8:6] == 3'o7);
    clear_control = is_io_instr & IR[1] & (TR[8:6] == 3'o7);
    clear_flag = is_io_instr & (TR[9]==1);   // Clear when H/C bit is 1.
    set_flag = is_io_instr & (TR[9]==0) & (TR[8:6] == 3'o1); // Set only when H/C bit is 0 and we have bits 8..6 = 001.
    skip_on_overflow = is_io_instr & msc0 & lsc1 & ((TR[8:6] == 3'o3) & OVERFLOW | (TR[8:6] == 3'o2) & ~OVERFLOW);
    set_overflow = set_flag & msc0 & lsc1;
    clear_overflow = clear_flag & msc0 & lsc1;
    set_interrupt_control = ((phase == PH_FETCH) & ~IR[4] & ~IR[3] & ~IR[2]) | (phase == PH_INDIRECT) | (phase == PH_EXECUTE);
    clear_interrupt_control =  clear_control | set_control | clear_flag | set_flag | phase == PH_INTERRUPT ;
    set_interrupt_system_enable = set_flag & msc0 & lsc0;
    clear_interrupt_system_enable = clear_flag & msc0 & lsc0;
    iak = (tstate == T1) & (phase == PH_FETCH) & ~Interrupt_Control;
    ioo = state34 & (((TR[8:6] == 3'o6) && is_io_instr) | dma_ioo);
    ioi = state45 & ((((TR[8:6] == 3'o5) | (TR[8:6] == 3'o4)) && is_io_instr) | dma_ioi);
    if (dma_phase) begin
      iob_out = ioo ? iob_out_dma : 16'h0000;  
    end
    else begin
      iob_out = ioo ? (IR[1] ? B : A) : 16'h0000;  
    end
    
    sfs = is_io_instr & (TR[8:6] == 3'o3);
    sfc = is_io_instr & (TR[8:6] == 3'o2);
    sfs_intp = sfs & msc0 & lsc0 & Interrupt_System_Enable;
    sfc_intp = sfc & msc0 & lsc0 & ~Interrupt_System_Enable;
    skip_dma6 = (sfc & (sc == 6'o06) & ~dma_1_flag_ff) | (sfs & (sc == 6'o06) & dma_1_flag_ff);
    skip_dma7 = (sfc & (sc == 6'o07) & ~dma_2_flag_ff) | (sfs & (sc == 6'o07) & dma_2_flag_ff);
    skip_intp = sfc_intp | sfs_intp;
    skip_io = skf10 | skf11 | skf12 | skf16 | skf17| skf20 | skf22 | skip_intp | skip_dma6 | skip_dma7;
    clf = ((clear_flag & normal_instruction_execution) | dma_clf) & state45;
    stf = set_flag & normal_instruction_execution & state45;
    stc = ((set_control & normal_instruction_execution)| dma_stc) & state34;
    clc = ((clear_control & normal_instruction_execution)| dma_clc) & state45;
    t3 = (tstate == T3);
    sir = (tstate == T5);
    enf = (tstate == T2);
    crs = clc & msc0 & lsc0 | popio;
    interrupt = ((irq10 | irq11 | irq12  | irq16 | irq17 | irq20| irq22 | irq23 | dma_1_irq_ff | dma_2_irq_ff )  & Interrupt_System_Enable & Interrupt_Control) |  (Interrupt_System_Enable & mp_irq);
    if ((M >= 15'o77700) && loader_protected_switch) begin
      unprotected = 1'b0;
    end else begin
      unprotected = 1'b1;
    end
    srq13 = 1'b0;
    srq14 = 1'b0;
    srq15 = 1'b0;
    //srq17 = 1'b0;
    srq21 = 1'b0;
    //srq22 = 1'b0;
    srq23 = 1'b0;
    srq24 = 1'b0; 
    srq25 = 1'b0;
    srq26 = 1'b0;
    srq27 = 1'b0;     

    eau_mem_ref = eau_mpy | eau_div | eau_dld | eau_dst;
    eau_step = eau_step_t'({eau_phase, tstate});
  end

always @* begin
    // Default value to avoid latches
    iob_in_internal = 16'h0000;

    // Special case: internal select codes 00-07 (and any reserved values)
    if (sc_mux < 6'o10) begin
        case (sc_mux)
            6'o01: iob_in_internal = sw;
            6'o02: iob_in_internal = dma_1_reg_selector?{ 2'b00, dma_1_block_length[13:0]}:{16'o000000};
            6'o03: iob_in_internal = dma_2_reg_selector?{ 2'b00, dma_2_block_length[13:0]}:{16'o000000};
            6'o04: iob_in_internal = {10'o0000, central_interrupt_register}; 
            6'o05: iob_in_internal = mp_violation_register;
            default: iob_in_internal = 16'o000000;

        endcase
    end
    else begin
      iob_in_internal = iob_in10 | iob_in11 | iob_in12 | iob_in16 | iob_in17 | iob_in20 |iob_in22;
    end
end

  task automatic do_eau_arithmetic_shift (
      input logic direction,        // 1 = right, 0 = left
      input logic [3:0] steps
  );
      logic [31:0] temp;
      logic overflow;
      int count;

      begin
          // Work on a temporary value first.
          // This avoids many overlapping non-blocking assignments.
          temp = {B, A};
          overflow = 1'b0;
          // In many HP-style encodings, 0 means 16 shifts.
          if (steps == 4'd0)
              count = 16;
          else
              count = int'(steps);

          for (int i = 0; i < count; i++) begin
              if (direction) begin
                  // Arithmetic right shift:
                  // copy sign bit into the new top bit.
                  temp = {temp[31], temp[31:1]};
              end else begin
                  // Arithmetic left shift:
                  // shift left, fill low bit with zero.
                  if ((temp[31] & ~temp[30]) | (~temp[31] & temp[30])) begin
                    overflow = 1'b1;
                  end                  
                  temp = {temp[31],temp[29:0], 1'b0};

              end
          end

          // Write final result back to B:A
          {B, A} <= temp;
          OVERFLOW <= overflow;
      end
  endtask

  // Rotate (circular shift) of B:A
  task automatic do_eau_rotate (
      input logic direction,        // 1 = right, 0 = left
      input logic [3:0] steps
  );
      logic [31:0] temp;
      int count;

      begin
          // Combine B:A
          temp = {B, A};

          // HP convention: 0 means 16 shifts
          count = (steps == 4'd0) ? 16 : int'(steps);

          if (direction) begin
              // Rotate right
              temp = (temp >> count) | (temp << (32 - count));
          end else begin
              // Rotate left
              temp = (temp << count) | (temp >> (32 - count));
          end

          // Write back
          {B, A} <= temp;
      end
  endtask


  // Logical shift of B:A
  task automatic do_eau_logic_shift (
      input logic direction,        // 1 = right, 0 = left
      input logic [3:0] steps
  );
      logic [31:0] temp;
      int count;

      begin
          // Combine B:A
          temp = {B, A};

          // HP convention: 0 means 16 shifts
          count = (steps == 4'd0) ? 16 : int'(steps);

          if (direction) begin
              // Logical right shift (fill with 0)
              temp = temp >> count;
          end else begin
              // Logical left shift (fill with 0)
              temp = temp << count;
          end

          // Write back
          {B, A} <= temp;
      end
  endtask
  task automatic do_shift_rotate(input logic [2:0] op, input logic store);
  begin
    unique case (op)
      3'o0: begin // left shift
          if (TR[11] == 0)
            A <= {A[15], A[13:0], 1'b0};
          else
            B <= {B[15], B[13:0], 1'b0};
        end
      3'o1: begin // right shift
          if (TR[11] == 0)
            A <= {A[15], A[15:1]};
          else
            B <= {B[15], B[15:1]};
        end
      3'o2:  begin // rotate left
          if (TR[11] == 0)
            A <= {A[14:0], A[15]};
          else
            B <= {B[14:0], B[15]};
        end
      3'o3:  begin // rotate right
          if (TR[11] == 0)
            A <= {A[0], A[15:1]};
          else
            B <= {B[0], B[15:1]};
        end
      3'o4:  begin // left shift clear sign
          if (TR[11] == 0)
            A <= {1'b0, A[13:0], 1'b0};
          else
            B <= {1'b0, B[13:0], 1'b0};
        end
      3'o5: begin // rotate E right with register
          if (TR[11] == 0) begin
            if (store) A <= {EXTEND, A[15:1]};
            EXTEND <= A[0];
          end
          else begin
            if (store) B <= {EXTEND, B[15:1]};
            EXTEND <= B[0];
          end
        end
      3'o6: begin  // rotate E left with register
          if (TR[11] == 0) begin
            if (store) A <= { A[14:0], EXTEND};
            EXTEND <= A[15];
          end
          else begin
            if (store) B <= {B[14:0], EXTEND};
            EXTEND <= B[15];
          end
        end
      3'o7: begin // rotate four left
          if (TR[11] == 0)
            A <= {A[11:0], A[15:12]};
          else
            B <= {B[11:0], B[15:12]};
        end
    endcase
  end
  endtask




// MEMORY PROTECT

logic [15:0] mp_violation_register;
logic [14:0] mp_fence_register;

logic mp_jmp_ptotect_ff;
logic mp_iak_ff;
logic mp_control_ff;
logic mp_interrupt_ff;
logic mp_interrupt_request_ff;
logic [1:0] mp_indirect_counter;
logic mp_mev;
logic mp_sir_d;
logic mp_sir_negedge;
logic mp_sc_05;
logic mp_prl_out;
logic mp_prh_in;
logic mp_irq;
logic mp_inhibit_execution;

always_comb begin
  mp_mev = (M < mp_fence_register);
  mp_sir_negedge = ~sir & mp_sir_d;
  mp_prh_in = 1'b1;

  mp_sc_05 = lsc5 & msc0 & is_io_instr;
  mp_prl_out = mp_prh_in & ~mp_interrupt_ff;
  mp_irq = mp_interrupt_request_ff;
  
end

always_ff @(posedge clk or popio) begin
  if (popio) begin
    mp_control_ff <= 1'b0;   
    mp_fence_register <= 15'o00000; 
    mp_interrupt_request_ff <= 1'b0;
    mp_violation_register <= 16'o100000;
  end else if (scale_clock_enable) begin

    mp_sir_d <= sir;
    if (tstate == T0) mp_inhibit_execution <= 1'b0; 
    if (mp_control_ff) begin 
      //$display("TIME %020t Fetch is_io_instr=%d, phase=%d, tstate=%d", $time, is_io_instr, phase, tstate);  
      case (phase) 
        PH_FETCH: begin
          mp_indirect_counter <= 2'd0;  
          if (is_io_instr) begin
            if (mp_iak_ff) begin
              if (is_halt_instr) begin
                if (tstate == T3) mp_control_ff <= 1'b0; 
              end
            end 
            else begin
              if (is_halt_instr) begin
                if (tstate == T3) mp_violation_register <= {1'b0, M};
                if (tstate == T2) begin 
                  mp_inhibit_execution <= 1'b1; 
                  mp_interrupt_ff <= 1'b1;
                end 
              end 
              else begin
                if (~(lsc1 & msc0)) begin
                  if (tstate == T3) mp_violation_register <={1'b0, M};
                  if (tstate == T2) begin 
                    mp_inhibit_execution <= 1'b1;  
                    mp_interrupt_ff <= 1'b1;
                  end              
                end             
              end
            end
          end
          else begin
            //$display("TIME %020t Fetch is_io_instr=%d", $time, is_io_instr);
            if (tstate == T3) begin
              mp_violation_register <= {1'b0, M};

              //$display("TIME %020t Saving M in Violation Register", $time);
            end
            if (mp_iak_ff) begin
              if (tstate == T2) mp_control_ff <= 1'b0;  
            end 
            else begin
              if (mp_jmp_ptotect_ff) begin
                if (mp_mev) begin
                  if (tstate == T2) begin
                    mp_inhibit_execution <= 1'b1;   
                    mp_interrupt_ff <= 1'b1;
                  end
                end
              end
            end
          end
          
        end
        PH_INDIRECT: begin    
          if (tstate == T5) mp_indirect_counter <= mp_indirect_counter + 2'd1; 
        end
        default: begin
          
        end
      endcase
    end

    if (mp_sir_negedge) mp_iak_ff <= 1'b0;
    else if (iak) mp_iak_ff <= 1'b1;


    if (iak | (tstate == T3)) mp_jmp_ptotect_ff <= 1'b0;
    else if (is_jmp & (tstate == T4)) mp_jmp_ptotect_ff <= 1'b1;

    if (stc & mp_sc_05) begin 
      $display("TIME %020t Setting mp_control_ff", $time);
      mp_control_ff <= 1'b1;
    end


    if (iak) mp_interrupt_ff <= 1'b0;

    if (mp_sc_05 & ioo) mp_fence_register <= iob_out[14:0];


    if (tstate == T2) mp_interrupt_request_ff <= 1'b0;
    else if (mp_prh_in & mp_interrupt_ff & sir) mp_interrupt_request_ff <= 1'b1;

  end
end

  //--------------------------------------------------------------------------
  // Memory wiring
  //--------------------------------------------------------------------------
  always_comb begin
    // Address is driven from M and write data from T.

    if (dma_phase) begin
      if (dma_1_cycle_request_ff) begin
        mem_addr = dma_1_address_word[14:0]; 
        mem_wdata = dma_1_storage_register; 
      end 
      else if (dma_2_cycle_request_ff) begin
        mem_addr = dma_2_address_word[14:0]; 
        mem_wdata = dma_2_storage_register;
      end 
      else begin
        mem_addr = 15'o000000; 
        mem_wdata = 16'o000000;
      end 
    end else begin
      mem_addr  = M ;
      mem_wdata = TR;
    end    
  end



function automatic logic srq_for_sc(input logic [5:0] selectcode);
  begin
    unique case (selectcode)
      6'o10: srq_for_sc = srq10;
      6'o11: srq_for_sc = srq11;
      6'o12: srq_for_sc = srq12;
      6'o13: srq_for_sc = srq13;
      6'o14: srq_for_sc = srq14;
      6'o15: srq_for_sc = srq15;
      6'o16: srq_for_sc = srq16;
      6'o17: srq_for_sc = srq17;
      6'o20: srq_for_sc = srq20;
      6'o21: srq_for_sc = srq21;
      6'o22: srq_for_sc = srq22;
      6'o23: srq_for_sc = srq23;
      6'o24: srq_for_sc = srq24;
      6'o25: srq_for_sc = srq25;
      6'o26: srq_for_sc = srq26;
      6'o27: srq_for_sc = srq27;
      default: srq_for_sc = 1'b0;
    endcase
  end
endfunction

/*
  Signal DIN1 and DIN2 in the schematic are the dma_1_direction_ff and dma_2_direction_ff.
  Signal WCR1 and WCR2 is the dma_1_overflow_ff and dma_2_overflow_ff.
  Signal CR1 and CR2 is coming from the Cycle Request Flip Flops, dma_1_cycle_request_ff, dma_2_cycle_request_ff


*/



  logic [5:0] dma_1_program_control_word, dma_2_program_control_word;
  logic dma_1_stc_on_every_transfer, dma_2_stc_on_every_transfer;
  logic dma_1_clc_on_last_transfer, dma_2_clc_on_last_transfer;
  logic [14:0] dma_1_address_word, dma_2_address_word;
  logic [13:0] dma_1_block_length, dma_2_block_length;
  logic [15:0] dma_1_storage_register, dma_2_storage_register;
  logic dma_1_direction_ff, dma_2_direction_ff;
  logic dma_1_overflow_ff, dma_2_overflow_ff;
  logic dma_1_control_ff, dma_2_control_ff, dma_1_reg_selector, dma_2_reg_selector;
  logic dma_1_flag_ff, dma_2_flag_ff, dma_1_flagbuffer_ff, dma_2_flagbuffer_ff, dma_1_irq_ff, dma_2_irq_ff;
  logic dma_1_transfer_enable_ff, dma_2_transfer_enable_ff;
  logic prh_in_to_dma_1, prl_out_from_dma_1, prh_in_to_dma_2, prl_out_from_dma_2, prl_out_from_12, prl_out_from_14, prl_out_from_15, prl_out_from_16;
  //logic dma_1_active;

  logic dma_ioi, dma_ioo, dma_stc, dma_clc, dma_clf;
  logic dma_1_char_mode_ff, dma_2_char_mode_ff;
  logic dma_1_cycle_div_ff,dma_2_cycle_div_ff;
  logic dma_1_cycle_request_ff, dma_2_cycle_request_ff;
  logic dma_1_request, dma_2_request;
  logic dma_1_cycle_div_toggle;
  logic dma_1_cycle_div_toggle_delayed;
  logic dma_2_cycle_div_toggle;
  logic dma_2_cycle_div_toggle_delayed;  
  logic [15:0] iob_out_dma; 
  always_comb begin
    // DMA combinatorial logic
    prh_in_to_dma_1 = mp_prl_out;
    prl_out_from_dma_1 = prh_in_to_dma_1 & ~(Interrupt_System_Enable & dma_1_flag_ff & dma_1_control_ff);
    prh_in_to_dma_2 =prl_out_from_dma_1;
    prl_out_from_dma_2 = prh_in_to_dma_2 & ~(Interrupt_System_Enable & dma_2_flag_ff & dma_2_control_ff);

    dma_ioi = 1'b0;
    dma_ioo = 1'b0;
    dma_stc = 1'b0;
    dma_clc = 1'b0;
    dma_clf = 1'b0;
    edt     = 1'b0;

    if (dma_phase) begin
        // Kodkommentar: STC vid varje transfer om villkoren är uppfyllda.
        if (dma_1_stc_on_every_transfer && dma_1_cycle_request_ff &&
            ~(dma_1_overflow_ff && dma_1_direction_ff)) begin
            dma_stc = 1'b1;
        end
        else if (dma_2_stc_on_every_transfer && dma_2_cycle_request_ff &&
                 ~(dma_2_overflow_ff && dma_2_direction_ff)) begin
            dma_stc = 1'b1;
        end

        // Kodkommentar: CLC på sista transfer.
        if (dma_1_clc_on_last_transfer && dma_1_cycle_request_ff && dma_1_overflow_ff) begin
            dma_clc = 1'b1;
        end
        else if (dma_2_clc_on_last_transfer && dma_2_cycle_request_ff && dma_2_overflow_ff) begin
            dma_clc = 1'b1;
        end

        // Kodkommentar: DMA output cycle.
        if (dma_1_cycle_request_ff && ~dma_1_direction_ff) begin
            dma_ioo = 1'b1;
        end
        else if (dma_2_cycle_request_ff && ~dma_2_direction_ff) begin
            dma_ioo = 1'b1;
        end

        // Kodkommentar: DMA input cycle.
        if (dma_1_cycle_request_ff && dma_1_direction_ff) begin
            dma_ioi = 1'b1;
        end
        else if (dma_2_cycle_request_ff && dma_2_direction_ff) begin
            dma_ioi = 1'b1;
        end

        // Kodkommentar: CLF under transfer så länge overflow-villkoret inte blockerar.
        if (dma_1_cycle_request_ff && ~(dma_1_overflow_ff && dma_1_direction_ff)) begin
            dma_clf = 1'b1;
        end
        else if (dma_2_cycle_request_ff && ~(dma_2_overflow_ff && dma_2_direction_ff)) begin
            dma_clf = 1'b1;
        end

        // Kodkommentar: EDT i state45 om någon DMA-kanal har overflow under aktiv cykel.
        if (state45) begin
            if (dma_1_overflow_ff && dma_1_cycle_request_ff) begin
                edt = 1'b1;
            end
            else if (dma_2_overflow_ff && dma_2_cycle_request_ff) begin
                edt = 1'b1;
            end
        end
    end 
    dma_1_request = dma_1_transfer_enable_ff && srq_for_sc(dma_1_program_control_word);

    dma_2_request = !dma_1_request && dma_2_transfer_enable_ff && srq_for_sc(dma_2_program_control_word);
    dma_1_cycle_div_toggle = dma_1_cycle_request_ff && dma_phase;
    dma_2_cycle_div_toggle = dma_2_cycle_request_ff && dma_phase;
    if (dma_1_cycle_request_ff) begin
      if (dma_1_char_mode_ff) begin
        if (dma_1_cycle_div_ff) begin
          iob_out_dma[7:0] = dma_1_storage_register[15:8];  
        end
        else begin
          iob_out_dma[7:0] = dma_1_storage_register[7:0];  
        end
      end 
      else begin
        iob_out_dma = dma_1_storage_register;
      end          
    end 
    else if (dma_2_cycle_request_ff) begin
      if (dma_2_char_mode_ff) begin
        if (dma_2_cycle_div_ff) begin
          iob_out_dma[7:0] = dma_2_storage_register[15:8];  
        end
        else begin
          iob_out_dma[7:0] = dma_2_storage_register[7:0];  
        end
      end 
      else begin
        iob_out_dma = dma_2_storage_register;
      end        
    end 
    else begin
      iob_out_dma = 16'o000000;  
    end 
    
  end

  // DMA process
  always_ff @(posedge clk or popio) begin
    if (popio) begin
      dma_1_program_control_word <= 6'o00; 
      dma_2_program_control_word <= 6'o00;
      dma_1_address_word <= 15'o000000;
      dma_2_address_word <= 15'o000000;
      dma_1_block_length <= 14'o000000;
      dma_2_block_length <= 14'o000000;
      dma_1_control_ff <= 1'b0;
      dma_2_control_ff <= 1'b0;
      dma_1_reg_selector <= 1'b0;
      dma_2_reg_selector <= 1'b0;
      dma_1_flagbuffer_ff <= 1'b0;
      dma_2_flagbuffer_ff <= 1'b0;
      dma_1_transfer_enable_ff <= 1'b0;
      dma_2_transfer_enable_ff <= 1'b0;
      dma_1_stc_on_every_transfer <= 1'b0;
      dma_2_stc_on_every_transfer <= 1'b0;
      dma_1_clc_on_last_transfer <= 1'b0;
      dma_2_clc_on_last_transfer <= 1'b0;
      dma_1_char_mode_ff <= 1'b0;
      dma_2_char_mode_ff <= 1'b0;
      dma_1_cycle_div_ff <= 1'b0;
      dma_2_cycle_div_ff <=1'b0;
      dma_1_direction_ff <= 1'b0;
      dma_2_direction_ff <= 1'b0;
      dma_1_overflow_ff <= 1'b0;
      dma_2_overflow_ff <= 1'b0;
      dma_1_cycle_div_toggle_delayed <= 1'b0;
      dma_2_cycle_div_toggle_delayed <= 1'b0;
      dma_phase <=1'b0;
    end else if (scale_clock_enable) begin
      if (crs | (clc & (sc_mux == 6'o2))) dma_1_reg_selector <= 1'b0;
      else if (stc & (sc_mux == 6'o2)) dma_1_reg_selector <= 1'b1;

      if (ioo & ~dma_1_reg_selector & (sc_mux == 6'o2)) dma_1_address_word <= iob_out[14:0];
      if (ioo & ~dma_1_reg_selector & (sc_mux == 6'o2)) dma_1_direction_ff <= iob_out[15];
      if (ioo & dma_1_reg_selector & (sc_mux == 6'o2)) dma_1_block_length <= iob_out[13:0];
      if (ioo & dma_1_reg_selector & (sc_mux == 6'o2)) dma_1_overflow_ff <= 1'b0;
      if (crs | (clc & (sc_mux == 6'o3))) dma_2_reg_selector <= 1'b0;
      else if (stc & (sc_mux == 6'o3)) dma_2_reg_selector <= 1'b1;

      if (ioo & ~dma_2_reg_selector & (sc_mux == 6'o3)) dma_2_address_word <= iob_out[14:0];
      if (ioo & ~dma_2_reg_selector & (sc_mux == 6'o3)) dma_2_direction_ff <= iob_out[15];
      if (ioo & dma_2_reg_selector & (sc_mux== 6'o3)) dma_2_block_length <= iob_out[13:0];
      if (ioo & dma_2_reg_selector & (sc_mux== 6'o3)) dma_2_overflow_ff <= 1'b0;

      if (ioo & (sc_mux == 6'o6)) dma_1_program_control_word <= iob_out[5:0];
      if (ioo & (sc_mux == 6'o6)) dma_1_stc_on_every_transfer <= iob_out[15];
      if (ioo & (sc_mux == 6'o6)) dma_1_char_mode_ff <= iob_out[14];
      if (ioo & (sc_mux == 6'o6)) dma_1_clc_on_last_transfer <= iob_out[13];

      if (ioo & (sc_mux == 6'o7)) dma_2_program_control_word <= iob_out[5:0];
      if (ioo & (sc_mux == 6'o7)) dma_2_stc_on_every_transfer <= iob_out[15];
      if (ioo & (sc_mux == 6'o7)) dma_2_char_mode_ff <= iob_out[14];
      if (ioo & (sc_mux == 6'o7)) dma_2_clc_on_last_transfer <= iob_out[13];

      if (crs | (clc & (sc_mux == 6'o6))) dma_1_control_ff <= 1'b0;
      if (crs | (clc & (sc_mux == 6'o7))) dma_2_control_ff <= 1'b0;
      if (stc & (sc_mux == 6'o6)) dma_1_control_ff <= 1'b1;
      if (stc & (sc_mux == 6'o7)) dma_2_control_ff <= 1'b1;  

      if (stc & (sc_mux == 6'o6)) dma_1_transfer_enable_ff <= 1'b1;
      else if (crs | (dma_1_flagbuffer_ff & state45) ) dma_1_transfer_enable_ff <= 1'b0;

      if (stc & (sc_mux == 6'o7)) dma_2_transfer_enable_ff <= 1'b1;
      else if (crs | (dma_2_flagbuffer_ff & state45) ) dma_2_transfer_enable_ff <= 1'b0;

      // DMA 1 flag_buffer, flag and irq
      if ((clf & (sc_mux == 6'o6)) |  (iak & dma_1_irq_ff)) dma_1_flagbuffer_ff <= 1'b0;
      else if (popio | preset_btn | (stf & (sc_mux == 6'o6)) | (dma_1_overflow_ff & dma_1_transfer_enable_ff)) dma_1_flagbuffer_ff <= 1'b1;

      // flag flip/flop
      if (dma_1_flagbuffer_ff & enf) dma_1_flag_ff <= 1'b1;
      else if (clf & (sc_mux == 6'o6)) dma_1_flag_ff <= 1'b0;

      // irq flip/flop
      if (sir & prh_in_to_dma_1 & dma_1_flagbuffer_ff & Interrupt_System_Enable & dma_1_flag_ff & dma_1_control_ff) dma_1_irq_ff <= 1'b1;
      else if (enf) dma_1_irq_ff <= 1'b0;

      // DMA 2 flag_buffer, flag and irq
      if ((clf & (sc_mux == 6'o7)) |  (iak & dma_2_irq_ff)) dma_2_flagbuffer_ff <= 1'b0;
      else if (popio | preset_btn| (stf & (sc_mux == 6'o7)) | (dma_2_overflow_ff & dma_2_transfer_enable_ff)) dma_2_flagbuffer_ff <= 1'b1;

      // flag flip/flop
      if (dma_2_flagbuffer_ff & enf) dma_2_flag_ff <= 1'b1;
      else if ((clf & (sc_mux == 6'o7))) dma_2_flag_ff <= 1'b0;

      // irq flip/flop
      if (sir & prh_in_to_dma_2 & dma_2_flagbuffer_ff & Interrupt_System_Enable & dma_2_flag_ff & dma_2_control_ff) dma_2_irq_ff <= 1'b1;
      else if (enf) dma_2_irq_ff <= 1'b0;
      if (tstate == T6) begin
        dma_1_cycle_request_ff <= dma_1_request;
        dma_2_cycle_request_ff <= dma_2_request;       
      end 
      else if (crs) begin
        dma_1_cycle_request_ff <= 1'b0;
        dma_2_cycle_request_ff <= 1'b0;        
      end    

      dma_1_cycle_div_toggle_delayed <= dma_1_cycle_div_toggle;
      dma_2_cycle_div_toggle_delayed <= dma_2_cycle_div_toggle;

      if (stc & (sc_mux == 6'o6)) begin
        dma_1_cycle_div_ff <= 1'b0;  
      end 
      else if ((dma_1_cycle_div_toggle && !dma_1_cycle_div_toggle_delayed)) begin 
        dma_1_cycle_div_ff <= ~dma_1_cycle_div_ff; 
      end

      if (stc & (sc_mux == 6'o7)) begin
        dma_2_cycle_div_ff <= 1'b0;  
      end 
      else if ((dma_2_cycle_div_toggle && !dma_2_cycle_div_toggle_delayed)) begin 
        dma_2_cycle_div_ff <= ~dma_2_cycle_div_ff; 
      end      
    end
  end

  //--------------------------------------------------------------------------
  // One-shot edge detection for RUN and SINGLE CYCLE
  //--------------------------------------------------------------------------
  logic run_btn_d;
  logic sc_btn_d;

  logic run_press;
  logic sc_press;

  always_ff @(posedge clk or ~popio) begin
    if (popio) begin
      run_btn_d <= 1'b0;
      sc_btn_d  <= 1'b0;
    end else if (scale_clock_enable) begin
      run_btn_d <= run_btn;
      sc_btn_d  <= single_cycle_btn;
    end
  end

  // Button presses are detected only on the rising edge.
  assign run_press = run_btn & ~run_btn_d;
  assign sc_press  = single_cycle_btn & ~sc_btn_d;

  //--------------------------------------------------------------------------
  // Single-cycle control
  //--------------------------------------------------------------------------
  logic phase_step_armed;
  logic step_started_by_sc;

  //--------------------------------------------------------------------------
  // DISPLAY MEMORY pending capture
  //--------------------------------------------------------------------------
  logic panel_disp_pending;
  //logic [16:0] add_sum;
  //--------------------------------------------------------------------------
  // Main sequential logic
  //--------------------------------------------------------------------------
  always_ff @(posedge clk or popio) begin
    logic [16:0] add_sum;
    add_sum = '0;
    if (popio) begin
      A <= 16'o000000;
      B <= 16'o000000;
      TR <= 16'o000000;
      P <= 15'o00000;
      M <= 15'o00000;
      pon <= 1'b1;
      EXTEND   <= 1'b0;
      OVERFLOW <= 1'b0;

      IR <= 6'o00;

      Interrupt_System_Enable <= 1'b0;
      RUN <= 1'b0;

      phase  <= PH_FETCH;
      tstate <= T0;

      mem_we <= 1'b0;

      phase_step_armed   <= 1'b0;
      step_started_by_sc <= 1'b0;

      panel_disp_pending <= 1'b0;
      clk_scale <= 5'd0;
    end else if (scale_clock_enable) begin
      clk_scale <= 5'd0;
      // Default is no memory write in this cycle.
      mem_we <= 1'b0;
      //======================================================================
      // Front panel commands
      //======================================================================

      // DISPLAY MEMORY uses a synchronous RAM model and captures
      // mem_rdata on the next clock edge.
      if (panel_disp_pending) begin
        TR <= mem_rdata;
        M <= M + 15'o00001;
        P <= P + 15'o00001;
        panel_disp_pending <= 1'b0;
      end

      // PRESET resets the phase and T-state counter to the start state.

      // TODO: 
      // The popio signal need to be generated here but is it is a async signal coming from the nrst.
      // what is the best way of dealing with this?
      // need more investigation.

      if (preset_btn) begin
        phase  <= PH_FETCH;
        mp_violation_register <= 16'o100000;
        mp_control_ff <= 1'b0;
        mp_fence_register <= 15'o00000; 
        tstate <= T0;
        Interrupt_System_Enable    <= 1'b0;
        RUN    <= 1'b0;

        phase_step_armed   <= 1'b0;
        step_started_by_sc <= 1'b0;
      end else begin
        // The HALT button stops execution immediately.
        if (halt_btn) begin
          RUN <= 1'b0;
          phase_step_armed   <= 1'b0;
          step_started_by_sc <= 1'b0;
        end

        // The RUN button starts free-running execution.
        if (run_press) begin
          RUN <= 1'b1;
          phase_step_armed   <= 1'b0;
          step_started_by_sc <= 1'b0;
        end

        // SINGLE CYCLE runs exactly one full phase and then stops at the
        // next T7 -> T0 transition.
        if (sc_press && !RUN) begin
          RUN <= 1'b1;
          phase_step_armed   <= 1'b1;
          step_started_by_sc <= 1'b1;
        end

        // Front-panel functions also work when RUN=0.
        if (load_a_btn) A <= sw;
        if (load_b_btn) B <= sw;

        if (load_addr_btn) begin
          M <= sw[14:0];
          P <= sw[14:0];
        end

        if (load_mem_btn) begin
          // LOAD MEMORY writes SW through the T register.
          TR      <= sw;
          mem_we <= 1'b1;
          M      <= M + 15'o00001;
          P      <= P + 15'o00001;
        end

        if (disp_mem_btn) begin
          panel_disp_pending <= 1'b1;
        end

        //====================================================================
        // CPU sequencing
        //====================================================================
        if (RUN) begin
          if (dma_phase) begin
              // ---------------------------------------------------------------
              // DMA phase (stub)
              // ---------------------------------------------------------------
            if (tstate == T1) begin
              if (dma_1_cycle_request_ff & ~dma_1_direction_ff) begin
                  if ((dma_1_char_mode_ff & dma_1_cycle_div_ff) | ~dma_1_char_mode_ff) begin
                    if (dma_1_address_word == 15'o00000) begin
                      dma_1_storage_register <= A;
                    end
                    else if (dma_1_address_word == 15'o00001) begin
                      dma_1_storage_register <= B;
                    end
                    else begin
                      dma_1_storage_register <= mem_rdata;
                    end                      
                  end
              end 
              else if (dma_2_cycle_request_ff & ~dma_2_direction_ff ) begin
                  if ((dma_2_char_mode_ff & dma_2_cycle_div_ff) | ~dma_2_char_mode_ff) begin
                    if (dma_2_address_word == 15'o00000) begin
                      dma_2_storage_register <= A;
                    end
                    else if (dma_2_address_word == 15'o00001) begin
                      dma_2_storage_register <= B;
                    end
                    else begin
                      dma_2_storage_register <= mem_rdata;
                    end  
                  end
              end 

            end
            if (tstate == T2) begin
              if (dma_1_cycle_request_ff & ((dma_1_char_mode_ff & ~dma_1_cycle_div_ff) | ~dma_1_char_mode_ff)) begin
                  { dma_1_overflow_ff, dma_1_block_length[13:0] } <=  { 1'b0, dma_1_block_length[13:0] } + 14'o00001;
              end 
              else if (dma_2_cycle_request_ff & ((dma_2_char_mode_ff & ~dma_2_cycle_div_ff) | ~dma_2_char_mode_ff)) begin
                  { dma_2_overflow_ff, dma_2_block_length[13:0] } <=  { 1'b0, dma_2_block_length[13:0]} + 14'o00001;
              end                 
            end
            if (tstate == T4) begin
              if (dma_1_direction_ff & dma_1_cycle_request_ff) begin
                  if (dma_1_char_mode_ff) begin
                    if (dma_1_cycle_div_ff)  begin 
                      dma_1_storage_register[15:8]  <= iob_in_internal[7:0];    
                    end
                    else begin 
                      dma_1_storage_register[7:0]  <= iob_in_internal[7:0];       
                    end
                  end
                  else begin
                    dma_1_storage_register <= iob_in_internal;
                  end
              end 
              else if (dma_2_direction_ff & dma_2_cycle_request_ff) begin
                  if (dma_2_char_mode_ff) begin
                    if (dma_2_cycle_div_ff)  begin 
                      dma_2_storage_register[15:8]  <= iob_in_internal[7:0];     
                    end
                    else begin 
                      dma_2_storage_register[7:0]  <= iob_in_internal[7:0];                           
                    end
                  end
                  else begin
                    dma_2_storage_register <= iob_in_internal;
                  end
              end                  
            end
            if (tstate == T5) begin
              if (dma_1_direction_ff & dma_1_cycle_request_ff & ((dma_1_char_mode_ff & ~dma_1_cycle_div_ff) | ~dma_1_char_mode_ff)) begin  // write on word transfers or when even cycle
                if (dma_1_address_word == 15'o00000) begin
                  A <= dma_1_storage_register;
                end
                else if (dma_1_address_word == 15'o00001) begin
                  B <= dma_1_storage_register;
                end
                else begin
                  mem_we <= 1'b1;
                end
              end
              if (dma_2_direction_ff &  & dma_2_cycle_request_ff & ((dma_2_char_mode_ff & ~dma_2_cycle_div_ff) | ~dma_2_char_mode_ff)) begin  // write on word transfers or when even cycle
                if (dma_2_address_word == 15'o00000) begin
                  A <= dma_2_storage_register;
                end
                else if (dma_2_address_word == 15'o00001) begin
                  B <= dma_2_storage_register;
                end
                else begin
                  mem_we <= 1'b1;
                end
              end                
            end  
            if (tstate == T6) begin
              mem_we <= 1'b0;
            end               
            if (tstate == T6) begin
              if (dma_1_cycle_request_ff & ((dma_1_char_mode_ff & ~dma_1_cycle_div_ff) | ~dma_1_char_mode_ff)) begin
                dma_1_address_word[14:0] <=  dma_1_address_word[14:0] + 15'o00001; 
              end 
              else if (dma_2_cycle_request_ff & ((dma_2_char_mode_ff & ~dma_2_cycle_div_ff) | ~dma_2_char_mode_ff)) begin
                dma_2_address_word[14:0] <=  dma_2_address_word[14:0] + 15'o00001;
              end                   
            end           
          end
          else begin
            unique case (phase)

              // ---------------------------------------------------------------
              // FETCH phase
              // ---------------------------------------------------------------
              PH_FETCH: begin
                if (~mp_inhibit_execution) begin
                  unique case (tstate)
                    T0: begin
                      // Load the program counter into M before the memory read.
                      //M <= P;
                      CARRY <= 1'b0;


                  end

                    T1: begin
                      // Synchronous memory model: the instruction is read into T.
                      if (M== 15'o00000) 
                      begin
                        TR <= A;
                        IR <= A[15:10];
                      end
                      else if (M== 15'o00001)
                      begin
                        TR <= B;
                        IR <= B[15:10];
                      end
                      else begin
                        TR <= mem_rdata;
                        IR <= mem_rdata[15:10];
                      end
                    end

                    T3: begin
                      if (~eau_mem_ref) begin
                        if(set_interrupt_system_enable) begin
                          Interrupt_System_Enable <= 1'b1;
                        end
                        if (set_overflow) begin
                          OVERFLOW <= 1'b1;
                        end
                        if (is_mac_instr & TR[4] & ~TR[11]) begin
                          // Arithmetic shift TR[9] is direction
                          do_eau_arithmetic_shift(TR[9],TR[3:0]);
                        end
                        if (is_mac_instr & TR[5] & ~TR[11]) begin
                          // Logic shift TR[9] is direction
                          do_eau_logic_shift(TR[9],TR[3:0]);
                        end
                        if (is_mac_instr & TR[6] & ~TR[11]) begin
                          // Rotate TR[9] is direction
                          do_eau_rotate(TR[9],TR[3:0]);
                        end                    
                        if (is_srg_instr & TR[9]) begin
                          do_shift_rotate(TR[8:6],1'b1);
                        end
                        if  (is_srg_instr & ~TR[9] & ((TR[8:6] == 3'o5) || (TR[8:6] == 3'o6))) begin
                          do_shift_rotate(TR[8:6],1'b0);
                        end
                        if (is_asg_instr) begin
                          if (TR[11] == 1'b0)
                            unique case (TR[9:8])
                              2'o0:begin
                                // No operation
                              end
                              2'o1: // Clear
                                A<=16'o000000;
                              2'o2: // Complement
                                A<=~A;
                              2'o3: // Set
                                A<=16'o177777;
                            endcase

                          else
                            unique case (TR[9:8])
                              2'o0:begin
                                // No operation
                              end
                              2'o1: // Clear
                                B<=16'o000000;
                              2'o2: // Complement
                                B<=~B;
                              2'o3: // Set
                                B<=16'o177777;
                            endcase
                          if (TR[5]) begin
                            if (TR[0]==1'b0 & EXTEND == 1'b0)
                              CARRY <= 1'b1;
                            else if (TR[0] == 1'b1 & EXTEND == 1'b1)
                              CARRY <= 1'b1;
                          end
                          unique case (TR[7:6])
                            2'b00:begin
                              // no operation
                            end
                            2'b01:
                              EXTEND <= 1'b0;
                            2'b10:
                              EXTEND <= ~EXTEND;
                            2'b11:
                              EXTEND <= 1'b1;
                          endcase
                        end
                      end
                    end

                    T4: begin
                      if (~eau_mem_ref) begin
                        if (is_asg_instr) begin
                          if (TR[11] == 1'b0) begin
                            if (((~A[15] & TR[4] | ~A[0] & TR[3]) & ~TR[0]) | ((~(~A[15] & TR[4] | ~A[0] & TR[3])) & TR[0] & (TR[3] | TR[4]) ))
                              CARRY <= 1'b1;
                          end
                          else begin
                            if (((~B[15] & TR[4] | ~B[0] & TR[3]) & ~TR[0]) | ((~(~B[15] & TR[4] | ~B[0] & TR[3])) & TR[0] & (TR[3] | TR[4])))
                              CARRY <= 1'b1;
                          end

                          if (TR[2]) begin
                            if (TR[11] == 1'b0) begin
                              if (A == 16'o177777) begin
                                EXTEND <= 1'b1;
                              end
                              if (A == 16'o077777) begin
                                OVERFLOW <= 1'b1;
                              end
                              A <= A + 16'o000001;
                            end
                            else begin
                              if (B == 16'o177777) begin
                                EXTEND <= 1'b1;
                              end
                              if (B == 16'o077777) begin
                                OVERFLOW <= 1'b1;
                              end
                              B <= B + 16'o000001;
                            end

                          end
            

                      end
                      if (skip_io) begin
                        CARRY <= 1'b1;
                      end
                      if (skip_on_overflow) begin
                        CARRY <= 1'b1;
                      end

                      if(clear_interrupt_system_enable) begin
                        Interrupt_System_Enable <= 1'b0;
                      end
                      if (clear_overflow) begin
                        OVERFLOW <= 1'b0;
                      end
                      if(is_srg_instr) begin
                        if (TR[5]) EXTEND <= 1'b0;
                        if (TR[3]) begin
                          if (TR[11] == 1'b0) begin
                            if (A[0] == 1'b0)
                              CARRY <= 1'b1;
                          end else begin
                            if (B[0] == 1'b0)
                              CARRY <= 1'b1;
                          end
                        end
                      end
                    end  
                  end

                    T5: begin
                      if (~eau_mem_ref) begin
                        if (is_srg_instr & TR[4]) begin
                          do_shift_rotate(TR[2:0], 1'b1);
                        end
                        if  (is_srg_instr & ~TR[4] & ((TR[2:0] == 3'o5) || (TR[2:0] == 3'o6))) begin
                          do_shift_rotate(TR[2:0],1'b0);
                        end
                        if (is_asg_instr & TR[1]) begin
                            if (TR[11] == 1'b0) begin
                              if (A == 16'o000000 & ~TR[0] || A!=16'o000000 & TR[0])
                                CARRY <= 1'b1;
                            end
                            else begin
                              if (B == 16'o000000 & ~TR[0] || B != 16'o000000 & TR[0])
                                CARRY <= 1'b1;
                            end
                        end
                        if (is_asg_instr & ~TR[1] & ~TR[3] & ~TR[4] & ~TR[5] & TR[0]) begin // unconditional skip
                          CARRY <= 1'b1;
                        end
                        if (is_io_instr) begin
                          case (TR[8:6])
                            3'o4: begin // MIA
                              if (IR[1] == 1'b0) begin
                                A <= A | iob_in_internal;
                              end
                              else begin
                                B <= B | iob_in_internal;
                              end
                            end
                            3'o5: begin //LIA
                              if (IR[1] == 1'b0) begin
                                A <= iob_in_internal;
                              end
                              else begin
                                B <= iob_in_internal;
                              end
                            end
                            default: begin
                            end
                          endcase
                        end
                        case (TR[5:0])
                          6'o01: begin
                            //sw <= iob_out;
                          end
                          default: begin
                            
                          end
                        endcase
                      end
                    end

                    T7: begin
                      // FETCH completes at T7.
                      // Normally P advances to the next sequential instruction.
                      if (eau_mem_ref) begin
                        M <= TR[14:0];
                      end
                      else if (is_halt_instr) begin
                        RUN   <= 1'b0;
                        M <= P + 15'o00001;
                        P <= P + 15'o00001;
                        //phase <= PH_FETCH;
                      end
                      // HALT is recognized already here in FETCH/T7.
                      else if (is_srg_instr | is_asg_instr | is_io_instr) begin
                        P <= P + {14'o00000, CARRY} + 15'o00001;
                        M <= P + {14'o00000, CARRY} + 15'o00001;
                      end 
                      else if (is_mac_instr) begin // EAU instructions
  
                        eau_mpy <= 1'b0;
                        eau_div <= 1'b0;
                        eau_dld <= 1'b0;
                        eau_dst <= 1'b0;
                        if (TR[7] & ~TR[11]) eau_mpy <= 1'b1;
                        if (TR[8] & ~TR[11]) eau_div <= 1'b1;
                        if (TR[7] & TR[11]) eau_dld <= 1'b1;
                        if (TR[8] & TR[11]) eau_dst <= 1'b1;

                        M <= P + 15'o00001;
                        P <= P + 15'o00001;
                        
                      end
                      // A direct JMP completes entirely in the fetch phase.
                      else if (is_jmp && !ind) begin
                        M     <= direct_addr;
                        P     <= direct_addr;
                        //phase <= PH_FETCH;
                      end
                      // An indirect JMP proceeds to the indirect phase.
                      else if (is_jmp && ind) begin
                        M     <= direct_addr;
                        //phase <= PH_INDIRECT;
                      end
                      // Other indirect memory-reference instructions
                      // also proceed through the indirect phase.
                      else if (ind) begin
                        //P <= P + 15'o00001;
                        M     <= direct_addr;
                        //phase <= PH_INDIRECT;
                      end

                      else begin
                        // Direct-addressed instructions get their effective
                        // address in M and then move to execute.

                        M     <= direct_addr;
                        //phase <= PH_EXECUTE;
                      end

                    end

                    default: begin
                      // The remaining T-states are not used in fetch yet.
                    end
                  endcase
                end
              end

              // ---------------------------------------------------------------
              // INDIRECT phase
              // ---------------------------------------------------------------
              PH_INDIRECT: begin
                unique case (tstate)
                  T1: begin
                    if (M== 15'o00000)
                      TR <= A;
                    else if (M== 15'o00001)
                      TR <= B;
                    else
                      TR <= mem_rdata;
                  end

                  T7: begin
                    // After the indirect phase, the final effective
                    // address is in T[14:0].
                    M <= TR[14:0];
                    if (ind) begin
                      //phase <= PH_INDIRECT;
                    end
                    else if (is_jmp) begin
                      P     <= TR[14:0];
                      //phase <= PH_FETCH;
                    end else begin
                      //phase <= PH_EXECUTE;
                    end
                  end

                  default: begin
                    // The remaining T-states are not used here yet.
                  end
                endcase
              end

              // ---------------------------------------------------------------
              // EXECUTE phase
              // ---------------------------------------------------------------
              PH_EXECUTE: begin
                if (eau_mpy) begin
                  case (eau_step)
                    EAU_STEP0: begin
                        OVERFLOW <= 1'b0;  // reset overflow now - set it later
                        if ((TR != 16'o000000) && (A != 16'o000000)) begin 
                          divisor_sign <= TR[15];
                          dividend_sign <= A[15];
                        end
                        if (TR[15]) begin
                            { extrabit_TR, TR} <= ~({ TR[15], TR }) + 17'd1;
                        end 
                        else begin
                          extrabit_TR <= 1'b0;
                        end
                        if (A[15]) begin
                            { extrabit_A, A } <= (~{A[15], A}) + 17'd1;
                        end
                    end

                    EAU_STEP1: begin
                        if (A[0]) begin
                            B <= TR;    
                        end 
                        else begin
                            B <= 16'd0;
                        end
                        A[0] <= extrabit_TR;
                    end

                    EAU_STEP2: begin
                        if (A[1]) begin
                            {A[0],B} <= {1'b0, B} + {TR, 1'b0};
                            A[1] <= extrabit_TR;    
                        end 
                    end
                    EAU_STEP3: begin
                        if (A[2]) begin
                            {A[1:0],B} <= {1'b0, A[0], B} + {TR, 2'b0}; 
                            A[2] <= extrabit_TR;   
                        end 
                    end
                    EAU_STEP4: begin
                        if (A[3]) begin
                            {A[2:0],B} <= {1'b0, A[1:0], B} + {TR, 3'b0}; 
                            A[3] <= extrabit_TR;   
                        end 
                    end

                    EAU_STEP5: begin
                        if (A[4]) begin
                            {A[3:0],B} <= {1'b0, A[2:0], B} + {TR, 4'b0}; 
                            A[4] <= extrabit_TR;   
                        end 
                    end

                    EAU_STEP6: begin
                        if (A[5]) begin
                            {A[4:0],B} <= {1'b0, A[3:0], B} + {TR, 5'b0};    
                            A[5] <= extrabit_TR;
                        end 
                    end

                    EAU_STEP7: begin
                        if (A[6]) begin
                            {A[5:0],B} <= {1'b0, A[4:0], B} + {TR, 6'b0};    
                            A[6] <= extrabit_TR;
                        end 
                    end

                    EAU_STEP8: begin
                        if (A[7]) begin
                            {A[6:0],B} <= {1'b0, A[5:0], B} + {TR, 7'b0};   
                            A[7] <= extrabit_TR; 
                        end 
                    end

                    EAU_STEP9: begin
                        if (A[8]) begin
                            {A[7:0],B} <= {1'b0, A[6:0], B} + {TR, 8'b0};   
                            A[8] <= extrabit_TR; 
                        end 
                    end

                    EAU_STEP10: begin
                        if (A[9]) begin
                            {A[8:0],B} <= {1'b0, A[7:0], B} + {TR, 9'b0};   
                            A[9] <= extrabit_TR; 
                        end 
                    end

                    EAU_STEP11: begin
                        if (A[10]) begin
                            {A[9:0],B} <= {1'b0, A[8:0], B} + {TR, 10'b0};   
                            A[10] <= extrabit_TR; 
                        end 
                    end

                    EAU_STEP12: begin
                        if (A[11]) begin
                            {A[10:0],B} <= {1'b0, A[9:0], B} + {TR, 11'b0};    
                            A[11] <= extrabit_TR;
                        end 
                    end

                    EAU_STEP13: begin
                        if (A[12]) begin
                            {A[11:0],B} <= {1'b0, A[10:0], B} + {TR, 12'b0};
                            A[12] <= extrabit_TR;    
                        end 
                    end

                    EAU_STEP14: begin
                        if (A[13]) begin
                            {A[12:0],B} <= {1'b0, A[11:0], B} + {TR, 13'b0};    
                            A[13] <= extrabit_TR;
                        end 
                    end

                    EAU_STEP15: begin
                        if (A[14]) begin
                            {A[13:0],B} <= {1'b0, A[12:0], B} + {TR, 14'b0};  
                            A[14] <= extrabit_TR;  
                        end 
                    end

                    EAU_STEP16: begin
                        if (A[15]) begin
                            {A[14:0],B} <= {1'b0, A[13:0], B} + {TR, 15'b0};  
                            A[15] <= extrabit_TR;  
                        end 
                    end

                    EAU_STEP17: begin
                        if (extrabit_A) begin
                            {A,B} <= {1'b0, A[14:0], B} + {TR, 16'b0};  
                            A[15] <= extrabit_TR;  
                        end 
                    end                    

                    EAU_STEP18: begin
                        if ((divisor_sign & dividend_sign) | (~divisor_sign & ~dividend_sign)) begin
                            //A[15] <= 1'b0;
                        end else begin
                            { A,B }  <= ~{A,B} + 32'd1;
                        end
                    end

                    EAU_STEP19: begin
                        A <= B;  // Swap around A and B  
                        B <= A;
                    end

                    default: begin
                    end
                  endcase
                end
                else if (eau_div) begin

                  case (eau_step)                                 
                    EAU_STEP0: begin
                        divisor_sign <= TR[15];
                        dividend_sign <= B[15];
                        OVERFLOW <= 1'b0;
                        if (TR == 16'o000000) begin
                          eau_divide_by_zero <= 1'b1;
                          OVERFLOW <= 1'b1;
                        end
                        else begin 
                          eau_divide_by_zero <= 1'b0;
                        end
                        if (TR[15]) begin
                            TR[15:0] <= (~TR[15:0]) + 16'd1;
                        end
                        if (B[15]) begin
                            {extrabit_BA, B, A} <= (~{B[15], B, A}) + 33'd1;
                            if ({B[14:0],A} == 31'd0) begin
                              OVERFLOW <= 1'b1;  
                            end
                        end
                    end
                  
                    EAU_STEP1: begin
                        if (B >= TR) begin 
                          OVERFLOW <= 1'b1; 
                          skip_to_end <= 1'b1;   
                        end
                        else begin
                          skip_to_end <= 1'b0;
                          if (~eau_divide_by_zero & ~skip_to_end) begin
                            if ({B, A} >= {TR, 16'b0}) begin                              
                                {B, A} <= {B, A} - {TR, 16'b0};
                                extrabit_BA <= 1'b1;
                            end else begin
                                extrabit_BA <= 1'b0;
                            end
                          end
                        end 
                    end                 
                    EAU_STEP2: begin
                        if (~eau_divide_by_zero & ~skip_to_end) begin
                          if ({B[14:0], A} >= {TR, 15'b0}) begin
                              {B[14:0], A} <= {B[14:0], A} - {TR, 15'b0};
                              B[15] <= 1'b1;
                          end else begin
                              B[15] <= 1'b0;
                          end
                        end
                    end

                    EAU_STEP3: begin
                        if (~eau_divide_by_zero  & ~skip_to_end) begin
                          if ({B[13:0], A} >= {TR, 14'b0}) begin
                              {B[13:0], A} <= {B[13:0], A} - {TR, 14'b0};
                              B[14] <= 1'b1;
                          end else begin
                              B[14] <= 1'b0;
                          end
                        end
                    end

                    EAU_STEP4: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin
                          if ({B[12:0], A} >= {TR, 13'b0}) begin
                              {B[12:0], A} <= {B[12:0], A} - {TR, 13'b0};
                              B[13] <= 1'b1;
                          end else begin
                              B[13] <= 1'b0;
                          end
                        end
                    end

                    EAU_STEP5: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin
                          if ({B[11:0], A} >= {TR, 12'b0}) begin
                              {B[11:0], A} <= {B[11:0], A} - {TR, 12'b0};
                              B[12] <= 1'b1;
                          end else begin
                              B[12] <= 1'b0;
                          end
                        end
                    end

                    EAU_STEP6: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin
                          if ({B[10:0], A} >= {TR, 11'b0}) begin
                              {B[10:0], A} <= {B[10:0], A} - {TR, 11'b0};
                              B[11] <= 1'b1;
                          end else begin
                              B[11] <= 1'b0;
                          end
                        end
                    end

                    EAU_STEP7: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin
                          if ({B[9:0], A} >= {TR, 10'b0}) begin
                              {B[9:0], A} <= {B[9:0], A} - {TR, 10'b0};
                              B[10] <= 1'b1;
                          end else begin
                              B[10] <= 1'b0;
                          end
                        end
                    end

                    EAU_STEP8: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin
                          if ({B[8:0], A} >= {TR, 9'b0}) begin
                              {B[8:0], A} <= {B[8:0], A} - {TR, 9'b0};
                              B[9] <= 1'b1;
                          end else begin
                              B[9] <= 1'b0;
                          end
                        end 
                    end

                    EAU_STEP9: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin
                          if ({B[7:0], A} >= {TR, 8'b0}) begin
                              {B[7:0], A} <= {B[7:0], A} - {TR, 8'b0};
                              B[8] <= 1'b1;
                          end else begin
                              B[8] <= 1'b0;
                          end
                        end
                    end

                    EAU_STEP10: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin
                          if ({B[6:0], A} >= {TR, 7'b0}) begin
                              {B[6:0], A} <= {B[6:0], A} - {TR, 7'b0};
                              B[7] <= 1'b1;
                          end else begin
                              B[7] <= 1'b0;
                          end
                        end
                    end

                    EAU_STEP11: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin
                          if ({B[5:0], A} >= {TR, 6'b0}) begin
                              {B[5:0], A} <= {B[5:0], A} - {TR, 6'b0};
                              B[6] <= 1'b1;
                          end else begin
                              B[6] <= 1'b0; // You had 1'b1 here, likely typo
                          end
                        end
                    end

                    EAU_STEP12: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin
                          if ({B[4:0], A} >= {TR, 5'b0}) begin
                              {B[4:0], A} <= {B[4:0], A} - {TR, 5'b0};
                              B[5] <= 1'b1;
                          end else begin
                              B[5] <= 1'b0;
                          end
                        end
                    end

                    EAU_STEP13: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin
                          if ({B[3:0], A} >= {TR, 4'b0}) begin
                              {B[3:0], A} <= {B[3:0], A} - {TR, 4'b0};
                              B[4] <= 1'b1;
                          end else begin
                              B[4] <= 1'b0; 
                          end
                        end
                    end

                    EAU_STEP14: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin
                          if ({B[2:0], A} >= {TR, 3'b0}) begin
                              {B[2:0], A} <= {B[2:0], A} - {TR, 3'b0};
                              B[3] <= 1'b1;
                          end else begin
                              B[3] <= 1'b0;
                          end
                        end
                    end

                    EAU_STEP15: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin
                          if ({B[1:0], A} >= {TR, 2'b0}) begin
                              {B[1:0], A} <= {B[1:0], A} - {TR, 2'b0};
                              B[2] <= 1'b1;
                          end else begin
                              B[2] <= 1'b0;
                          end
                        end
                    end

                    EAU_STEP16: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin
                          if ({B[0], A} >= {TR, 1'b0}) begin
                              {B[0], A} <= {B[0], A} - {TR, 1'b0};
                              B[1] <= 1'b1;
                          end else begin
                              B[1] <= 1'b0;
                          end
                        end
                    end

                    EAU_STEP17: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin
                          if (A >= TR) begin
                              A <= A - TR;
                              B[0] <= 1'b1;
                          end else begin
                              B[0] <= 1'b0;
                          end
                        end
                    end

                    EAU_STEP18: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin
                          
                          if (B != 16'd0) begin
                            logic [15:0] temp; 
                            logic qs;
                            qs = ~((divisor_sign & dividend_sign) | (~divisor_sign & ~dividend_sign));
                            if (qs) begin
                                temp = ~B + 16'd1;
                                B <= temp;
                            end 
                            else begin
                              temp = B;
                            end 
                            if (temp[15] ^ qs) begin
                              OVERFLOW <= 1'b1; 
                            end                          
                          end

                          if (dividend_sign & (A[14:0] != 15'd0)) begin
                              A <= ~A + 16'd1;                            
                          end 
                          else begin
                              A[15] <= 1'b0;                            
                          end
                        end
                    end

                    EAU_STEP19: begin
                        if (~eau_divide_by_zero &  ~skip_to_end) begin  
                          A <= B;  // Swap around A and B  
                          B <= A;
                        end 
                        else begin
                          OVERFLOW <= 1'b1;
                        end
                    end
                    default: begin
                    end
                  endcase
                end 
                unique case (tstate)
                  T0: begin
                    CARRY <= 1'b0;
                  end
                  T1: begin
                    if (~eau_mem_ref | eau_dld | ((eau_mpy | eau_div) & (eau_phase == 2'd0))) begin
                      if (M== 15'o00000)
                        TR <= A;
                      else if (M== 15'o00001)
                        TR <= B;
                      else
                        TR <= mem_rdata;
                    end
                  end
                  T2: begin
                    if (eau_dst) begin
                      if (eau_phase == 2'd0) begin
                        TR <= A;                     
                      end
                      else if (eau_phase == 2'd1) begin
                        TR <= B; 
                      end

                    end
                    else begin
                      if (op4 == 4'o16)
                        TR <= A;
                      if (op4 == 4'o17)
                        TR <= B;
                      if (op4 == 4'o07)
                        TR <= TR + 16'o000001;
                      if (op4 == 4'o03)
                        TR <= {1'b0, (P + 15'o000001)};
                    end
                  end
                  T3: begin
                    if (eau_dst) begin
                      if ((M!= 15'o00000) && (M!= 15'o00001) && unprotected)
                      mem_we <= 1'b1;
                    end else if (eau_dld) begin
                      if (eau_phase == 2'd0) begin
                        A <= TR;  
                      end 
                      else if (eau_phase == 2'd1) begin
                        B <= TR; 
                      end
                    end
                    else begin
                      unique case (op4)
                        4'o00:
                          begin
                          end
                        4'o01:
                          begin
                          end
                        4'o02: // AND - And to A
                          A <= A & TR;
                        4'o03: //JSB - Jump to subroutine
                          if ((M!= 15'o00000) && (M!= 15'o00001) && unprotected)
                            if (mp_control_ff & mp_mev) begin
                              mp_interrupt_ff <= 1'b1;   
                            end
                            else mem_we <= 1'b1;
                        4'o04: // XOR
                          A <= A ^ TR;
                        4'o05: // JMP - Jump is handled in FETCH.
                          begin

                          end
                        4'o06: // IOR - Inclusive OR
                          A <= A | TR;
                        4'o07:  // ISZ - Inrement memory and skip if zero
                          if ((M!= 15'o00000) && (M!= 15'o00001) && unprotected)
                            if (mp_control_ff & mp_mev) begin
                              mp_interrupt_ff <= 1'b1;   
                            end
                            else mem_we <= 1'b1;
                        4'o10: // ADA - Add to A
                        begin
                          add_sum = {1'b0, A} + {1'b0, TR};
                          A <= add_sum[15:0];
                          if (add_sum[16] == 1'b1) EXTEND <= 1'b1;
                          if (((~(A[15] ^ TR[15])) & (A[15] ^ add_sum[15])) == 1'b1) OVERFLOW <= 1'b1;
                        end
                        4'o11: // ADB - Add to B
                        begin
                          add_sum = {1'b0, B} + {1'b0, TR};
                          B <= add_sum[15:0];
                          if (add_sum[16] == 1'b1) EXTEND <= 1'b1;
                          if (((~(B[15] ^ TR[15])) & (B[15] ^ add_sum[15])) == 1'b1) OVERFLOW <= 1'b1;
                        end
                        4'o12: // CPA - Compare A to memory - skip if not identical
                          begin
                            if (A != TR)
                              CARRY <= 1'b1;
                          end
                        4'o13:
                          begin // CPB - Compare B to memory - skip if not identical
                            if (B != TR)
                              CARRY <= 1'b1;
                          end
                        4'o14: // LDA - Load A from memory
                          A <= TR;
                        4'o15: // LDB - Load B from memory
                          B <= TR;
                        4'o16:
                          if ((M!= 15'o00000) && (M!= 15'o00001) && unprotected)
                            if (mp_control_ff & mp_mev) begin
                              mp_interrupt_ff <= 1'b1;   
                            end
                            else mem_we <= 1'b1;
                        4'o17:
                          if ((M!= 15'o00000) && (M!= 15'o00001) && unprotected)
                            if (mp_control_ff & mp_mev) begin
                              mp_interrupt_ff <= 1'b1;   
                            end
                            else mem_we <= 1'b1;
                      endcase
                    end
                  end
                  T4: begin
                    if ((~eau_dst & (op4 == 4'o16 | op4 == 4'o17 | op4 == 4'o07 || op4 == 4'o03)) | eau_dst ) begin
                      mem_we <= 1'b0;
                      if (M== 15'o00000) A <= TR;
                      if (M== 15'o00001) B <= TR;
                    end
                  end
                  T5: begin
                    if (~eau_mem_ref) begin
                      if (op4 == 4'o07)
                        if (TR == 16'o000000)
                          CARRY <= 1'b1;
                      if ( op4 == 4'o03)
                        P <= M;
                    end
                  end
                  T7: begin
                    // JMP and HALT are handled earlier and should
                    // therefore not be handled here.
                    //phase <= PH_FETCH;
                    if ((eau_dst | eau_dld) & (eau_phase == 2'd0)) begin
                      M <= M + 15'o00001;   
                    end else if ((eau_dst | eau_dld) & (eau_phase == 2'd1)) begin
                      M <= P + 15'o00001; 
                      P <= P + 15'o00001; 
                    end else if ((eau_mpy | eau_div) & ((eau_phase == 2'd0) | (eau_phase == 2'd1))) begin
                      // Do nothing
                    end 
                    else if (op4 == 4'o07 || op4 == 4'o12 || op4 == 4'o13) begin
                      P <= P + 15'o00001 + { 14'o0000, CARRY};
                      M <= P + 15'o00001 + { 14'o0000, CARRY};
                    end
                    else begin
                      P <= P + 15'o00001;
                      M <= P + 15'o00001;
                    end
                  end

                  default: begin
                    // Placeholder for future execute logic.
                  end
                endcase
              end

              // ---------------------------------------------------------------
              // INTERRUPT phase (stub)
              // ---------------------------------------------------------------
              PH_INTERRUPT: begin
                if (tstate == T7) begin
                  //phase <= PH_FETCH;
                  P <= P - 15'o00001;
                  if (mp_irq) begin
                    M <= 15'o000005;
                    central_interrupt_register <= 6'o05;                    
                  end
                  else if (dma_1_irq_ff) begin
                    M <= 15'o000006;
                    central_interrupt_register <= 6'o06;
                  end 
                  else if (dma_2_irq_ff) begin
                    M <= 15'o000007;
                    central_interrupt_register <= 6'o07;
                  end 
                  else if (irq10) begin
                    M <= 15'o000010;
                    central_interrupt_register <= 6'o10;
                  end
                  else if (irq11) begin
                    M <= 15'o000011;
                    central_interrupt_register <= 6'o11;
                  end
                  else if (irq12) begin
                    M <= 15'o000012; 
                    central_interrupt_register <= 6'o12;                                   
                  end
                  else if (irq16) begin
                    M <= 15'o000016;   
                    central_interrupt_register <= 6'o16;                                 
                  end
                  else if (irq17) begin
                    M <= 15'o000017;   
                    central_interrupt_register <= 6'o17;                                 
                  end                   
                  else if (irq20) begin
                    M <= 15'o000020;    
                    central_interrupt_register <= 6'o20;                                
                  end 
                  else if (irq22) begin
                    M <= 15'o000022;   
                    central_interrupt_register <= 6'o22;                                 
                  end                                    
                  else if (irq23) begin
                    M <= 15'o000023;                   
                    central_interrupt_register <= 6'o23;                 
                  end    
                end
              end


              default: begin
                if (tstate == T7) begin
                  //phase <= PH_FETCH;
                end
              end
            endcase
          end
          if (tstate == T4) begin
            if(clear_interrupt_control) begin
              Interrupt_Control <= 1'b0;
            end
          end
          if (tstate == T7) begin
            if (set_interrupt_control) Interrupt_Control <= 1'b1;
            dma_phase <= dma_1_cycle_request_ff | dma_2_cycle_request_ff;
            if (!dma_phase) begin
              if (interrupt & (~IR[5] | ~(is_jsb | is_jmp))) begin
                phase <= PH_INTERRUPT;
              end 
              else if (((eau_mem_ref & ind) | (is_mem_ref & ind)) & (phase == PH_INDIRECT || phase == PH_FETCH)) begin
                phase <= PH_INDIRECT;
              end
              else if (is_jmp & (phase == PH_INDIRECT || phase == PH_FETCH)) begin
                phase <= PH_FETCH;
              end 
              else if (phase == PH_INDIRECT) begin
                phase <= PH_EXECUTE;
              end 
              else if ((phase == PH_FETCH) && (is_mem_ref | eau_mem_ref)) begin
                phase <= PH_EXECUTE; 
              end 
              else if ((phase == PH_EXECUTE) && eau_mem_ref) begin
                if (eau_phase == 2'd0) begin
                  eau_phase <= 2'd1;
                end 
                else if (eau_phase == 2'd1) begin
                  if (eau_dst | eau_dld) begin
                    eau_phase <= 2'd0;    
                    eau_dst <= 1'b0;
                    eau_dld <= 1'b0;  
                    phase <= PH_FETCH;             
                  end 
                  else begin
                    eau_phase <= 2'd2;

                  end 
                end
                else if (eau_phase == 2'd2) begin
                  eau_phase <= 2'd0; 
                  eau_mpy <= 1'b0;
                  eau_div <= 1'b0;
                  phase <= PH_FETCH;
                end
              end
              else if ((phase == PH_FETCH) && is_mac_instr) begin
                phase <= PH_FETCH; // We stay in FETCH to get the opperand address with some special handling in FETCH
              end
              else begin
                phase <= PH_FETCH;  
              end
            end 
          end

                  //==================================================================
            // Free-running modulo-8 T-state counter
            //==================================================================
            // This is the central change. The T-state counter runs
            // freely as long as RUN is asserted, independent of phase.
          if (tstate == T7) begin
              tstate <= T0;

              // SINGLE CYCLE stops at the phase boundary after exactly one phase.
            if (step_started_by_sc && phase_step_armed) begin
                RUN                <= 1'b0;
                phase_step_armed   <= 1'b0;
                step_started_by_sc <= 1'b0;
            end
          end else begin
              tstate <= next_tstate(tstate);
          end
        end

      end
    end else begin
      clk_scale <= clk_scale + 5'd1;  
    end
  end

endmodule
