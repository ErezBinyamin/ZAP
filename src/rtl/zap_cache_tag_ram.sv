// -----------------------------------------------------------------------------
// --                                                                         --
// --    (C) 2016-2022 Revanth Kamaraj (krevanth)                             --
// --                                                                         -- 
// -- --------------------------------------------------------------------------
// --                                                                         --
// -- This program is free software; you can redistribute it and/or           --
// -- modify it under the terms of the GNU General Public License             --
// -- as published by the Free Software Foundation; either version 2          --
// -- of the License, or (at your option) any later version.                  --
// --                                                                         --
// -- This program is distributed in the hope that it will be useful,         --
// -- but WITHOUT ANY WARRANTY; without even the implied warranty of          --
// -- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           --
// -- GNU General Public License for more details.                            --
// --                                                                         --
// -- You should have received a copy of the GNU General Public License       --
// -- along with this program; if not, write to the Free Software             --
// -- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA           --
// -- 02110-1301, USA.                                                        --
// --                                                                         --
// -----------------------------------------------------------------------------
// --                                                                         --                   
// -- This is the tag RAM and data RAM unit. The tag RAM holds both the       --
// -- virtual tag and the physical address. The physical address is used to   --  
// -- avoid translation during clean operations. The cache data RAM is also   --
// -- present in this unit. This unit has a dedicated memory interface        -- 
// -- because it can perform global clean and flush by itself without         --
// -- depending on the cache controller.                                      --
// --                                                                         --
// -----------------------------------------------------------------------------



`include "zap_defines.svh"

module zap_cache_tag_ram #( 

parameter CACHE_SIZE = 1024, // Bytes.
parameter CACHE_LINE = 8

)(

input   logic                            i_clk,
input   logic                            i_reset,
input   logic    [31:0]                  i_address_nxt,
input   logic    [31:0]                  i_address,
input   logic                            i_cache_en,
input   logic    [CACHE_LINE*8-1:0]      i_cache_line,
input   logic    [CACHE_LINE-1:0]        i_cache_line_ben,
output  logic    [CACHE_LINE*8-1:0]      o_cache_line,
input   logic                            i_cache_tag_wr_en,
input   logic    [`ZAP_CACHE_TAG_WDT-1:0]i_cache_tag,
input   logic                            i_cache_tag_dirty,

