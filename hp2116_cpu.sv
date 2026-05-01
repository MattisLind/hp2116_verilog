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
  input  logic         stm32_fsmc_ne,
  input  logic         stm32_fsmc_nadv,
  input  logic         stm32_fsmc_nwe,
  input  logic         stm32_fsmc_noe,
  inout  logic [15:0]        stm32_fsmc_ad,
  output logic        stm32_irq,
  output logic        stm32_drq
);

  logic ptp_dummy;

  //--------------------------------------------------------------------------
  // Registers
  //--------------------------------------------------------------------------
  logic [15:0] A, B;
  logic [15:0] TR;          // Memory data buffer / T register
  logic [14:0] P;          // Program counter
  logic [14:0] M;          // Memory address register

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
  logic flgl11, flgl12, flgl13, flgl15, flgl16;
  logic sfc;
  logic irq10;
  logic clf;
  logic ien;
  logic stf;
  logic iak;
  logic t3;
  logic skf;
  logic flgh_dummy1, flgh_dummy2, flgh_dummy3, flgh_dummy4, flgh_dummy5, flgh_dummy6;

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
  logic srq10, srq11, srq12, srq13, srq14, srq15, srq16, srq17, srq20, srq21, srq22, srq23, srq24, srq25, srq26, srq27;
  logic [15:0] iob_out;
  logic [15:0] iob_in10, iob_in11, iob_in12, iob_in_internal, dummy, iob_in13, iob_in15, iob_in16;

  logic sir;
  logic enf;


  logic edt;
  logic pon;
  logic interrupt;

  logic crs;
  logic prl11;
  logic irq11, irq12, irq13, irq14, irq15, irq16;
  logic skf10, skf12, skf13, skf15, skf16;
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


  tstate_t tstate;

