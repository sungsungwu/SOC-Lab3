`timescale 1ns / 1ps
module fir 
#(  parameter pADDR_WIDTH = 12,
    parameter pDATA_WIDTH = 32,
    parameter Tape_Num    = 11
)
(
    output  wire                     awready,
    output  wire                     wready,
    input   wire                     awvalid,
    input   wire [(pADDR_WIDTH-1):0] awaddr,
    input   wire                     wvalid,
    input   wire [(pDATA_WIDTH-1):0] wdata,
    
    output  wire                     arready,
    input   wire                     rready,
    input   wire                     arvalid,
    input   wire [(pADDR_WIDTH-1):0] araddr,
    output  wire                     rvalid,
    output  wire [(pDATA_WIDTH-1):0] rdata,  
      
    input   wire                     ss_tvalid, 
    input   wire [(pDATA_WIDTH-1):0] ss_tdata, 
    input   wire                     ss_tlast, 
    output  wire                     ss_tready,
     
    input   wire                     sm_tready, 
    output  wire                     sm_tvalid, 
    output  wire [(pDATA_WIDTH-1):0] sm_tdata, 
    output  wire                     sm_tlast, 
    
    // bram for tap RAM
    output  wire [3:0]               tap_WE,
    output  wire                     tap_EN,
    output  wire [(pDATA_WIDTH-1):0] tap_Di,
    output  wire [(pADDR_WIDTH-1):0] tap_A,
    input   wire [(pDATA_WIDTH-1):0] tap_Do,

    // bram for data RAM
    output  wire [3:0]               data_WE,
    output  wire                     data_EN,
    output  wire [(pDATA_WIDTH-1):0] data_Di,
    output  wire [(pADDR_WIDTH-1):0] data_A,
    input   wire [(pDATA_WIDTH-1):0] data_Do,

    input   wire                     axis_clk,
    input   wire                     axis_rst_n
);
    reg ap_start, ap_done, ap_idle;
    
    parameter axilite_idle = 3'd0;
    parameter axilite_wdata = 3'd1;
    parameter axilite_rdata = 3'd2;
    parameter axilite_waddr = 3'd3;
    parameter axilite_raddr = 3'd4;
    reg [2:0] axilite_state, next_axilite_state;
    
    parameter axis_idle = 3'd0;
    parameter axis_input = 3'd1;
    parameter axis_calc = 3'd2;
    parameter axis_output = 3'd3;
    reg [2:0] axis_state, next_axis_state;
    
    reg [3:0]               tap_WE_reg, data_WE_reg;
    reg [(pDATA_WIDTH-1):0] tap_Di_reg;
    reg [(pADDR_WIDTH-1):0] tap_A_reg;
    
    reg [31:0] ap_config_reg, data_length_reg;
    reg awready_reg, wready_reg;
    reg rready_reg, rdata_reg;
    reg data_reset_done;
    reg data_Di_reg, data_A_reg;
    reg arready_reg;
    reg rvalid_reg; 
    reg ss_tready_reg;
    reg sm_tvalid_reg, sm_tlast_reg, sm_tready_reg;
    reg [31:0] sm_tdata_reg;
    reg [3:0] fir_counter, first_input;
    wire [3:0] data_input; 
    // write your code here!
    
    //axilite state
    always@* begin
        case(axilite_state)
            axilite_idle : begin
                if(awvalid)
                   next_axilite_state = axilite_waddr; //awready = 1, awready && awvalid => waddr
                else if(arvalid)
                   next_axilite_state = axilite_raddr; //arready = 1, arready && arvalid => raddr
                else
                   next_axilite_state = axilite_idle;
                end
            axilite_waddr : begin
                if(awvalid && awready)
                    next_axilite_state = axilite_wdata;
                else
                    next_axilite_state = axilite_waddr;
                end
           axilite_wdata : begin
                if(wready && wvalid)
                    next_axilite_state = axilite_idle; //wready && wvalid => wdata
                else
                    next_axilite_state = axilite_wdata;
                end
           axilite_raddr : begin
                if(arvalid && arready)
                    next_axilite_state = axilite_rdata;
                else
                    next_axilite_state = axilite_raddr;
                end
           axilite_rdata : begin
                if(rready && rvalid)
                    next_axilite_state = axilite_idle;//rready && rvalid => rdata
                else
                    next_axilite_state = axilite_rdata;
                end
         endcase
    end
    
    always@(posedge axis_clk or negedge axis_rst_n)
      if(~axis_rst_n)begin
          axilite_state <= axilite_idle;
      end
      else begin
          axilite_state <= next_axilite_state;
      end
      
    //ap config
    always @(posedge axis_clk or negedge axis_rst_n) begin
	    if (~axis_rst_n) begin
	        ap_config_reg <= 32'h04;  
                data_length_reg <= 0;
	    end else begin
		if (axilite_state == axilite_wdata) begin
                   if (awaddr == 32'h00)begin
                       ap_config_reg <= wdata;
               end
               else if(awaddr == 32'h10)begin
                    data_length_reg <= wdata;
               end
            end
            else if (axilite_state == axilite_rdata) begin // reset ap_done when 0x00 is read
                     if(awaddr == 32'h00)
                         ap_config_reg[1] <= 1'b0;
                     else
                         ap_config_reg[1] <= ap_config_reg[1];
            end
            else begin
            //ap_start 
                if(ap_config_reg[0] == 0)
                    ap_config_reg[0] <= 1'b0;
                else if(axis_state == axis_idle)// in idle_state set ap_start to 1
                    ap_config_reg[0] <= 1'b1;
                else
                    ap_config_reg[0] <= 1'b0;
            // ap_done   
                if(ap_config_reg[1] == 1)
                    ap_config_reg[1] <= 1'b1;
                else if(sm_tlast==1 && axis_state == axis_output)// when last data transfered set ap_done to 1
                    ap_config_reg[1] <= 1'b1;
                else
                    ap_config_reg[1] <= 1'b0;
            // ap_idle 
                if(ap_config_reg[2]==1)
                    if(ap_config_reg[0]==1) // when ap_start == 1 set ap_idle to 0
                        ap_config_reg[2] <= 1'b0;
                    else
                        ap_config_reg[2] <= 1'b1;
                else if(ss_tlast==1 && axis_state == axis_idle)// when last data received set ap_idle to 1
                        ap_config_reg[2] <= 1'b1;
                    else
                        ap_config_reg[2] <= 1'b0;
            end
	end
    end
    
    //axilite protocol
    //arready && arvalid => raddr, ready && rvalid => rdata, data_length => 32'h10, tap >= 32'h20
    //awready && awvalid => waddr 
    
    //awready
    assign awready = awready_reg;
    always@* begin
        if(axilite_state == axilite_waddr)
            awready_reg = 1'b1;
        else
            awready_reg = 1'b0;
    end
    
    //wready
    assign wready = wready_reg;
    always@* begin
        if(axilite_state == axilite_wdata)
            wready_reg = 1'b1;
        else
            wready_reg = 1'b0;
    end    
    
    //arready
    assign arready = arready_reg;
    always@* begin
        if(axilite_state == axilite_raddr)
            arready_reg = 1'b1;
        else
            arready_reg = 1'b0;
    end
    
    //rvalid
    assign rvalid = rvalid_reg;
    always@* begin
        if(axilite_state == axilite_rdata)
            rvalid_reg = 1'b1;
        else
            rvalid_reg = 1'b0;
    end
    
    //rdata
    assign rdata  = (axilite_state == axilite_rdata) ? (araddr == 32'h00)? ap_config_reg: (araddr == 32'h10)? data_length_reg : (araddr >= 32'h20)? tap_Do:0 : 0;
 
    
    //axis state
    always@* begin
        case(axis_state)
            axis_idle : begin
                if(ap_config_reg[0]) 
                    next_axis_state = axis_input;
                else
                    next_axis_state = axis_idle;
            end    
            axis_input : begin
                next_axis_state = axis_calc;
            end
            axis_calc : begin
                if(fir_counter == 11)
                    next_axis_state = axis_output;
                else
                    next_axis_state = axis_calc;
            end         
            axis_output : begin
                if(sm_tlast)
                    next_axis_state = axis_idle;
                else
                    next_axis_state = axis_input;
            end
        endcase
    end
    always@(posedge axis_clk or negedge axis_rst_n)begin
      if(~axis_rst_n)begin
          axis_state <= axis_idle;
      end
      else begin
          axis_state <= next_axis_state;
      end
    end
    
    //EN
    assign tap_EN = 1'b1;
    assign data_EN = 1'b1;
    
    //WE
    assign tap_WE = tap_WE_reg;
    always@* begin
        if(axilite_state == axilite_wdata && awaddr >= 32'h20)
            tap_WE_reg = 4'b1111;
        else
            tap_WE_reg = 4'b0000;
    end
    
    assign data_WE = data_WE_reg;
    always@* begin
        if(axis_state == axis_idle)
            data_WE_reg = 4'b1111;
        else if(axis_state == axis_input)
            data_WE_reg = 4'b1111;
        else
            data_WE_reg = 4'b0000;
    end
    
    //Di
	assign data_Di = (axis_state == axis_idle)? 0 : ss_tdata;  // axis_idle reset to 0
    assign tap_Di = wdata;

    //addr
    assign tap_A = tap_A_reg;
    always@* begin
        if(axilite_state == axilite_wdata && axis_state == axis_idle)
            tap_A_reg = awaddr - 32'h20;
        else if(axilite_state == axilite_raddr && axis_state == axis_idle)
            tap_A_reg = araddr - 32'h20;
        else
            tap_A_reg = fir_counter<<2;
    end
    
    assign data_A = (axis_state == axis_calc)? (data_input<<2) : (first_input<<2);

    //axis 
    assign ss_tready = ss_tready_reg;
    assign sm_tvalid = sm_tvalid_reg;
    assign sm_tlast = sm_tlast_reg;
    assign sm_tdata = sm_tdata_reg;
    assign data_input = (first_input >= fir_counter)? (first_input - fir_counter) : 11-(fir_counter - first_input); 
    always@(posedge axis_clk or negedge axis_rst_n)
        if(~axis_rst_n)begin
            data_reset_done <= 1'b0;
            ss_tready_reg <= 1'b0;
            first_input <= 1'b0;
            fir_counter <= 1'b0;
            sm_tready_reg <= 1'b0;
            sm_tdata_reg <= 1'b0;
            sm_tlast_reg <= 1'b0;
        end
        else begin
            case(axis_state)
                axis_idle : begin
                    ss_tready_reg <= 1'b0;
                    sm_tvalid_reg <= 1'b0;
                    first_input <= data_reset_done?0 : first_input + 1;
                    data_reset_done <= (data_reset_done == 1)? 1:(first_input == 10)?1:0;               
               end
               axis_input : begin // axis_s receive data
                   ss_tready_reg <= 1'b1; 
                   sm_tvalid_reg <= 1'b0;
                   fir_counter <= 1;
               end
               
               axis_calc: begin // fir calculation
                   ss_tready_reg <= 1'b0;
                   sm_tdata_reg <= sm_tdata_reg + data_Do*tap_Do; 
                   sm_tvalid_reg <= (fir_counter==11)? 1:0;
                   if(fir_counter == 11) 
                       fir_counter <= 1'b0;
                   else 
                       fir_counter <= fir_counter + 1;
               end
               axis_output : begin // stop receive data and send ap_done
                       ss_tready_reg <= 1'b0;  
                       sm_tvalid_reg <= 1'b0;
                       sm_tdata_reg <= 1'b0;
                       first_input <= (first_input == 10)? 0:first_input + 1;
                       sm_tlast_reg <= (ss_tlast == 1)? 1:0;
                   end
               endcase
           end
           
       
   
endmodule