output  logic    [`ZAP_CACHE_TAG_WDT-1:0] o_cache_tag,
output  logic                             o_cache_tag_valid,
output  logic                             o_cache_tag_dirty,
input   logic                             i_cache_clean_req,
output  logic                             o_cache_clean_done,
input   logic                             i_cache_inv_req,
output  logic                             o_cache_inv_done,

/* 
 * Cache clean operations occur through these ports.
 * Memory access ports, both NXT and FF. Usually you'll be connecting NXT ports 
 */
output  logic                             o_wb_cyc_ff, o_wb_cyc_nxt,
output  logic                             o_wb_stb_ff, o_wb_stb_nxt,
output  logic     [31:0]                  o_wb_adr_ff, o_wb_adr_nxt,
output  logic     [31:0]                  o_wb_dat_ff, o_wb_dat_nxt,
output  logic     [3:0]                   o_wb_sel_ff, o_wb_sel_nxt,
output  logic                             o_wb_wen_ff, o_wb_wen_nxt,
output  logic     [2:0]                   o_wb_cti_ff, o_wb_cti_nxt, /* Cycle Type Indicator - 010, 111 */
input logic      [31:0]                   i_wb_dat,
input logic                               i_wb_ack

);

// ----------------------------------------------------------------------------

`include "zap_localparams.svh"

localparam NUMBER_OF_DIRTY_BLOCKS = ((CACHE_SIZE/CACHE_LINE)/16); // Keep cache size > 16 bytes.

// States.
localparam IDLE                         = 0;
localparam CACHE_CLEAN_GET_ADDRESS      = 1;
localparam CACHE_CLEAN_WRITE            = 2;
localparam CACHE_INV                    = 3;

localparam BLK_CTR_PAD = 32 - $clog2(NUMBER_OF_DIRTY_BLOCKS) - 1;
localparam ADR_CTR_PAD = 32 - $clog2(CACHE_LINE/4) - 1;
localparam ZERO_WDT    = $clog2(CACHE_LINE/4) + 1;

// ----------------------------------------------------------------------------

logic [(CACHE_SIZE/CACHE_LINE)-1:0]        dirty;
logic [(CACHE_SIZE/CACHE_LINE)-1:0]        valid; 
logic [`ZAP_CACHE_TAG_WDT-1:0]             tag_ram_wr_data;
logic                                      tag_ram_wr_en;
logic [$clog2(CACHE_SIZE/CACHE_LINE)-1:0]  tag_ram_wr_addr;
logic [$clog2(CACHE_SIZE/CACHE_LINE)-1:0]  tag_ram_rd_addr;
logic                                      tag_ram_clear;
logic                                      tag_ram_clean;
logic [1:0]                                state_ff, state_nxt;
logic [$clog2(NUMBER_OF_DIRTY_BLOCKS):0]   blk_ctr_ff, blk_ctr_nxt;
logic [$clog2(CACHE_LINE/4):0]             adr_ctr_ff, adr_ctr_nxt;
genvar                                     i;

logic                                      unused;
logic [BLK_CTR_PAD-1:0]                    dummy;
logic [CACHE_LINE*8-32-1:0]                line_dummy;
logic                                      unused_0;
logic                                      cache_unused0;
logic                                      cache_unused1;

assign cache_unused0 = |{i_address[31: $clog2(CACHE_LINE)+$clog2(CACHE_SIZE/CACHE_LINE)], i_address[$clog2(CACHE_LINE)-1:0]};
assign cache_unused1 = |{i_address_nxt[31: $clog2(CACHE_LINE)+$clog2(CACHE_SIZE/CACHE_LINE)], i_address_nxt[$clog2(CACHE_LINE)-1:0]};
assign        unused = |{dummy, line_dummy, i_wb_dat, unused_0, cache_unused0, cache_unused1};

// ----------------------------------------------------------------------------

for(i=0;i<CACHE_LINE;i=i+1)
begin
        zap_ram_simple #(.WIDTH(8), .DEPTH(CACHE_SIZE/CACHE_LINE)) u_zap_ram_simple_data_ram (
                .i_clk(i_clk),

                .i_wr_en(i_cache_line_ben[i]),
                .i_rd_en(1'd1),

                .i_wr_data(i_cache_line   [i*8+7:i*8]),
                .o_rd_data(o_cache_line   [i*8+7:i*8]),

                .i_wr_addr(tag_ram_wr_addr),
                .i_rd_addr(tag_ram_rd_addr)
        );
end

zap_ram_simple #(.WIDTH(`ZAP_CACHE_TAG_WDT), .DEPTH(CACHE_SIZE/CACHE_LINE)) u_zap_ram_simple_tag (
        .i_clk(i_clk),

        .i_wr_en(tag_ram_wr_en),
        .i_rd_en(1'd1),

        .i_wr_data(tag_ram_wr_data),
        .o_rd_data(o_cache_tag),

        .i_wr_addr(tag_ram_wr_addr),
        .i_rd_addr(tag_ram_rd_addr)
);

// ----------------------------------------------------------------------------

always_ff @ (posedge i_clk)
begin
        o_cache_tag_dirty <= dirty [ tag_ram_rd_addr ];

        if ( i_reset )
                dirty <= 0;
        else if ( tag_ram_wr_en )
                dirty [ tag_ram_wr_addr ]   <= i_cache_tag_dirty;
        else if ( tag_ram_clean )
                dirty[tag_ram_rd_addr] <= 1'd0;// BUG FIX dirty_nxt;
end

always_ff @ (posedge i_clk)
begin
        o_cache_tag_valid <= valid [ tag_ram_rd_addr ];

        if ( tag_ram_clear || !i_cache_en || i_reset )
                valid <= 0;
        else if ( tag_ram_wr_en )
                valid [ tag_ram_wr_addr ]   <= 1'd1;
end

// ----------------------------------------------------------------------------

always_ff @ (posedge i_clk)
begin
        if ( i_reset )
        begin
                o_wb_cyc_ff             <= 0;
                o_wb_stb_ff             <= 0;
                o_wb_wen_ff             <= 0;
                o_wb_sel_ff             <= 0;
                o_wb_dat_ff             <= 0;
                o_wb_cti_ff             <= CTI_CLASSIC;
                o_wb_adr_ff             <= 0;
                adr_ctr_ff              <= 0;
                blk_ctr_ff              <= 0;
                state_ff                <= IDLE;
        end
        else
        begin
                o_wb_cyc_ff             <= o_wb_cyc_nxt;
                o_wb_stb_ff             <= o_wb_stb_nxt;
                o_wb_wen_ff             <= o_wb_wen_nxt;
                o_wb_sel_ff             <= o_wb_sel_nxt;
                o_wb_dat_ff             <= o_wb_dat_nxt;
                o_wb_cti_ff             <= o_wb_cti_nxt;
                o_wb_adr_ff             <= o_wb_adr_nxt;
                adr_ctr_ff              <= adr_ctr_nxt;
                blk_ctr_ff              <= blk_ctr_nxt;
                state_ff                <= state_nxt;
        end
end

// ----------------------------------------------------------------------------

always_comb
begin:blk1
        logic [31:0] shamt, data, pa;

        line_dummy = {(CACHE_LINE*8-32){1'd0}};
        shamt = 0;
        data  = 0;
        pa    = 0;
        dummy = 0;

        // Defaults.
        state_nxt = state_ff;
        tag_ram_rd_addr         = 0;
        tag_ram_wr_addr         = i_address     [`ZAP_VA__CACHE_INDEX];
        tag_ram_wr_en           = 0; 
        tag_ram_clear           = 0;
        tag_ram_clean           = 0;
        adr_ctr_nxt             = adr_ctr_ff;
        blk_ctr_nxt             = blk_ctr_ff;
        o_cache_clean_done      = 0;
        o_cache_inv_done        = 0;

        o_wb_cyc_nxt = o_wb_cyc_ff;
        o_wb_stb_nxt = o_wb_stb_ff;
        o_wb_adr_nxt = o_wb_adr_ff;
        o_wb_dat_nxt = o_wb_dat_ff;
        o_wb_sel_nxt = o_wb_sel_ff;
        o_wb_wen_nxt = o_wb_wen_ff;
        o_wb_cti_nxt = o_wb_cti_ff;

        tag_ram_wr_data = 0;

        case ( state_ff )

        IDLE:
        begin
                kill_access ();

                tag_ram_rd_addr = i_address_nxt [`ZAP_VA__CACHE_INDEX];
                tag_ram_wr_addr = i_address     [`ZAP_VA__CACHE_INDEX];
                tag_ram_wr_en   = i_cache_tag_wr_en;
                tag_ram_wr_data = i_cache_tag;

                if ( i_cache_clean_req )
                begin
                        tag_ram_wr_en = 0;
                        blk_ctr_nxt = 0;

                        state_nxt = CACHE_CLEAN_GET_ADDRESS;
                end
                else if ( i_cache_inv_req )
                begin
                        tag_ram_wr_en = 0;
                        state_nxt = CACHE_INV;
                end
        end        

        CACHE_CLEAN_GET_ADDRESS:
        begin
                tag_ram_rd_addr = get_tag_ram_rd_addr (blk_ctr_ff , dirty);

                if ( &baggage(dirty, blk_ctr_ff) )
                begin
                        // Move to next block.
                        {dummy, blk_ctr_nxt} = {dummy, blk_ctr_ff} + 32'd1;

                        if ( {{BLK_CTR_PAD{1'd0}}, blk_ctr_ff} == NUMBER_OF_DIRTY_BLOCKS - 1 )
                        begin
                                state_nxt          = IDLE;
                                o_cache_clean_done = 1'd1;
                        end
                end
                else
                begin

                        // Go to state.
                        state_nxt = CACHE_CLEAN_WRITE;
                end

                adr_ctr_nxt     = 0; // Initialize address counter.
        end

        CACHE_CLEAN_WRITE:
        begin
                tag_ram_rd_addr = get_tag_ram_rd_addr (blk_ctr_ff , dirty);
                adr_ctr_nxt = adr_ctr_ff + ((i_wb_ack && o_wb_stb_ff) ? 
                              {{(ZERO_WDT-1){1'd0}}, 1'd1} : 
                              {ZERO_WDT{1'd0}});

                if ( {{ADR_CTR_PAD{1'd0}}, adr_ctr_nxt} > ((CACHE_LINE/4) - 1) )
                begin
                        // Remove dirty marking. BUG FIX.
                        tag_ram_clean = 1;

                        // Kill access.
                        kill_access ();

                        // Go to new state.
                        state_nxt = CACHE_CLEAN_GET_ADDRESS;
                end
                else
                begin
                        shamt = {{(ADR_CTR_PAD-5){1'd0}}, adr_ctr_nxt, 5'd0};
                        {line_dummy, data}  = o_cache_line >> shamt;
                        pa    = {o_cache_tag[`ZAP_CACHE_TAG__PA], {$clog2(CACHE_LINE){1'd0}}};

                        // Perform a Wishbone write using Physical Address.
                        wb_prpr_write(  
                        data, 
                        pa + ({{(ADR_CTR_PAD-2){1'd0}}, adr_ctr_nxt, 2'd0}), 
                        ({{ADR_CTR_PAD{1'd0}},adr_ctr_nxt} != (CACHE_LINE/4)-1) ? CTI_BURST : CTI_EOB, 
                        4'b1111 
                        );
                end
        end

        CACHE_INV:
        begin
                tag_ram_clear = 1'd1;
                state_nxt     = IDLE;
                o_cache_inv_done = 1'd1;
        end
        
        endcase                
end

// -----------------------------------------------------------------------------

// Priority encoder.
function  [4:0] pri_enc_1 ( input [CACHE_SIZE/CACHE_LINE-1:0] in );
integer j;
begin: priEncFn
                pri_enc_1 = 5'b11111;

                // Run a backward loop.
                for(j=CACHE_SIZE/CACHE_LINE-1;j>=0;j=j-1)
                begin
                        if ( in[j] == 1'd1 )
                                pri_enc_1[4:0] = j[4:0];
                end
end
endfunction

// -----------------------------------------------------------------------------

function [$clog2(CACHE_SIZE/CACHE_LINE)-1:0] get_tag_ram_rd_addr (
input [$clog2(NUMBER_OF_DIRTY_BLOCKS):0]   blk_ctr,
input [CACHE_SIZE/CACHE_LINE-1:0]          Dirty
);
localparam W = $clog2(NUMBER_OF_DIRTY_BLOCKS) + 5;
logic [CACHE_SIZE/CACHE_LINE-1:0] dirty_new;
logic [4:0]                       enc;
logic [W-1:0]                     shamt;
logic [31:0]                      sum;
begin
        sum                 = 32'd0;
        shamt               = {blk_ctr, 4'd0};
        dirty_new           = Dirty >> shamt;
        enc                 = pri_enc_1(dirty_new[CACHE_SIZE/CACHE_LINE-1:0]);
        sum[W:0]            = {1'd0, shamt[W-1:0]} + {1'd0, {{(W-5){1'd0}}, enc}};
        get_tag_ram_rd_addr = sum[$clog2(CACHE_SIZE/CACHE_LINE)-1:0];
        unused_0            = |{sum[31:$clog2(CACHE_SIZE/CACHE_LINE)]};
end
endfunction

// ----------------------------------------------------------------------------

/* Function to generate Wishbone read signals. */
function void wb_prpr_read (
        input [31:0] address,
        input [2:0]  cti
);
begin
        o_wb_cyc_nxt = 1'd1;
        o_wb_stb_nxt = 1'd1;
        o_wb_wen_nxt = 1'd0;
        o_wb_sel_nxt = 4'b1111;
        o_wb_adr_nxt = address;
        o_wb_cti_nxt = cti;
        o_wb_dat_nxt = 0;
end
endfunction

// ----------------------------------------------------------------------------

/* Function to generate Wishbone write signals */
function void wb_prpr_write (
        input   [31:0]  data,
        input   [31:0]  address,
        input   [2:0]   cti,
        input   [3:0]   ben
);
begin
        o_wb_cyc_nxt = 1'd1;
        o_wb_stb_nxt = 1'd1;
        o_wb_wen_nxt = 1'd1;
        o_wb_sel_nxt = ben;
        o_wb_adr_nxt = address;
        o_wb_cti_nxt = cti;
        o_wb_dat_nxt = data;
end
endfunction

// ----------------------------------------------------------------------------

/* Disables Wishbone */
function void  kill_access ();
begin
        o_wb_cyc_nxt = 0;
        o_wb_stb_nxt = 0;
        o_wb_wen_nxt = 0;
        o_wb_adr_nxt = 0;
        o_wb_dat_nxt = 0;
        o_wb_sel_nxt = 0;
        o_wb_cti_nxt = CTI_CLASSIC;
end
endfunction

// ----------------------------------------------------------------------------

function [4:0] baggage ( 
        input [CACHE_SIZE/CACHE_LINE-1:0]               Dirty, 
        input [$clog2(NUMBER_OF_DIRTY_BLOCKS):0]        blk_ctr 
);
localparam                      W = $clog2(NUMBER_OF_DIRTY_BLOCKS) + 5;
logic [W-1:0]                     shamt;
logic [CACHE_SIZE/CACHE_LINE-1:0] val;
begin
        shamt   = {blk_ctr, 4'd0};
        val     = Dirty >> shamt;
        baggage = pri_enc_1(val[CACHE_SIZE/CACHE_LINE-1:0]);
end
endfunction

endmodule // zap_cache_tag_ram.v



// ----------------------------------------------------------------------------
// END OF FILE
// ----------------------------------------------------------------------------