// HP12531C teleprinter interface
hp12531c serial (
  .clk(clk),
  .crs(crs),

  .prl(prl11),
  .flgl(flgl),
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

  .irqh(irqh_dummy1),
  .scl_h(1'b0),
  .scm_h(1'b0),

  .iob_out(iob_out),
  .iob_in(iob_in10),

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
  .prh(prl11),
  .ioi(ioi),
  .sfs(sfs),

  .irqh(irqh_dummy2),
  .scl_h(1'b0),
  .scm_h(1'b0),

  .iob_out(iob_out),
  .iob_in(iob_in11),

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
  .prh(prl12),
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
  .irql(irq13),
  .clf(clf),
  .ien(Interrupt_System_Enable),
  .stf(stf),
  .iak(iak),
  .t3(t3),
  .skf(skf13),

  .scm_l(msc1),
  .scl_l(lsc3),

  .iog(iog),
  .popio(popio | preset_btn),

  .iob16_or_bios_n(1'b0),

  .srq(srq13),
  .ioo(ioo),
  .clc(clc),
  .stc(stc),
  .prh(prl_out_from_12),
  .ioi(ioi),
  .sfs(sfs),

  .irqh(irq14),
  .scl_h(msc1),
  .scm_h(lsc4),

  .iob_out(iob_out),
  .iob_in(iob_in13),

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
  .irql(irq15),
  .clf(clf),
  .ien(Interrupt_System_Enable),
  .stf(stf),
  .iak(iak),
  .t3(t3),
  .skf(skf15),

  .scm_l(msc1),
  .scl_l(lsc5),

  .iog(iog),
  .popio(popio | preset_btn),

  .iob16_or_bios_n(1'b0),

  .srq(srq15),
  .ioo(ioo),
  .clc(clc),
  .stc(stc),
  .prh(prl_out_from_14),
  .ioi(ioi),
  .sfs(sfs),

  .irqh(irqh_dummy5),
  .scl_h(1'b0),
  .scm_h(1'b0),

  .iob_out(iob_out),
  .iob_in(iob_in15),

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
  .flag(ptp_dummy),
  .devicecommand(ptp_punch),
  .jumper_w4(1'b1),
  .jumper_w9(1'b0)
);


hp12539c tbg (
  .clk(clk),
  .crs(crs),

  .prl(prl),
  .flgl(flgl16),
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
  .prh(prl_out_from_15),
  .ioi(ioi),
  .sfs(sfs),

  .irqh(irqh_dummy6),
  .scl_h(1'b0),
  .scm_h(1'b0),

  .iob_out(iob_out),
  .iob_in(iob_in16),

  .sir(sir),
  .enf(enf),
  .flgh(flgh_dummy6),

  .run(RUN),

  .edt(edt),
  .pon(pon),
  .bioo_n(1'b0),
  .sfsb_or_bioi_n(1'b0),
  .jumper_w1("A"), //  Position A: Bit 5 is always 0.
  .jumper_w2("A") //  Position A: Normal mode

);

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
  logic        is_jmp;
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
    // The low address bits come from the T register.
    off10 = TR[9:0];
    normal_instruction_execution = ~(dma_phase || (phase == PH_INTERRUPT));
    // The current page comes from P[14:10].
    direct_addr = cz ? {P[14:10], off10} : {5'b00000, off10};

    // HALT decodes as 1020xx. Since IR only stores bits 15..10, it is enough
    // to compare against the top field.

    is_io_instr = (IR[5:2] == 4'o10) & IR[0];
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
    clear_interrupt_control = (((op4 == 4'o3)| (op4 == 4'o5)) & IR[5] ) | clear_control | set_control | clear_flag | set_flag | phase == PH_INTERRUPT ;
    set_interrupt_system_enable = set_flag & msc0 & lsc0;
    clear_interrupt_system_enable = clear_flag & msc0 & lsc0;
    iak = (tstate == T0) & (phase == PH_FETCH) & Interrupt_Control;
    is_jmp = (op4 == 4'o5);
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
    skip_io = skf10 | skf11 | skf12 | skf13 | skf15 | skf16 | skip_intp | skip_dma6 | skip_dma7;
    clf = ((clear_flag & normal_instruction_execution) | dma_clf) & state45;
    stf = set_flag & normal_instruction_execution & state45;
    stc = ((set_control & normal_instruction_execution)| dma_stc) & state34;
    clc = ((clear_control & normal_instruction_execution)| dma_clc) & state45;
    t3 = (tstate == T3);
    sir = (tstate == T5);
    enf = (tstate == T2);
    crs = clc & msc0 & lsc0 | popio;
    interrupt = (irq10 | irq11 | irq12 | irq13 | irq14 | irq15 | irq16 | dma_1_irq_ff | dma_2_irq_ff)  & Interrupt_System_Enable & Interrupt_Control;
    if ((M >= 15'o77700) && loader_protected_switch) begin
      unprotected = 1'b0;
    end else begin
      unprotected = 1'b1;
    end
    srq14 = 1'b0;
    srq17 = 1'b0;
    srq20 = 1'b0;
    srq21 = 1'b0;
    srq22 = 1'b0;
    srq23 = 1'b0;
    srq24 = 1'b0; 
    srq25 = 1'b0;
    srq26 = 1'b0;
    srq27 = 1'b0;       
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
            default: iob_in_internal = 16'o000000;

        endcase
    end
    else begin
      iob_in_internal = iob_in10 | iob_in11 | iob_in12 | iob_in13 | iob_in15 | iob_in16;
    end
end

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
  logic prh_in_to_dma_1, prl_out_from_dma_1, prh_in_to_dma_2, prl_out_from_dma_2, prl_out_from_12, prl_out_from_14, prl_out_from_15;
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
    prh_in_to_dma_1 = 1'b1;
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
    end else begin
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
    end else begin
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

    end else begin
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
                unique case (tstate)
                  T0: begin
                    // Load the program counter into M before the memory read.
                    //M <= P;
                    CARRY <= 1'b0;

                    Interrupt_Control <= 1'b1;
                  end

                  T1: begin
                    // Synchronous memory model: the instruction is read into T.
                    if (M== 15'o00000)
                      TR <= A;
                    else if (M== 15'o00001)
                      TR <= B;
                    else
                      TR <= mem_rdata;
                  end

                  T2: begin
                    // Latch instruction field T[15:10] into the I register.
                    IR <= TR[15:10];
                  end

                  T3: begin

                    if(set_interrupt_system_enable) begin
                      Interrupt_System_Enable <= 1'b1;
                    end
                    if (set_overflow) begin
                      OVERFLOW <= 1'b1;
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

                  T4: begin
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
                    if(clear_interrupt_control) begin
                      Interrupt_Control <= 1'b0;
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

                  T5: begin
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

                  T7: begin
                    // FETCH completes at T7.
                    // Normally P advances to the next sequential instruction.
                    if (is_halt_instr) begin
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
                unique case (tstate)
                  T0: begin
                    CARRY <= 1'b0;
                  end
                  T1: begin
                    if (M== 15'o00000)
                      TR <= A;
                    else if (M== 15'o00001)
                      TR <= B;
                    else
                      TR <= mem_rdata;
                  end
                  T2: begin
                    if (op4 == 4'o16)
                      TR <= A;
                    if (op4 == 4'o17)
                      TR <= B;
                    if (op4 == 4'o07)
                      TR <= TR + 16'o000001;
                    if (op4 == 4'o03)
                      TR <= {1'b0, (P + 15'o000001)};
                  end
                  T3: begin
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
                          mem_we <= 1'b1;
                      4'o04: // XOR
                        A <= A ^ TR;
                      4'o05: // JMP - Jump is handled in FETCH.
                        begin

                        end
                      4'o06: // IOR - Inclusive OR
                        A <= A | TR;
                      4'o07:  // ISZ - Inrement memory and skip if zero
                        if ((M!= 15'o00000) && (M!= 15'o00001) && unprotected)
                          mem_we <= 1'b1;
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
                          mem_we <= 1'b1;
                      4'o17:
                        if ((M!= 15'o00000) && (M!= 15'o00001) && unprotected)
                          mem_we <= 1'b1;
                    endcase
                  end
                  T4: begin
                    if (op4 == 4'o16 | op4 == 4'o17 | op4 == 4'o07 || op4 == 4'o03) begin
                      mem_we <= 1'b0;
                      if (M== 15'o00000) A <= TR;
                      if (M== 15'o00001) B <= TR;
                    end
                  end
                  T5: begin
                    if (op4 == 4'o07)
                      if (TR == 16'o000000)
                        CARRY <= 1'b1;
                    if ( op4 == 4'o03)
                      P <= M;
                  end
                  T7: begin
                    // JMP and HALT are handled earlier and should
                    // therefore not be handled here.
                    //phase <= PH_FETCH;
                    if (op4 == 4'o07 || op4 == 4'o12 || op4 == 4'o13) begin
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
                  if (dma_1_irq_ff) begin
                    M <= 15'o000006;
                  end 
                  else if (dma_2_irq_ff) begin
                    M <= 15'o000007;
                  end 
                  else if (irq10) begin
                    M <= 15'o000010;
                  end
                  else if (irq11) begin
                    M <= 15'o000011;
                  end
                  else if (irq12) begin
                    M <= 15'o000012;                                    
                  end
                  else if (irq13) begin
                    M <= 15'o000013;                                    
                  end
                  else if (irq14) begin
                    M <= 15'o000014;                                    
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
          if (tstate == T7) begin
            dma_phase <= dma_1_cycle_request_ff | dma_2_cycle_request_ff;
            if (!dma_phase) begin
              if (interrupt & phase != PH_INTERRUPT) begin
                phase <= PH_INTERRUPT;
              end 
              else if (is_mem_ref & ind & (phase == PH_INDIRECT || phase == PH_FETCH)) begin
                phase <= PH_INDIRECT;
              end
              else if (is_jmp & (phase == PH_INDIRECT || phase == PH_FETCH)) begin
                phase <= PH_FETCH;
              end 
              else if (phase == PH_INDIRECT) begin
                phase <= PH_EXECUTE;
              end 
              else if ((phase == PH_FETCH) && is_mem_ref) begin
                phase <= PH_EXECUTE; 
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
    end
  end

endmodule
