
// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Description:
//      Decodes the SOC request and sends to appropriate target.
//

module mci_axi_sub_decode 
    import mci_pkg::*;
    import mci_reg_pkg::*;
    import mbox_csr_pkg::*;
    #(
    // Configurable memory blocks
    parameter MCU_SRAM_SIZE_KB = 1024,

    ///////////////////////////////////////////////////////////
    // MCI Memory Map
    ///////////////////////////////////////////////////////////
    localparam MCI_REG_SIZE_BYTES    = 2 ** MCI_REG_MIN_ADDR_WIDTH, 
    localparam MCI_REG_START_ADDR    = 32'h0000_0000,
    localparam MCI_REG_END_ADDR      = MCI_REG_START_ADDR + (MCI_REG_SIZE_BYTES) - 1,
    localparam MBOX0_START_ADDR      = 32'h0008_0000,
    localparam MBOX0_END_ADDR        = MBOX0_START_ADDR + ((32'h0000_0001 << MBOX_CSR_ADDR_WIDTH) - 1),
    localparam MBOX1_START_ADDR      = 32'h0009_0000,
    localparam MBOX1_END_ADDR        = MBOX1_START_ADDR + ((32'h0000_0001 << MBOX_CSR_ADDR_WIDTH) - 1),
    localparam MCU_SRAM_START_ADDR   = 32'h0020_0000,
    localparam MCU_SRAM_END_ADDR     = MCU_SRAM_START_ADDR + (MCU_SRAM_SIZE_KB * KB) - 1, 
      
    localparam MCI_END_ADDR   = MCU_SRAM_END_ADDR,
    localparam MCI_INTERNAL_ADDR_WIDTH = $clog2(MCI_END_ADDR)
        
    )
    (

    //SOC inf
    cif_if.response  soc_resp_if,

    //MCI REG inf
    cif_if.request  mci_reg_req_if, 

    //MCU SRAM inf
    cif_if.request  mcu_sram_req_if,

    //MCI Mbox0 inf
    cif_if.request  mci_mbox0_req_if,
    input logic [4:0][soc_resp_if.USER_WIDTH-1:0] valid_mbox0_users,

    // Mbox1 SRAM Interface
    cif_if.request  mci_mbox1_req_if,
    input logic [4:0][soc_resp_if.USER_WIDTH-1:0] valid_mbox1_users,

    // Privileged requests 
    output logic axi_mcu_lsu_req,
    output logic axi_mcu_ifu_req,
    output logic axi_mcu_req    ,
    output logic axi_debug_req    ,
    output logic axi_cptra_req    ,

    
    // Privileged AXI users
    input logic [soc_resp_if.USER_WIDTH-1:0] strap_mcu_lsu_axi_user,
    input logic [soc_resp_if.USER_WIDTH-1:0] strap_mcu_ifu_axi_user,
    input logic [soc_resp_if.USER_WIDTH-1:0] strap_cptra_axi_user,
    input logic [soc_resp_if.USER_WIDTH-1:0] strap_debug_axi_user
);

// Valid signals
logic mbox0_valid_user;
logic mbox1_valid_user;
logic all_strb_set;

// GRANT signals
logic soc_mcu_sram_gnt;
logic soc_mci_reg_gnt;
logic soc_mci_mbox0_gnt;
logic soc_mci_mbox1_gnt;

// REQ signals
logic soc_mcu_sram_req;
logic soc_mci_reg_req;
logic soc_mci_mbox0_req;
logic soc_mci_mbox1_req;

// MISC signals
logic soc_req_miss;
logic debug_req_disable;
logic debug_req_force_enable;
logic debug_axi_user_detect;


///////////////////////////////////////////////////////////
// Decode which address space is being requested
///////////////////////////////////////////////////////////
//SoC requests to MCU_SRAM
always_comb soc_mcu_sram_gnt = (soc_resp_if.dv & (soc_resp_if.req_data.addr[MCI_INTERNAL_ADDR_WIDTH-1:0] inside {[MCU_SRAM_START_ADDR:MCU_SRAM_END_ADDR]}));

// SoC request to MCI Reg
always_comb soc_mci_reg_gnt = (soc_resp_if.dv & (soc_resp_if.req_data.addr[MCI_INTERNAL_ADDR_WIDTH-1:0] inside {[MCI_REG_START_ADDR:MCI_REG_END_ADDR]}));

// SoC request to MCI Mbox0
always_comb soc_mci_mbox0_gnt = (soc_resp_if.dv & (soc_resp_if.req_data.addr inside {[MBOX0_START_ADDR:MBOX0_END_ADDR]}));



// SoC request to MCI Mbox1
always_comb soc_mci_mbox1_gnt = (soc_resp_if.dv & (soc_resp_if.req_data.addr inside {[MBOX1_START_ADDR:MBOX1_END_ADDR]}));

///////////////////////////////////////////////////////////
// Add qualifiers to grant before sending to IPs
///////////////////////////////////////////////////////////

// If write transaction verify all strbs are set. If read transaction strb
// doesn't care so assert all_strb_set
always_comb all_strb_set = (&soc_resp_if.req_data.wstrb & soc_resp_if.req_data.write) | ~soc_resp_if.req_data.write ;

// MCU SRAM
always_comb soc_mcu_sram_req = soc_mcu_sram_gnt;

// MCI REG 
always_comb soc_mci_reg_req   = soc_mci_reg_gnt & all_strb_set;

// MCI Mbox0
always_comb soc_mci_mbox0_req = soc_mci_mbox0_gnt & mbox0_valid_user & all_strb_set;

//Check if SoC request is coming from a valid user
//There are 5 valid user registers, check if user attribute matches any of them
//Check if user matches Default Valid user parameter - this user value is always valid
//Check if request is coming from MCU (privilaged access)
//Check if request is coming from Debug (privilaged access)
always_comb begin
    mbox0_valid_user = '0;
    for (int i=0; i < 5; i++) begin
        mbox0_valid_user |= (soc_resp_if.req_data.user == valid_mbox0_users[i]);
    end
    mbox0_valid_user |= soc_resp_if.req_data.user == MCI_DEF_MBOX_VALID_AXI_USER[soc_resp_if.USER_WIDTH-1:0];
    mbox0_valid_user |= axi_mcu_req;
    mbox0_valid_user |= axi_debug_req;
end

// MCI Mbox1
always_comb soc_mci_mbox1_req = soc_mci_mbox1_gnt & mbox1_valid_user & all_strb_set;

//Check if SoC request is coming from a valid user
//There are 5 valid user registers, check if user attribute matches any of them
//Check if user matches Default Valid user parameter - this user value is always valid
//Check if request is coming from MCU (privilaged access)
//Check if request is coming from Debug (privilaged access)
always_comb begin
    mbox1_valid_user = '0;
    for (int i=0; i < 5; i++) begin
        mbox1_valid_user |= (soc_resp_if.req_data.user == valid_mbox1_users[i]);
    end
    mbox1_valid_user |= (soc_resp_if.req_data.user == MCI_DEF_MBOX_VALID_AXI_USER[soc_resp_if.USER_WIDTH-1:0]);
    mbox1_valid_user |= axi_mcu_req;
    mbox1_valid_user |= axi_debug_req;
end


///////////////////////////////////////////////////////////
// Drive DV to appropriate destination
///////////////////////////////////////////////////////////

// MCU SRAM
always_comb mcu_sram_req_if.dv = soc_mcu_sram_req;

// MCI REG 
always_comb mci_reg_req_if.dv = soc_mci_reg_req;

// MCI Mbox0
always_comb mci_mbox0_req_if.dv = soc_mci_mbox0_req;

// MCI Mbox1
always_comb mci_mbox1_req_if.dv = soc_mci_mbox1_req;


///////////////////////////////////////////////////////////
// Drive data and reqest to approriate destination.
///////////////////////////////////////////////////////////

// MCU SRAM
always_comb mcu_sram_req_if.req_data = soc_resp_if.req_data;

// MCI REG 
always_comb mci_reg_req_if.req_data = soc_resp_if.req_data;

// MCI Mbox0
always_comb mci_mbox0_req_if.req_data = soc_resp_if.req_data;

// MCI MBOX1
always_comb mci_mbox1_req_if.req_data = soc_resp_if.req_data;


///////////////////////////////////////////////////////////
// Drive read data back
///////////////////////////////////////////////////////////

assign soc_resp_if.rdata =  soc_mcu_sram_req    ? mcu_sram_req_if.rdata : 
                            soc_mci_reg_req     ? mci_reg_req_if.rdata  :
                            soc_mci_mbox0_req   ? mci_mbox0_req_if.rdata  :
                            soc_mci_mbox1_req   ? mci_mbox1_req_if.rdata  :
                            '0;




///////////////////////////////////////////////////////////
// Drive appropriate hold back
///////////////////////////////////////////////////////////

always_comb soc_resp_if.hold =  (soc_mcu_sram_req & (~soc_mcu_sram_req | mcu_sram_req_if.hold)) |
                                (soc_mci_reg_req & (~soc_mci_reg_req | mci_reg_req_if.hold)) |
                                (soc_mci_mbox0_req & (~soc_mci_mbox0_req | mci_mbox0_req_if.hold)) |
                                (soc_mci_mbox1_req & (~soc_mci_mbox1_req | mci_mbox1_req_if.hold)) ;



///////////////////////////////////////////////////////////
// Drive appropriate error back or request misses all destinations
///////////////////////////////////////////////////////////

// Missed all destinations 
always_comb soc_req_miss = soc_resp_if.dv & ~(soc_mcu_sram_req | soc_mci_reg_req | soc_mci_mbox0_req | soc_mci_mbox1_req);

// Error for SOC
always_comb soc_resp_if.error = (soc_mcu_sram_req  & mcu_sram_req_if.error)  |
                                (soc_mci_reg_req   & mci_reg_req_if.error)   |
                                (soc_mci_mbox0_req & mci_mbox0_req_if.error) |
                                (soc_mci_mbox1_req & mci_mbox1_req_if.error) |
                                soc_req_miss;

///////////////////////////////////////////////
// Determine if the user matches any of the  
// privileged users
///////////////////////////////////////////////

// All 0s disabled debug_axi user capability. Mutually exclusive with
// debug_req_force_enable.
assign debug_req_disable = ~|strap_debug_axi_user;

// All 1s every AXI transaction is treated as a debug user. Mutually exclusive
// with debug_req_disable
assign debug_req_force_enable = &strap_debug_axi_user;

assign debug_axi_user_detect = ~(|(soc_resp_if.req_data.user ^ strap_debug_axi_user));

assign axi_debug_req    = soc_resp_if.dv & ((debug_axi_user_detect & ~debug_req_disable) | debug_req_force_enable);

assign axi_mcu_lsu_req  = soc_resp_if.dv & ~(|(soc_resp_if.req_data.user ^ strap_mcu_lsu_axi_user));
assign axi_mcu_ifu_req  = soc_resp_if.dv & ~(|(soc_resp_if.req_data.user ^ strap_mcu_ifu_axi_user));
assign axi_mcu_req      = axi_mcu_lsu_req | axi_mcu_ifu_req; 

assign axi_cptra_req      = soc_resp_if.dv & ~(|(soc_resp_if.req_data.user ^ strap_cptra_axi_user));



endmodule
