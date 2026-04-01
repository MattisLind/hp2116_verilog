`timescale 1ns/1ps

module hp12531c #(
  parameter int unsigned CLOCK_HZ  = 50_000_000,
  parameter int unsigned BAUD      = 110,
  parameter int unsigned STOP_BITS = 2
) (
  input  logic         clk,
  input  logic         rst_n,

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
  input  logic         crs,

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

  output logic [15:0]  iob_out,
  input  logic [15:0]  iob_in,

  input  logic         sir,
  input  logic         enf,
  output logic         flgh,

  inout  logic         run,

  output logic         edt,
  input  logic         pon,
  input  logic         bioo_n,
  input  logic         sfsb_or_bioi_n
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
  // Internal state
  //--------------------------------------------------------------------------
  logic        flag_ff;
  logic        control_ff;
  logic        inout_ff;      // Kodkommentar: 1=input, 0=output.
  logic        print_ff;
  logic        punch_ff;

  // Kodkommentar: Delat dataregister för både input och output.
  logic [7:0]  data_reg;

  // Kodkommentar: Håller senaste kontrollord för debug/vidare utbyggnad.
  logic [15:0] control_word;

  //--------------------------------------------------------------------------
  // Simplified teleprinter-side state
  //--------------------------------------------------------------------------
  logic        tx_active;
  logic        rx_active;
  logic        rx_armed;

  logic [10:0] tx_shift_reg;
  logic [3:0]  tx_bits_left;
  logic [31:0] tx_baud_cnt;

  logic [7:0]  rx_shift_reg;
  logic [2:0]  rx_bit_index;
  logic [31:0] rx_baud_cnt;
  logic [1:0]  rx_stop_count;

  // Kodkommentar: Förenklad seriell linje internt. I denna första version
  // finns ingen separat yttre teleprinterport på modulgränssnittet.
  logic        teleprinter_rx;
  logic        teleprinter_tx;

  //--------------------------------------------------------------------------
  // Baud timing
  //--------------------------------------------------------------------------
  localparam int unsigned BAUD_DIV      = (BAUD > 0) ? (CLOCK_HZ / BAUD) : 1;
  localparam int unsigned HALF_BAUD_DIV = (BAUD_DIV > 1) ? (BAUD_DIV / 2) : 1;

  //--------------------------------------------------------------------------
  // Helper wires
  //--------------------------------------------------------------------------
  logic irq_pending;
  logic skip_true;

  always_comb begin
    // Kodkommentar: Enheten begär interrupt när både control och flag är satta
    // och CPU:n har interrupt enable aktiv.
    irq_pending = control_ff && flag_ff && ien;

    // Kodkommentar: Skip om SFS och flag=1, eller SFC och flag=0.
    skip_true = (do_sfs && flag_ff) || (do_sfc && !flag_ff);
  end

  //--------------------------------------------------------------------------
  // Backplane outputs
  //--------------------------------------------------------------------------
  always_comb begin
    // Kodkommentar: I denna första modell driver vi bara lägre flagglinje.
    flgl = flag_ff;
    flgh = 1'b0;

    // Kodkommentar: Skip-ledningen drivs endast när kortet är valt.
    skf  = skip_true;

    // Kodkommentar: Service request / interrupt request från kortet.
    srq  = irq_pending;
    irql = irq_pending;

    // Kodkommentar: PRL lämnas tills vidare som enkel vidarekoppling av PRH.
    // Detta är en förenkling som kan göras mer trogen senare.
    prl  = prh;

    // Kodkommentar: EDT används inte i denna modell.
    edt  = 1'b0;
  end

  //--------------------------------------------------------------------------
  // Bus readback
  //
  // Kodkommentar: Vid IOI återlämnas ett 16-bitars ord där lågbyte är
  // dataregistret och några statusbitar läggs i övre delen.
  //
  // bit 15 = 0 (för att skilja från kontrollord vid skrivning)
  // bit 14 = inout_ff
  // bit 13 = print_ff
  // bit 12 = punch_ff
  // bit 11 = control_ff
  // bit 10 = flag_ff
  // bit  9 = irq_pending
  // bit  7:0 = data_reg
  //--------------------------------------------------------------------------
  always_comb begin
    iob_out = 16'h0000;

    if (do_ioi) begin
      iob_out[15]   = 1'b0;
      iob_out[14]   = inout_ff;
      iob_out[13]   = print_ff;
      iob_out[12]   = punch_ff;
      iob_out[11]   = control_ff;
      iob_out[10]   = flag_ff;
      iob_out[9]    = irq_pending;
      iob_out[7:0]  = data_reg;
    end
  end

  //--------------------------------------------------------------------------
  // Helper tasks
  //--------------------------------------------------------------------------
  task automatic start_tx();
    int i;
    begin
      // Kodkommentar: Dataregistret sänds seriellt med 1 startbit, 8 databitar
      // och STOP_BITS stopbitar. LSB sänds först.
      tx_shift_reg = '0;
      tx_shift_reg[0] = 1'b0;

      for (i = 0; i < 8; i++) begin
        tx_shift_reg[i+1] = data_reg[i];
      end

      for (i = 0; i < STOP_BITS; i++) begin
        tx_shift_reg[9+i] = 1'b1;
      end

      tx_bits_left = 4'(1 + 8 + STOP_BITS);
      tx_baud_cnt  = BAUD_DIV - 1;
      tx_active    = 1'b1;
      rx_active    = 1'b0;
      rx_armed     = 1'b0;

      // Kodkommentar: Startad överföring nollställer flaggan.
      flag_ff      <= 1'b0;
    end
  endtask

  task automatic arm_rx();
    begin
      // Kodkommentar: Input-operationen gör kortet mottagningsberett.
      rx_armed      <= 1'b1;
      rx_active     <= 1'b0;
      tx_active     <= 1'b0;

      rx_shift_reg  <= 8'h00;
      rx_bit_index  <= 3'd0;
      rx_baud_cnt   <= 32'd0;
      rx_stop_count <= 2'd0;

      // Kodkommentar: Startad input-operation nollställer flaggan.
      flag_ff       <= 1'b0;
    end
  endtask

  //--------------------------------------------------------------------------
  // Main sequential logic
  //--------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      flag_ff       <= 1'b0;
      control_ff    <= 1'b0;
      inout_ff      <= 1'b0;
      print_ff      <= 1'b0;
      punch_ff      <= 1'b0;
      data_reg      <= 8'h00;
      control_word  <= 16'h0000;

      tx_active     <= 1'b0;
      rx_active     <= 1'b0;
      rx_armed      <= 1'b0;

      tx_shift_reg  <= 11'h7FF;
      tx_bits_left  <= 4'd0;
      tx_baud_cnt   <= 32'd0;

      rx_shift_reg  <= 8'h00;
      rx_bit_index  <= 3'd0;
      rx_baud_cnt   <= 32'd0;
      rx_stop_count <= 2'd0;

      teleprinter_tx <= 1'b1;
      teleprinter_rx <= 1'b1;
    end else begin
      //----------------------------------------------------------------------
      // Global reset-like actions
      //----------------------------------------------------------------------
      if (popio || pon || crs) begin
        flag_ff        <= 1'b0;
        control_ff     <= 1'b0;
        inout_ff       <= 1'b0;
        print_ff       <= 1'b0;
        punch_ff       <= 1'b0;

        tx_active      <= 1'b0;
        rx_active      <= 1'b0;
        rx_armed       <= 1'b0;

        tx_bits_left   <= 4'd0;
        tx_baud_cnt    <= 32'd0;
        rx_bit_index   <= 3'd0;
        rx_baud_cnt    <= 32'd0;
        rx_stop_count  <= 2'd0;

        teleprinter_tx <= 1'b1;
      end else begin
        //--------------------------------------------------------------------
        // Simple flip-flop controls
        //--------------------------------------------------------------------
        if (do_clf) flag_ff <= 1'b0;
        if (do_stf) flag_ff <= 1'b1;

        if (do_clc) begin
          control_ff <= 1'b0;
          tx_active  <= 1'b0;
          rx_active  <= 1'b0;
          rx_armed   <= 1'b0;
        end

        if (do_stc) begin
          // Kodkommentar: STC sätter control_ff och startar vald operation.
          control_ff <= 1'b1;

          if (inout_ff) begin
            arm_rx();
          end else begin
            start_tx();
          end
        end

        //--------------------------------------------------------------------
        // IOO write path
        //--------------------------------------------------------------------
        if (do_ioo) begin
          if (iob_in[15]) begin
            // Kodkommentar: Bit 15 = 1 betyder kontrollord enligt manualen.
            control_word <= iob_in;

            // Kodkommentar: Bit 14 = 1 input, 0 output.
            inout_ff <= iob_in[14];

            // Kodkommentar: Bit 13 = print, bit 12 = punch.
            print_ff <= iob_in[13];
            punch_ff <= iob_in[12];
          end else begin
            // Kodkommentar: Dataord. Lågbyte laddas i det gemensamma dataregistret.
            data_reg <= iob_in[7:0];
          end
        end

        //--------------------------------------------------------------------
        // IOI read path side effects
        //--------------------------------------------------------------------
        if (do_ioi) begin
          // Kodkommentar: Första approximation:
          // läsning av data i inputläge tömmer flaggan.
          if (inout_ff) begin
            flag_ff <= 1'b0;
          end
        end

        //--------------------------------------------------------------------
        // IAK side effect
        //--------------------------------------------------------------------
        if (iak && irq_pending) begin
          // Kodkommentar: I denna förenklade modell ändras inget extra här.
        end

        //--------------------------------------------------------------------
        // Simplified transmitter
        //--------------------------------------------------------------------
        if (tx_active) begin
          teleprinter_tx <= tx_shift_reg[0];

          if (tx_baud_cnt != 0) begin
            tx_baud_cnt <= tx_baud_cnt - 1;
          end else begin
            tx_shift_reg <= {1'b1, tx_shift_reg[10:1]};

            if (tx_bits_left > 1) begin
              tx_bits_left <= tx_bits_left - 1;
              tx_baud_cnt  <= BAUD_DIV - 1;
            end else begin
              tx_active      <= 1'b0;
              tx_bits_left   <= 4'd0;
              teleprinter_tx <= 1'b1;

              // Kodkommentar: När ett tecken sänts färdigt sätts flaggan.
              flag_ff        <= 1'b1;
            end
          end
        end else begin
          teleprinter_tx <= 1'b1;
        end

        //--------------------------------------------------------------------
        // Simplified receiver
        //
        // Kodkommentar: I denna version finns ingen extern seriell ingångspinne
        // på modulgränssnittet, så teleprinter_rx lämnas vilande. Logiken finns
        // ändå kvar som stomme för fortsatt arbete.
        //--------------------------------------------------------------------
        if (rx_armed && !rx_active) begin
          if (teleprinter_rx == 1'b0) begin
            rx_armed      <= 1'b0;
            rx_active     <= 1'b1;
            rx_bit_index  <= 3'd0;
            rx_baud_cnt   <= HALF_BAUD_DIV;
            rx_stop_count <= 2'd0;
          end
        end else if (rx_active) begin
          if (rx_baud_cnt != 0) begin
            rx_baud_cnt <= rx_baud_cnt - 1;
          end else begin
            if (rx_bit_index < 8) begin
              rx_shift_reg[rx_bit_index] <= teleprinter_rx;
              rx_bit_index               <= rx_bit_index + 1'b1;
              rx_baud_cnt                <= BAUD_DIV - 1;
            end else if (rx_stop_count < STOP_BITS) begin
              rx_stop_count <= rx_stop_count + 1'b1;
              rx_baud_cnt   <= BAUD_DIV - 1;

              if (rx_stop_count == STOP_BITS-1) begin
                rx_active <= 1'b0;
                data_reg  <= rx_shift_reg;
                flag_ff   <= 1'b1;
              end
            end
          end
        end
      end
    end
  end

endmodule