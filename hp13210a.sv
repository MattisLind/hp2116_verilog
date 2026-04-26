`timescale 1ns/1ps

module hp13210a #(
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
  input  logic         stm32_fsmc_ne,
  input  logic         stm32_fsmc_nadv,
  input  logic         stm32_fsmc_nwe,
  input  logic         stm32_fsmc_noe,
  inout  logic  [15:0] stm32_fsmc_ad,
  output logic         stm32_irq, 
  output logic         stm32_drq
);

  //--------------------------------------------------------------------------
  // Selection / decoded local strobes
  //--------------------------------------------------------------------------
  logic dsel,csel;


  //--------------------------------------------------------------------------
  // Internal state
  //--------------------------------------------------------------------------
  logic        data_channel_flag_ff;
  logic        data_channel_flag_buffer_ff;
  logic        command_channel_flag_ff;
  logic        command_channel_flag_buffer_ff;  
  logic        command_channel_control_ff;
  logic        data_channel_encode_ff;
  logic        command_channel_encode_ff;
  logic        irq_ff;
  logic        [1:0] drive_select_register; 
  logic        protected_cylinder_register;
  logic        defective_cylinder_register;
  logic        first_status, overrun, drive_unsafe, data_protect, seek_check, not_ready, end_of_cylinder, address_error;
  logic        flagged_cylinder, drive_busy, data_error, any_error;
  logic        [3:0] attention_input_register;
  logic        data_op;
  logic        drv0_sel, drv1_sel, drv2_sel, drv3_sel;
  logic        [3:0] address_register;   // internal address register used by the micro controller to access internal registers.
  logic        [15:0] data_interface_output_buffer_register; // data going from host to drive
  logic        [15:0] data_interface_input_buffer_register; // data going from drive to host
  logic        cmd_status, cmd_cd;
  logic        eow, sk_set_dflag, gate_status;
  logic        [3:0] command_register;
  logic        hp7900_data_n_status;
  logic        stm32_data_access;
  logic        stm32_status_access;
  logic        stm32_read_csr;
  logic        stm32_write_csr;
  logic        stm32_irq_ff;
  logic        stm32_data_channel_irq_ff;
  logic        stm32_data_channel_irq_enable;
  logic        stm32_7900_command_status_access;
  logic        stm32_read_7900_command_status;
  logic        stm32_write_7900_command_status;
  logic        stm32_write_7900_command_status_delayed;
  logic        stm32_write_7900_command_status_negedge;
  logic        stm32_write_7900_command_status_registered;
  logic        stm32_7900_data_access;
  logic        stm32_read_7900_data;
  logic        stm32_read_7900_data_registered;
  logic        stm32_read_7900_data_delayed;
  logic        stm32_read_7900_data_negedge;
  logic        stm32_write_7900_data;
  logic        stm32_write_7900_data_registered;
  logic        stm32_write_7900_data_delayed;
  logic        stm32_write_7900_data_negedge;
  logic        stm32_irq_enable;
  logic        set_data_channel_flag_buffer;
  logic        command_channel_control_ff_delayed;
  logic        stm32_write_7900_attention;
  logic        stm32_read_7900_attention;
  logic        stm32_7900_attention_access;
  logic        stm32_write_7900_attention_delayed;
  logic        stm32_write_7900_attention_negedge;
  logic        stm32_write_7900_attention_registered;
  logic        stm32_read_csr_negedge;
  logic        stm32_read_csr_delayed;
  logic        stm32_read_csr_registered;
  logic        stc_data_channel; 
  logic        stc_data_channel_delayed;
  logic        stc_data_channel_negedge;
  logic        seek_record_command;
  logic        status_check_command;

  localparam logic [3:0] STM32_REG_CSR                     = 4'h00;
  localparam logic [3:0] STM32_REG_7900_COMMAND_STATUS     = 4'h02;
  localparam logic [3:0] STM32_REG_7900_DATA               = 4'h04;
  localparam logic [3:0] STM32_REG_7900_ATTENTION          = 4'h06;
  //localparam logic [3:0] STM32_REG_DATA       = 4'h0c;
  //localparam logic [3:0] STM32_REG_IRQ_STATUS = 4'h0e;

  //--------------------------------------------------------------------------
  // Backplane outputs
  //--------------------------------------------------------------------------
  always_comb begin

    //strobe_attention 
    data_op = 1'b1; 
    any_error = data_error | seek_check | drive_busy | address_error | drive_unsafe | overrun | end_of_cylinder | drive_busy | first_status;

    dsel  = iog && scm_l && scl_l;
    csel  = iog && scm_h && scl_h;

    // In this first model only the lower flag line is driven.
    flgl = 1'b0;
    flgh = irq_ff;
    irqh = irq_ff;
    prl = prh & ~(command_channel_flag_ff & ien & command_channel_control_ff);
    irql = 1'b0;
    srq = data_channel_flag_ff;
    eow = 1'b1;
    sk_set_dflag = 1'b0;
    gate_status = 1'b0;

    // The skip line is driven only when the card is selected.
    skf  = (data_channel_flag_ff & sfs & dsel) | (~data_channel_flag_ff & sfc & dsel) | (command_channel_flag_ff & sfs & csel) | (~command_channel_flag_ff & sfc & csel);

    // Either we supply data through the data channel from the status register or from the data buffer register

    iob_in = 16'h0000;
    if (dsel & ioi & ~hp7900_data_n_status) iob_in [15:0] = { 1'b0, first_status, overrun, 1'b0, drive_unsafe, data_protect, 1'b0, seek_check, 1'b0, not_ready, end_of_cylinder, address_error, flagged_cylinder, drive_busy, data_error, any_error};
    if (dsel & ioi & hp7900_data_n_status) iob_in [15:0] = data_interface_input_buffer_register;


    if (ioi & csel) iob_in [15:0] = {12'b000000000000, attention_input_register};

    drv0_sel = ~drive_select_register[0] & ~drive_select_register[1];
    drv1_sel = ~drive_select_register[0] & drive_select_register[1];
    drv2_sel = drive_select_register[0] & ~drive_select_register[1];
    drv3_sel = drive_select_register[0] & drive_select_register[1];

    stm32_data_access = stm32_fsmc_nadv & ~stm32_fsmc_ne;

    stm32_status_access = stm32_data_access & (address_register == STM32_REG_CSR);
    stm32_read_csr = ~stm32_fsmc_noe & stm32_status_access;
    stm32_write_csr = ~stm32_fsmc_nwe & stm32_status_access;

    stm32_read_csr_negedge = ~stm32_read_csr_registered & stm32_read_csr_delayed;
    stm32_fsmc_ad[7] = stm32_read_csr & stm32_irq_ff;
    stm32_fsmc_ad[6] = stm32_read_csr &  stm32_data_channel_irq_ff;

    stm32_7900_command_status_access = stm32_data_access & (address_register == STM32_REG_7900_COMMAND_STATUS);
    stm32_read_7900_command_status = stm32_7900_command_status_access & ~stm32_fsmc_noe;
    stm32_write_7900_command_status = stm32_7900_command_status_access & ~stm32_fsmc_nwe;
    
    stm32_write_7900_command_status_negedge = ~stm32_write_7900_command_status_registered & stm32_write_7900_command_status_delayed;

    stm32_fsmc_ad[15:12] = stm32_read_7900_command_status ? command_register : 4'bz;
    stm32_fsmc_ad[9] =     stm32_read_7900_command_status ? protected_cylinder_register : 1'bz;
    stm32_fsmc_ad[8] =     stm32_read_7900_command_status ? defective_cylinder_register : 1'bz;
    stm32_fsmc_ad[1:0] =   stm32_read_7900_command_status ? drive_select_register : 2'bz;
 
    stm32_7900_data_access = stm32_data_access & (address_register == STM32_REG_7900_DATA);
    stm32_read_7900_data = stm32_7900_data_access & ~stm32_fsmc_noe;
    stm32_write_7900_data = stm32_7900_data_access & ~stm32_fsmc_nwe;

    stm32_fsmc_ad[15:0] = stm32_read_7900_data ? data_interface_output_buffer_register : 16'bz;

    stm32_write_7900_data_negedge = ~stm32_write_7900_data_registered & stm32_write_7900_data_delayed;
    stm32_read_7900_data_negedge = ~stm32_read_7900_data_registered & stm32_read_7900_data_delayed;

    stm32_7900_attention_access = stm32_data_access & (address_register == STM32_REG_7900_ATTENTION);
    stm32_read_7900_attention = stm32_7900_attention_access & ~stm32_fsmc_noe;
    stm32_write_7900_attention = stm32_7900_attention_access & ~stm32_fsmc_nwe;        

    stm32_write_7900_attention_negedge = ~stm32_write_7900_attention_registered & stm32_write_7900_attention_delayed;

    stm32_irq = stm32_irq_ff & stm32_irq_enable | stm32_data_channel_irq_ff & stm32_data_channel_irq_enable;

    stm32_drq = 1'b0;

    set_data_channel_flag_buffer = ~hp7900_data_n_status & stm32_write_7900_command_status_negedge | hp7900_data_n_status &  stm32_write_7900_data_negedge | stm32_read_7900_data_negedge;
    stc_data_channel = stc & dsel;
    stc_data_channel_negedge = ~stc_data_channel & stc_data_channel_delayed;

    seek_record_command = ( command_register == 4'h3) & ioo;
    status_check_command = (command_register == 4'h0) & ioo;

  end

  //--------------------------------------------------------------------------
  // Main sequential logic
  //--------------------------------------------------------------------------
  always_ff @(posedge clk or popio) begin
    if (popio) begin
      data_channel_flag_ff <= 1'b0;
      data_channel_flag_buffer_ff <= 1'b1;
      command_channel_flag_ff <= 1'b0;
      command_channel_flag_buffer_ff <= 1'b1;      
      irq_ff        <= 1'b0;
      command_channel_control_ff    <= 1'b0;
      drive_select_register <= 2'b00;
      protected_cylinder_register <= 1'b0;
      defective_cylinder_register <= 1'b0;
      address_register[3:0] <= 4'b0000;
      data_channel_encode_ff <= 1'b0;
      command_channel_encode_ff <= 1'b0;
      data_interface_output_buffer_register <= 16'o000000;
      stm32_irq_ff <= 1'b0;
      stm32_data_channel_irq_ff <= 1'b0;
      //stm32_irq_enable <= 1'b0; Has to be commented out since PRESET reset this.

      end else begin

        // microcontroller interface

        if (~stm32_fsmc_nadv) address_register <= stm32_fsmc_ad[3:0];
        
        //--------------------------------------------------------------------
        // Simple flip-flop controls
        //--------------------------------------------------------------------

        // data channel flag buffer flip/flop
        if ((clf & dsel) |  (iak & irq_ff)) data_channel_flag_buffer_ff <= 1'b0;
        else if ((stf & dsel) | (~data_channel_flag_ff & set_data_channel_flag_buffer)) data_channel_flag_buffer_ff <= 1'b1;

        // data channel flag flip/flop
        if (clf & dsel) data_channel_flag_ff <= 1'b0;
        else if (data_channel_flag_buffer_ff & enf) data_channel_flag_ff <= 1'b1;
         
        // command channel flag buffer flip/flop
        if ((clf & csel) |  (iak & irq_ff)) command_channel_flag_buffer_ff <= 1'b0;
        else if ((stf & csel) | (~command_channel_flag_ff & stm32_write_7900_attention_negedge)) command_channel_flag_buffer_ff <= 1'b1;

        // command channel flag flip/flop
        if (clf & csel) command_channel_flag_ff <= 1'b0;
        else if (command_channel_flag_buffer_ff & enf) command_channel_flag_ff <= 1'b1;
        
        // command channel control flip/flip
        if (((clc | ioo) & csel) | crs) command_channel_control_ff <= 1'b0;
        else if (stc & csel) command_channel_control_ff <= 1'b1;

        stm32_read_csr_registered <= stm32_read_csr;
        stm32_read_csr_delayed <= stm32_read_csr_registered;
        
        // STM32 interface

        // The IRQ is set on the rising edge of the command channel control signal and reset by reading the status register.
        command_channel_control_ff_delayed <= command_channel_control_ff;
        if (stm32_read_csr_negedge) stm32_irq_ff <= 1'b0;
        else if (~command_channel_control_ff_delayed & command_channel_control_ff) stm32_irq_ff <= 1'b1;

        if (stm32_read_7900_data_negedge) stm32_data_channel_irq_ff <= 1'b0;
        else if (stc_data_channel_negedge) stm32_data_channel_irq_ff <= 1'b1;

        if (stm32_write_csr) begin
            stm32_irq_enable <= stm32_fsmc_ad[8];
            stm32_data_channel_irq_enable <= stm32_fsmc_ad[9];
            hp7900_data_n_status <= stm32_fsmc_ad[1];
        end


        if (stm32_write_7900_command_status) begin
            first_status <= stm32_fsmc_ad[14];
            overrun <= stm32_fsmc_ad[13];
            drive_unsafe <= stm32_fsmc_ad[11];
            data_protect <= stm32_fsmc_ad[10];
            seek_check <= stm32_fsmc_ad[8];
            not_ready <= stm32_fsmc_ad[6];
            end_of_cylinder <= stm32_fsmc_ad[5];
            address_error <= stm32_fsmc_ad[4];
            flagged_cylinder <= stm32_fsmc_ad[3];
            drive_busy <= stm32_fsmc_ad[2];
            data_error <= stm32_fsmc_ad[1];  
        end

        stm32_read_7900_data_registered <= stm32_read_7900_data;
        stm32_read_7900_data_delayed <=  stm32_read_7900_data_registered;

        stm32_write_7900_data_registered <= stm32_write_7900_data;
        stm32_write_7900_data_delayed <= stm32_write_7900_data_registered;

        stm32_write_7900_command_status_registered <= stm32_write_7900_command_status;
        stm32_write_7900_command_status_delayed <= stm32_write_7900_command_status_registered;

        if (stm32_write_7900_data) begin
            data_interface_input_buffer_register <= stm32_fsmc_ad;
        end

        // irq flip/flop
        if (sir & prh & command_channel_flag_buffer_ff & ien & command_channel_flag_ff & command_channel_control_ff) irq_ff <= 1'b1;
        else if (enf) irq_ff <= 1'b0;

        stc_data_channel_delayed <= stc_data_channel;

        if (ioo & csel) begin
            command_register <= iob_out[15:12];
            drive_select_register <= iob_out[1:0];
            protected_cylinder_register <= iob_out[9];
            defective_cylinder_register <= iob_out[8];
        end
        stm32_write_7900_attention_registered <= stm32_write_7900_attention;
        stm32_write_7900_attention_delayed <= stm32_write_7900_attention_registered;
        
        if (crs | seek_record_command | status_check_command) attention_input_register[0] <=1'b0;
        //else if (drv0_sel) attention_input_register[0] <=1'b1;
        else if (stm32_write_7900_attention) attention_input_register[0] <= stm32_fsmc_ad[0] | attention_input_register[0];

        if (crs | seek_record_command | status_check_command) attention_input_register[1] <=1'b0;
        //else if (drv1_sel) attention_input_register[1] <=1'b1;
        else if (stm32_write_7900_attention) attention_input_register[1] <= stm32_fsmc_ad[1] | attention_input_register[1];

        if (crs | seek_record_command | status_check_command) attention_input_register[2] <=1'b0;
        //else if (drv2_sel) attention_input_register[2] <=1'b1;
        else if (stm32_write_7900_attention) attention_input_register[2] <= stm32_fsmc_ad[2] | attention_input_register[2];

        if (crs | seek_record_command | status_check_command) attention_input_register[3] <=1'b0;
        //else if (drv3_sel) attention_input_register[3] <=1'b1;
        else if (stm32_write_7900_attention) attention_input_register[3] <= stm32_fsmc_ad[3] | attention_input_register[3];


/*


        if (crs | (stc & ~cmd_status & csel) ) first_status <= 1'b0;
        else if (strobe_status) first_status <= stm32_fsmc_ad[14];

        if (crs | (stc & ~cmd_status & csel) ) end_of_cylinder <= 1'b0;
        else if (strobe_status) end_of_cylinder <= stm32_fsmc_ad[5];

        if (crs | (stc & ~cmd_status & csel) ) overrun <= 1'b0;
        else if (strobe_status) overrun <= stm32_fsmc_ad[13];

        if (crs | (stc & ~cmd_status & csel) ) drive_unsafe <= 1'b0;
        else if (strobe_status) drive_unsafe <= stm32_fsmc_ad[11];   

        if (crs | (stc & ~cmd_status & csel) ) address_error <= 1'b0;
        else if (strobe_status) address_error <= stm32_fsmc_ad[4];               

        if (crs | (stc & ~cmd_status & csel) ) flagged_cylinder <= 1'b0;
        else if (strobe_status) flagged_cylinder <= stm32_fsmc_ad[3]; 

        if (crs | (stc & ~cmd_status & csel) ) data_protect <= 1'b0;
        else if (strobe_status) data_protect <= stm32_fsmc_ad[10]; 

        if (crs | (stc & ~cmd_status & csel) ) drive_busy <= 1'b0;
        else if (strobe_status) drive_busy <= stm32_fsmc_ad[10];       

        if (crs | (stc & ~cmd_status & csel) ) seek_check <= 1'b0;
        else if (strobe_status) seek_check <= stm32_fsmc_ad[8];   

        if (crs | (stc & ~cmd_status & csel) ) data_error <= 1'b0;
        else if (strobe_status) data_error <= stm32_fsmc_ad[1];    

        if (crs | sk_set_dflag | ((cmd_status | cmd_cd) & gate_status)) data_channel_encode_ff <= 1'b0;
        else if (stc & dsel) data_channel_encode_ff <= 1'b1;     

        if (command_channel_control_ff | strobe_s6) command_channel_encode_ff <= 1'b0;
        else if (stc & csel) command_channel_encode_ff <= 1'b1;
       */ 

        if (dsel & ioo) data_interface_output_buffer_register <= iob_out;
      end
    end

endmodule
