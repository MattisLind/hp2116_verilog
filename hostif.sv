// hostif.sv
//
// Simple UART host interface for simulation.
// - Receives UART data from DUT on serial_out and forwards bytes to C via DPI-C.
// - Reads bytes from C (stdin) via DPI-C and transmits them to DUT on serial_in.
//
// Assumptions:
// - 8 data bits
// - No parity
// - STOP_BITS stop bits
// - Idle line level is logic 1
//
// Note:
// - This is intended for simulation, not synthesis.
// - The module name and parameter list match the requested instantiation.

module hostif #(
  parameter int CLOCK_HZ  = 50_000_000,
  parameter int BAUD      = 115200,
  parameter int STOP_BITS = 1
)(
  input  logic clk,
  input  logic crs,         // Global reset, assumed active-high
  output logic serial_in,   // Host -> DUT (UART RX of DUT)
  input  logic serial_out   // DUT -> Host (UART TX of DUT)
);

  // ------------------------------------------------------------
  // DPI-C imports
  // ------------------------------------------------------------
  //
  // hostif_putc:
  //   Called whenever a full byte has been received from serial_out.
  //
  // hostif_getc_nonblock:
  //   Returns:
  //     -1 if no input byte is available
  //     0..255 for a valid byte from stdin
  //
  import "DPI-C" function void hostif_putc(input int ch);
  import "DPI-C" function int  hostif_getc_nonblock();

  // ------------------------------------------------------------
  // UART timing
  // ------------------------------------------------------------
  localparam int CLKS_PER_BIT = CLOCK_HZ / BAUD;

  // ------------------------------------------------------------
  // UART RX: monitor serial_out and reconstruct bytes
  // ------------------------------------------------------------
  typedef enum logic [2:0] {
    RX_IDLE,
    RX_START,
    RX_DATA,
    RX_STOP
  } rx_state_t;

  rx_state_t rx_state;

  int         rx_clk_count;
  int         rx_bit_index;
  int         rx_stop_count;
  logic [7:0] rx_shift;

  // ------------------------------------------------------------
  // UART TX: drive serial_in with bytes read from C/stdin
  // ------------------------------------------------------------
  typedef enum logic [2:0] {
    TX_IDLE,
    TX_START,
    TX_DATA,
    TX_STOP
  } tx_state_t;

  tx_state_t   tx_state;

  int          tx_clk_count;
  int          tx_bit_index;
  int          tx_stop_count;
  logic [7:0]  tx_shift;

  // ------------------------------------------------------------
  // Reset and main sequential logic
  // ------------------------------------------------------------
  always_ff @(posedge clk or posedge crs) begin
    int          tx_next_char;
    if (crs) begin
      // ---------------------------
      // RX reset
      // ---------------------------
      rx_state      <= RX_IDLE;
      rx_clk_count  <= 0;
      rx_bit_index  <= 0;
      rx_stop_count <= 0;
      rx_shift      <= 8'h00;

      // ---------------------------
      // TX reset
      // ---------------------------
      tx_state      <= TX_IDLE;
      tx_clk_count  <= 0;
      tx_bit_index  <= 0;
      tx_stop_count <= 0;
      tx_shift      <= 8'h00;
      tx_next_char  <= -1;

      // UART idle level is high
      serial_in     <= 1'b1;
    end else begin
      // ==========================================================
      // RX FSM
      // ==========================================================
      case (rx_state)
        RX_IDLE: begin
          // Wait for start bit on serial_out (line goes low)
          if (serial_out == 1'b0) begin
            rx_clk_count <= 0;
            rx_state     <= RX_START;
          end
        end

        RX_START: begin
          // Sample in the middle of the start bit
          if (rx_clk_count == (CLKS_PER_BIT/2)) begin
            if (serial_out == 1'b0) begin
              // Valid start bit
              rx_clk_count <= 0;
              rx_bit_index <= 0;
              rx_state     <= RX_DATA;
            end else begin
              // False start, go back to idle
              rx_state <= RX_IDLE;
            end
          end else begin
            rx_clk_count <= rx_clk_count + 1;
          end
        end

        RX_DATA: begin
          // Sample each data bit once per bit time
          if (rx_clk_count == CLKS_PER_BIT-1) begin
            rx_clk_count <= 0;

            // LSB-first UART format
            rx_shift[rx_bit_index] <= serial_out;

            if (rx_bit_index == 7) begin
              rx_bit_index  <= 0;
              rx_stop_count <= 0;
              rx_state      <= RX_STOP;
            end else begin
              rx_bit_index <= rx_bit_index + 1;
            end
          end else begin
            rx_clk_count <= rx_clk_count + 1;
          end
        end

        RX_STOP: begin
          // Ignore stop bit value here; just wait STOP_BITS bit times
          if (rx_clk_count == CLKS_PER_BIT-1) begin
            rx_clk_count <= 0;

            if (rx_stop_count == STOP_BITS-1) begin
              // Full byte received: send it to C/stdout
              hostif_putc({24'b0, rx_shift});
              rx_state <= RX_IDLE;
            end else begin
              rx_stop_count <= rx_stop_count + 1;
            end
          end else begin
            rx_clk_count <= rx_clk_count + 1;
          end
        end

        default: begin
          rx_state <= RX_IDLE;
        end
      endcase

      // ==========================================================
      // TX FSM
      // ==========================================================
      case (tx_state)
        TX_IDLE: begin
          // Keep line high while idle
          serial_in <= 1'b1;

          // Poll C for a pending byte from stdin
          tx_next_char = hostif_getc_nonblock();

          if (tx_next_char >= 0) begin
            tx_shift      <= tx_next_char[7:0];
            tx_clk_count  <= 0;
            tx_bit_index  <= 0;
            tx_stop_count <= 0;
            tx_state      <= TX_START;
          end
        end

        TX_START: begin
          // Send start bit
          serial_in <= 1'b0;

          if (tx_clk_count == CLKS_PER_BIT-1) begin
            tx_clk_count <= 0;
            tx_state     <= TX_DATA;
          end else begin
            tx_clk_count <= tx_clk_count + 1;
          end
        end

        TX_DATA: begin
          // Send data bits LSB first
          serial_in <= tx_shift[tx_bit_index];

          if (tx_clk_count == CLKS_PER_BIT-1) begin
            tx_clk_count <= 0;

            if (tx_bit_index == 7) begin
              tx_bit_index <= 0;
              tx_state     <= TX_STOP;
            end else begin
              tx_bit_index <= tx_bit_index + 1;
            end
          end else begin
            tx_clk_count <= tx_clk_count + 1;
          end
        end

        TX_STOP: begin
          // Send stop bit(s)
          serial_in <= 1'b1;

          if (tx_clk_count == CLKS_PER_BIT-1) begin
            tx_clk_count <= 0;

            if (tx_stop_count == STOP_BITS-1) begin
              tx_state <= TX_IDLE;
            end else begin
              tx_stop_count <= tx_stop_count + 1;
            end
          end else begin
            tx_clk_count <= tx_clk_count + 1;
          end
        end

        default: begin
          tx_state  <= TX_IDLE;
          serial_in <= 1'b1;
        end
      endcase
    end
  end

endmodule
