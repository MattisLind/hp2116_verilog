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
  input  logic         rst_n,

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
  output logic         ptr_read
);

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

  logic prl;
  logic flgl;
  logic sfc;
  logic irq10;
  logic clf;
  logic ien;
  logic stf;
  logic iak;
  logic t3;
  logic skf;

  logic popio;

  logic srq;
  logic ioo;
  logic clc;
  logic stc;
  logic prh;
  logic ioi;
  logic sfs;

  logic irqh;

  logic [15:0] iob_out;
  logic [15:0] iob_in10, iob_in11, iob_in_internal, dummy;

  logic sir;
  logic enf;
  logic flgh;

  logic edt;
  logic pon;
  logic interrupt;

  logic crs;
  logic prl11;
  logic irq11;
  logic skf10;
  logic skf11;

  assign run_ff = RUN;
  assign ien_ff = Interrupt_System_Enable;

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

  .iog(is_io_instr),
  .popio(popio),

  .iob16_or_bios_n(1'b0),

  .srq(srq),
  .ioo(ioo),
  .clc(clc),
  .stc(stc),
  .prh(1'b1),
  .ioi(ioi),
  .sfs(sfs),

  .irqh(irqh),
  .scl_h(1'b0),
  .scm_h(1'b0),

  .iob_out(iob_out),
  .iob_in(iob_in10),

  .sir(sir),
  .enf(enf),
  .flgh(flgh),

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

  .prl(prl),
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

  .iog(is_io_instr),
  .popio(popio),

  .iob16_or_bios_n(1'b0),

  .srq(srq),
  .ioo(ioo),
  .clc(clc),
  .stc(stc),
  .prh(prl11),
  .ioi(ioi),
  .sfs(sfs),

  .irqh(irqh),
  .scl_h(1'b0),
  .scm_h(1'b0),

  .iob_out(iob_out),
  .iob_in(iob_in11),

  .sir(sir),
  .enf(enf),
  .flgh(flgh),

  .run(RUN),

  .edt(edt),
  .pon(pon),
  .bioo_n(1'b0),
  .sfsb_or_bioi_n(1'b0),
  .datain(ptr_datain),
  .dataout(ptr_dataout),
  .feedhole(ptr_feedhole),
  .read(ptr_read)
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
    PH_INTERRUPT = 3'd3,
    PH_DMA       = 3'd4
  } phase_t;

  phase_t phase;

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
  logic        is_jmp;
  logic        msc0, msc1,msc2,msc3,msc4,msc5,msc6,msc7,lsc0,lsc1,lsc2,lsc3,lsc4,lsc5,lsc6,lsc7;
  logic        skip_on_overflow;
  logic        sfs_intp, sfc_intp, skip_intp, skip_io;

  logic set_control, clear_control, clear_flag, set_flag, set_overflow, clear_overflow, set_interrupt_control, clear_interrupt_control, set_interrupt_system_enable, clear_interrupt_system_enable;
  always_comb begin
    // The decoder uses the I register (IR) for the control field.
    op4 = IR[4:1];
    cz  = IR[0];
    ind = TR[15];

    // The low address bits come from the T register.
    off10 = TR[9:0];

    // The current page comes from P[14:10].
    direct_addr = cz ? {P[14:10], off10} : {5'b00000, off10};

    // HALT decodes as 1020xx. Since IR only stores bits 15..10, it is enough
    // to compare against the top field.

    is_io_instr = (IR[5:2] == 4'o10) & IR[0];
    is_mac_instr = (IR[5:2] == 4'o10) & ~IR[0];
    is_srg_instr = (IR[5:2] == 4'o00) & ~IR[0];  // Shift / Rotate group
    is_asg_instr = (IR[5:2] == 4'o00) & IR[0];  // Alter / Skip group
    is_halt_instr = is_io_instr & (TR[8:6] == 3'o0);
    msc0 = TR[5:3] == 3'o0;
    msc1 = TR[5:3] == 3'o1;
    msc2 = TR[5:3] == 3'o2;
    msc3 = TR[5:3] == 3'o3;
    msc4 = TR[5:3] == 3'o4;
    msc5 = TR[5:3] == 3'o5;
    msc6 = TR[5:3] == 3'o6;
    msc7 = TR[5:3] == 3'o7;
    lsc0 = TR[2:0] == 3'o0;
    lsc1 = TR[2:0] == 3'o1;
    lsc2 = TR[2:0] == 3'o2;
    lsc3 = TR[2:0] == 3'o3;
    lsc4 = TR[2:0] == 3'o4;
    lsc5 = TR[2:0] == 3'o5;
    lsc6 = TR[2:0] == 3'o6;
    lsc7 = TR[2:0] == 3'o7;
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
    ioo = tstate[1] & ~tstate[0] & (TR[8:6] == 3'o6);
    ioi = tstate[2] &  tstate[1] & ((TR[8:6] == 3'o5) | (TR[8:6] == 3'o4));
    iob_out = ioo ? (IR[0] ? A : B) : 16'h0000;
    sfs = is_io_instr & (TR[8:6] == 3'o3);
    sfc = is_io_instr & (TR[8:6] == 3'o2);
    sfs_intp = sfs & msc0 & lsc0 & Interrupt_System_Enable;
    sfc_intp = sfc & msc0 & lsc0 & ~Interrupt_System_Enable;
    skip_intp = sfc_intp | sfs_intp;
    skip_io = skf10 | skf11 | skip_intp ;
    clf = clear_flag & (tstate == T4);
    stf = set_flag & (tstate == T3);
    stc = set_control & (tstate == T4);
    clc = clear_control & (tstate == T4);
    t3 = (tstate == T3);
    sir = (tstate == T5);
    enf = (tstate == T2);
    crs = clc & msc0 & lsc0 | popio;
    interrupt = irq10 & Interrupt_System_Enable & Interrupt_Control;
  end

always @* begin
    // Default value to avoid latches
    iob_in_internal = 16'h0000;

    // Special case: internal select codes 00-07 (and any reserved values)
    if (TR[5:0] < 6'o10) begin
        case (TR[5:0])
            6'o01: iob_in_internal = sw;
            default: iob_in_internal = 16'h0000;
        endcase
    end
    else begin
      iob_in_internal = iob_in10 | iob_in11;
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
    mem_addr  = M;
    mem_wdata = TR;
  end

  //--------------------------------------------------------------------------
  // One-shot edge detection for RUN and SINGLE CYCLE
  //--------------------------------------------------------------------------
  logic run_btn_d;
  logic sc_btn_d;

  logic run_press;
  logic sc_press;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
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
  always_ff @(posedge clk or negedge rst_n) begin
    logic [16:0] add_sum;
    add_sum = '0;
    if (!rst_n) begin
      A <= 16'o000000;
      B <= 16'o000000;
      TR <= 16'o000000;
      P <= 15'o00000;
      M <= 15'o00000;

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
      popio <= 1'b1;

    end else begin
      // Default is no memory write in this cycle.
      mem_we <= 1'b0;
      popio <= 1'b0;
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
      if (preset_btn) begin
        phase  <= PH_FETCH;
        tstate <= T0;
        Interrupt_System_Enable    <= 1'b0;
        popio <= 1'b1;
        RUN    <= 1'b0;

        phase_step_armed   <= 1'b0;
        step_started_by_sc <= 1'b0;
      end else begin
        popio <= 1'b0;
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
                    endcase
                  end
                  case (TR[5:0])
                    6'o01: begin
                      //sw <= iob_out;
                    end
                  endcase
                end

                T7: begin
                  // FETCH completes at T7.
                  // Normally P advances to the next sequential instruction.
                  if (interrupt) begin
                    phase <= PH_INTERRUPT;
                  end
                  else if (is_halt_instr) begin
                    RUN   <= 1'b0;
                    M <= P + 15'o00001;
                    P <= P + 15'o00001;
                    phase <= PH_FETCH;
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
                    phase <= PH_FETCH;
                  end
                  // An indirect JMP proceeds to the indirect phase.
                  else if (is_jmp && ind) begin
                    M     <= direct_addr;
                    phase <= PH_INDIRECT;
                  end
                  // Other indirect memory-reference instructions
                  // also proceed through the indirect phase.
                  else if (ind) begin
                    //P <= P + 15'o00001;
                    M     <= direct_addr;
                    phase <= PH_INDIRECT;
                  end

                  else begin
                    // Direct-addressed instructions get their effective
                    // address in M and then move to execute.

                    M     <= direct_addr;
                    phase <= PH_EXECUTE;
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
                    phase <= PH_INDIRECT;
                  end
                  else if (is_jmp) begin
                    P     <= TR[14:0];
                    phase <= PH_FETCH;
                  end else begin
                    phase <= PH_EXECUTE;
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
                      if ((M!= 15'o00000) && (M!= 15'o00001))
                        mem_we <= 1'b1;
                    4'o04: // XOR
                      A <= A ^ TR;
                    4'o05: // JMP - Jump is handled in FETCH.
                      begin

                      end
                    4'o06: // IOR - Inclusive OR
                      A <= A | TR;
                    4'o07:  // ISZ - Inrement memory and skip if zero
                      if ((M!= 15'o00000) && (M!= 15'o00001))
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
                      if ((M!= 15'o00000) && (M!= 15'o00001))
                        mem_we <= 1'b1;
                    4'o17:
                      if ((M!= 15'o00000) && (M!= 15'o00001))
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
                  phase <= PH_FETCH;
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
                phase <= PH_FETCH;
                P <= P - 15'o00001;
                if (irq10) begin
                  M <= 15'o000010;
                end
              end
            end

            // ---------------------------------------------------------------
            // DMA phase (stub)
            // ---------------------------------------------------------------
            PH_DMA: begin
              if (tstate == T7) begin
                phase <= PH_FETCH;
              end
            end

            default: begin
              if (tstate == T7) begin
                phase <= PH_FETCH;
              end
            end
          endcase

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
