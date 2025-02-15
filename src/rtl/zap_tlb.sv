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
//                                                                            --    
// TLB management unit for the ZAP processor. The TLB units use single cycle  --
// clearing memories since TLBs are shallow.                                  --
//                                                                            --
// -----------------------------------------------------------------------------


module zap_tlb #(

parameter LPAGE_TLB_ENTRIES   = 8,
parameter SPAGE_TLB_ENTRIES   = 8,
parameter SECTION_TLB_ENTRIES = 8,
parameter FPAGE_TLB_ENTRIES   = 8

) (

// Clock and reset.
input   logic            i_clk,
input   logic            i_reset,

// From cache FSM (processor)
input   logic    [31:0]  i_address,
input   logic    [31:0]  i_address_nxt,
input   logic            i_rd,
input   logic            i_wr,

// CPSR, SR, DAC register.
input   logic    [`ZAP_CPSR_MODE] i_cpsr,
input   logic    [1:0]   i_sr,
input   logic    [31:0]  i_dac_reg,
input   logic    [31:0]  i_baddr,

// From CP15.
input   logic            i_mmu_en,
input   logic            i_inv,

// To cache FSM.
output  logic    [31:0]  o_phy_addr,
output  logic    [7:0]   o_fsr,
output  logic    [31:0]  o_far,
output  logic            o_fault,
output  logic            o_cacheable,
output  logic            o_busy,

// Wishbone memory interface - Needs to go through some OR gates.
output logic             o_wb_stb_nxt,
output logic             o_wb_cyc_nxt,
output logic [31:0]      o_wb_adr_nxt,
output logic             o_wb_wen_nxt,
output logic [3:0]       o_wb_sel_nxt,
input  logic [31:0]      i_wb_dat,
output logic [31:0]      o_wb_dat_nxt,
input  logic             i_wb_ack 

);

// ----------------------------------------------------------------------------

assign o_wb_dat_nxt = 32'd0;

`include "zap_localparams.svh"
`include "zap_defines.svh"

logic [`ZAP_SECTION_TLB_WDT-1:0]     setlb_wdata, setlb_rdata;
logic [`ZAP_LPAGE_TLB_WDT-1:0]       lptlb_wdata, lptlb_rdata;
logic [`ZAP_SPAGE_TLB_WDT-1:0]       sptlb_wdata, sptlb_rdata;
logic [`ZAP_FPAGE_TLB_WDT-1:0]       fptlb_wdata, fptlb_rdata;

logic                            sptlb_wen, lptlb_wen, setlb_wen;
logic                            sptlb_ren, lptlb_ren, setlb_ren;
logic                            fptlb_ren, fptlb_wen;
logic                            walk;
logic [7:0]                      fsr;
logic [31:0]                     far;
logic                            cacheable;
logic [31:0]                     phy_addr;
logic [31:0]                     tlb_address;
logic                            u0, u1, u2, u3, u4, u5;
logic                            unused;

// ----------------------------------------------------------------------------

function [31:0] max ( input [31:0] a, b, c, d );
             if ( a >= b && a >= c && a >= d )                max = a;
        else if ( b >= a && b >= c && b >= d )                max = b;
        else if ( c >= a && c >= b && c >= d )                max = c;
        else                                                  max = d;
endfunction 

generate 
        if      ( 10+$clog2(FPAGE_TLB_ENTRIES) == 11 ) assign u0 = i_address_nxt[11];    
        else                                           assign u0 = 1'd0;

        if      ( 12+$clog2(SPAGE_TLB_ENTRIES) == 13 ) assign u1 = i_address_nxt[13]; 
        else if ( 12+$clog2(SPAGE_TLB_ENTRIES) == 14 ) assign u1 = i_address_nxt[14]; 
        else if ( 12+$clog2(SPAGE_TLB_ENTRIES) == 15 ) assign u1 = i_address_nxt[15]; 
        else                                           assign u1 = 1'd0;

        if      ( 16+$clog2(LPAGE_TLB_ENTRIES) == 17 ) assign u2 = i_address_nxt[17]; 
        else if ( 16+$clog2(LPAGE_TLB_ENTRIES) == 18 ) assign u2 = i_address_nxt[18]; 
        else if ( 16+$clog2(LPAGE_TLB_ENTRIES) == 19 ) assign u2 = i_address_nxt[19]; 
        else                                           assign u2 = 1'd0;

        if      ( 10+$clog2(FPAGE_TLB_ENTRIES) == 11 ) assign u3 = tlb_address[11]; 
        else                                           assign u3 = 1'd0;

        if      ( 12+$clog2(SPAGE_TLB_ENTRIES) == 13 ) assign u4 = tlb_address[13]; 
        else if ( 12+$clog2(SPAGE_TLB_ENTRIES) == 14 ) assign u4 = tlb_address[14]; 
        else if ( 12+$clog2(SPAGE_TLB_ENTRIES) == 15 ) assign u4 = tlb_address[15]; 
        else                                           assign u4 = 1'd0;

        if      ( 16+$clog2(LPAGE_TLB_ENTRIES) == 17 ) assign u5 = tlb_address[17]; 
        else if ( 16+$clog2(LPAGE_TLB_ENTRIES) == 18 ) assign u5 = tlb_address[18]; 
        else if ( 16+$clog2(LPAGE_TLB_ENTRIES) == 19 ) assign u5 = tlb_address[19];
        else                                           assign u5 = 1'd0;
endgenerate 

// -----------------------------------------------------------------------------

parameter W = max (    
        20+$clog2(SECTION_TLB_ENTRIES),
        16+$clog2(LPAGE_TLB_ENTRIES),
        12+$clog2(SPAGE_TLB_ENTRIES),
        10+$clog2(FPAGE_TLB_ENTRIES)
);

assign unused = |{i_address_nxt[9:0], tlb_address[9:0], i_address_nxt[31:W], tlb_address[31:W], u0, u1, u2, u3, u4, u5};

// ----------------------------------------------------------------------------

zap_mem_inv_block #(.WIDTH(`ZAP_SECTION_TLB_WDT), .DEPTH(SECTION_TLB_ENTRIES)) 
u_section_tlb (
.i_clk          (i_clk),
.i_reset        (i_reset),

.i_wdata        (setlb_wdata),
.i_wen          (setlb_wen),
.i_ren          (1'd1),

.i_inv          (i_inv | !i_mmu_en),

.i_raddr        (i_address_nxt[`ZAP_VA__SECTION_INDEX]),
.i_waddr        (tlb_address[`ZAP_VA__SECTION_INDEX]),

.o_rdata        (setlb_rdata),
.o_rdav         (setlb_ren)
);

// ----------------------------------------------------------------------------

zap_mem_inv_block #(.WIDTH(`ZAP_LPAGE_TLB_WDT), .DEPTH(LPAGE_TLB_ENTRIES)) 
u_lpage_tlb   (
.i_clk          (i_clk),
.i_reset        (i_reset),

.i_wdata        (lptlb_wdata),
.i_wen          (lptlb_wen),
.i_ren          (1'd1),

.i_inv          (i_inv | !i_mmu_en),

.i_raddr        (i_address_nxt[`ZAP_VA__LPAGE_INDEX]),
.i_waddr        (tlb_address[`ZAP_VA__LPAGE_INDEX]),

.o_rdata        (lptlb_rdata),
.o_rdav         (lptlb_ren)
);

// ----------------------------------------------------------------------------

zap_mem_inv_block #(.WIDTH(`ZAP_SPAGE_TLB_WDT), .DEPTH(SPAGE_TLB_ENTRIES)) 
u_spage_tlb   (
.i_clk          (i_clk),
.i_reset        (i_reset),

.i_wdata        (sptlb_wdata),
.i_wen          (sptlb_wen),
.i_ren          (1'd1),

.i_inv          (i_inv | !i_mmu_en),

.i_raddr        (i_address_nxt[`ZAP_VA__SPAGE_INDEX]),
.i_waddr        (tlb_address[`ZAP_VA__SPAGE_INDEX]),

.o_rdata        (sptlb_rdata),
.o_rdav         (sptlb_ren)
);

// ----------------------------------------------------------------------------

zap_mem_inv_block #(.WIDTH(`ZAP_FPAGE_TLB_WDT), .DEPTH(FPAGE_TLB_ENTRIES))
u_fpage_tlb (
.i_clk          (i_clk),
.i_reset        (i_reset),

.i_wdata        (fptlb_wdata),
.i_wen          (fptlb_wen),
.i_ren          (1'd1),

.i_inv          (i_inv | !i_mmu_en),

.i_raddr        (i_address_nxt[`ZAP_VA__FPAGE_INDEX]),
.i_waddr        (tlb_address[`ZAP_VA__FPAGE_INDEX]),

.o_rdata        (fptlb_rdata),
.o_rdav         (fptlb_ren)

);

// ----------------------------------------------------------------------------

zap_tlb_check #(
.LPAGE_TLB_ENTRIES(LPAGE_TLB_ENTRIES), 
.SPAGE_TLB_ENTRIES(SPAGE_TLB_ENTRIES), 
.SECTION_TLB_ENTRIES(SECTION_TLB_ENTRIES),
.FPAGE_TLB_ENTRIES(FPAGE_TLB_ENTRIES)
) 
u_zap_tlb_check (

.i_mmu_en       (i_mmu_en),
.i_va           (i_address),
.i_rd           (i_rd),
.i_wr           (i_wr),

.i_cpsr         (i_cpsr),
.i_sr           (i_sr),
.i_dac_reg      (i_dac_reg),

.i_sptlb_rdata  (sptlb_rdata),
.i_sptlb_rdav   (sptlb_ren),

.i_lptlb_rdata  (lptlb_rdata),
.i_lptlb_rdav   (lptlb_ren),

.i_setlb_rdata  (setlb_rdata),
.i_setlb_rdav   (setlb_ren),

.i_fptlb_rdata  (fptlb_rdata),
.i_fptlb_rdav   (fptlb_ren),

.o_walk         (walk),
.o_fsr          (fsr),
.o_far          (far),
.o_cacheable    (cacheable),
.o_phy_addr     (phy_addr)

);

// ----------------------------------------------------------------------------

zap_tlb_fsm #(
.LPAGE_TLB_ENTRIES      (LPAGE_TLB_ENTRIES),
.SPAGE_TLB_ENTRIES      (SPAGE_TLB_ENTRIES),
.SECTION_TLB_ENTRIES    (SECTION_TLB_ENTRIES),
.FPAGE_TLB_ENTRIES      (FPAGE_TLB_ENTRIES)
) u_zap_tlb_fsm (
.i_clk          (i_clk),
.i_reset        (i_reset),
.i_mmu_en       (i_mmu_en),
.i_baddr        (i_baddr),
.i_address      (i_address),
.i_walk         (walk),
.i_fsr          (fsr),
.i_far          (far),
.i_cacheable    (cacheable),
.i_phy_addr     (phy_addr),

.o_fsr          (o_fsr),
.o_far          (o_far),
.o_fault        (o_fault),
.o_phy_addr     (o_phy_addr),
.o_cacheable    (o_cacheable),
.o_busy         (o_busy),

.o_setlb_wdata  (setlb_wdata),
.o_setlb_wen    (setlb_wen),

.o_sptlb_wdata  (sptlb_wdata),
.o_sptlb_wen    (sptlb_wen),

.o_lptlb_wdata  (lptlb_wdata),
.o_lptlb_wen    (lptlb_wen),

.o_fptlb_wdata  (fptlb_wdata),
.o_fptlb_wen    (fptlb_wen),

.o_address      (tlb_address),
.o_wb_wen       (o_wb_wen_nxt),

/* verilator lint_off PINCONNECTEMPTY */
.o_wb_cyc       (),
.o_wb_stb       (),
.o_wb_sel       (),
.o_wb_adr       (),
/* verilator lint_on PINCONNECTEMPTY */

.i_wb_dat       (i_wb_dat),
.i_wb_ack       (i_wb_ack),

.o_wb_sel_nxt   (o_wb_sel_nxt),
.o_wb_cyc_nxt   (o_wb_cyc_nxt),
.o_wb_stb_nxt   (o_wb_stb_nxt),
.o_wb_adr_nxt   (o_wb_adr_nxt)
);

// ----------------------------------------------------------------------------

endmodule

