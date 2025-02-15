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
// --  Implements store FIFO. Serves as a bridge between the processor core & --
// --  the memory interface.                                                  --
// --                                                                         --
// -----------------------------------------------------------------------------



module zap_wb_adapter #(parameter DEPTH = 32) (

// Clock.
input logic                   i_clk,
input logic                   i_reset,

// Processor Wishbone interface. These come from the Wishbone registered
// interface.
input logic                   I_WB_CYC,
input logic                   I_WB_STB,   
input logic [3:0]             I_WB_SEL,     
input logic [2:0]             I_WB_CTI,   
input logic [31:0]            I_WB_ADR,    
input logic [31:0]            I_WB_DAT,    
input logic                   I_WB_WE,
output logic [31:0]           O_WB_DAT,    
output logic                  O_WB_ACK,     

// Wishbone interface.
output logic                  o_wb_cyc,
output logic                  o_wb_stb,
output logic     [31:0]       o_wb_dat,
output logic     [31:0]       o_wb_adr,
output logic     [3:0]        o_wb_sel,
output logic     [2:0]        o_wb_cti,
output logic                  o_wb_we,
input logic      [31:0]       i_wb_dat,
input logic                   i_wb_ack
);

`include "zap_defines.svh"
`include "zap_localparams.svh"

logic  fsm_write_en;
logic  [69:0] fsm_write_data;
logic  w_eob;
logic  w_full;
logic  unused;
logic  w_emp;
logic  o_wb_stb_nxt;
logic  o_wb_cyc_nxt;
logic  emp_nxt;
logic  emp_ff;
logic  [31:0] ctr_nxt, ctr_ff;
logic  [31:0] dff, dnxt;
logic  ack;        // ACK write channel.
logic  ack_ff;     // Read channel.

localparam IDLE = 0;
localparam PRPR_RD_SINGLE = 1;
localparam PRPR_RD_BURST = 2;
localparam WRITE = 3;
localparam WAIT1 = 5;
localparam WAIT2 = 6;
localparam NUMBER_OF_STATES = 7;

logic [$clog2(NUMBER_OF_STATES)-1:0] state_ff, state_nxt;

zap_sync_fifo #(.WIDTH(32'd70), .DEPTH(DEPTH), .FWFT(32'd0)) U_STORE_FIFO (
.i_clk          (i_clk),
.i_reset        (i_reset),
.i_ack          ((i_wb_ack && o_wb_stb) || emp_ff),
.i_wr_en        (fsm_write_en),
.i_data         (fsm_write_data),
.o_data         ({o_wb_sel, o_wb_dat, o_wb_adr, w_eob, o_wb_we}),
.o_empty        (w_emp),
.o_full         (w_full),

/* verilator lint_off PINCONNECTEMPTY */
.o_empty_n      (),
.o_full_n       (),
.o_full_n_nxt   ()
/* verilator lint_on PINCONNECTEMPTY */
);

assign unused = |{I_WB_CYC};

// FIFO pipeline register and nxt state logic.
always_comb
begin
        o_wb_cti     = {w_eob, 1'd1, w_eob};
        emp_nxt      = emp_ff;
        o_wb_stb_nxt = o_wb_stb;
        o_wb_cyc_nxt = o_wb_cyc;

        if ( i_reset ) 
        begin
                emp_nxt      = 1'd1;
                o_wb_stb_nxt = 1'd0;
                o_wb_cyc_nxt = 1'd0;
        end
        else if ( emp_ff || (i_wb_ack && o_wb_stb) ) 
        begin
                emp_nxt      = w_emp;
                o_wb_stb_nxt = !w_emp;
                o_wb_cyc_nxt = !w_emp;
        end
end

always_ff @ (posedge i_clk)
begin
        emp_ff   <= emp_nxt;
        o_wb_stb <= o_wb_stb_nxt;
        o_wb_cyc <= o_wb_cyc_nxt;
end

// Flip flop clocking block.
always_ff @ (posedge i_clk)
begin
        if ( i_reset )
        begin
                state_ff <= IDLE;
                ctr_ff   <= 0;
                dff      <= 0;
        end
        else
        begin
                state_ff <= state_nxt;
                ctr_ff   <= ctr_nxt;
                dff      <= dnxt;
        end
end

// Reads from the Wishbone bus are flopped.
always_ff @ (posedge i_clk)
begin
        if ( i_reset )
        begin
                ack_ff  <= 1'd0;
                O_WB_DAT <= 0;
        end
        else if ( !o_wb_we && o_wb_cyc && o_wb_stb && i_wb_ack )
        begin
                ack_ff   <= 1'd1;
                O_WB_DAT <= i_wb_dat;
        end
        else
        begin
                ack_ff <= 1'd0;
        end
end

localparam BURST_LEN = 4;

// OR from flop and mealy FSM output.
always_comb O_WB_ACK = ack_ff | ack;

// State machine.
always_comb
begin:blk1
        logic [31:0] adr;

        adr = 0;
        state_nxt = state_ff;
        ctr_nxt = ctr_ff;
        ack = 0;
        dnxt = dff;
        fsm_write_en = 0;
        fsm_write_data = 0;

        case(state_ff)
        IDLE:
        begin
                ctr_nxt = 0;
                dnxt = 0;

                if ( I_WB_STB && I_WB_WE && !o_wb_stb ) // Wishbone write request 
                begin
                        // Simply buffer stores into the FIFO.
                        state_nxt = WRITE;
                end   
                else if ( I_WB_STB && !I_WB_WE && !o_wb_stb ) // Wishbone read request
                begin
                        // Write a set of reads into the FIFO.
                        if ( I_WB_CTI == CTI_BURST ) // Burst of 4 words. Each word is 4 byte.
                        begin
                                state_nxt = PRPR_RD_BURST;
                        end
                        else // Single.
                        begin
                                state_nxt = PRPR_RD_SINGLE; 
                        end
                end
        end

        PRPR_RD_SINGLE: // Write a single read token into the FIFO.
        begin
                if ( !w_full )
                begin
                        state_nxt = WAIT1;
                        fsm_write_en = 1'd1;
                        fsm_write_data = {      I_WB_SEL, 
                                                I_WB_DAT, 
                                                I_WB_ADR, 
                                                I_WB_CTI != CTI_BURST ? 1'd1 : 1'd0, 
                                                1'd0};
                end
        end

        PRPR_RD_BURST: // Write burst read requests into the FIFO.
        begin
                if ( O_WB_ACK )
                begin
                        dnxt = dff + 1'd1;
                end

                if ( ctr_ff == BURST_LEN * 4 )
                begin
                        ctr_nxt = 0;
                        state_nxt = WAIT2; // FIFO prep done.
                end
                else if ( !w_full )
                begin
                        adr = {I_WB_ADR[31:4], 4'd0} + ctr_ff; // Ignore lower 4-bits.

                        fsm_write_en = 1'd1;
                        fsm_write_data = {      I_WB_SEL, 
                                                I_WB_DAT, 
                                                adr, 
                                                ctr_ff == 12 ? 1'd1 : 1'd0, 
                                                1'd0 };
                        ctr_nxt = ctr_ff + 4;
                end                
        end

        WRITE:
        begin
                // As long as requests exist, write them out to the FIFO.
                if ( I_WB_STB && I_WB_WE )
                begin
                        if ( !w_full )
                        begin
                                fsm_write_en    = 1'd1;
                                fsm_write_data  =  {I_WB_SEL, I_WB_DAT, I_WB_ADR, I_WB_CTI != CTI_BURST ? 1'd1 : 1'd0, 1'd1};
                                ack = 1'd1;
                        end
                end
                else // Writes done!
                begin
                        state_nxt = IDLE;
                end
        end

        WAIT1: // Wait for single read to complete.
        begin
                if ( O_WB_ACK )
                begin
                        state_nxt = IDLE;
                end
        end

        WAIT2: // Wait for burst reads to complete.
        begin
                if ( O_WB_ACK )
                begin
                        dnxt = dff + 1;
                end

                if ( dff == BURST_LEN && !o_wb_stb )
                begin
                        state_nxt = IDLE;
                end
        end

        endcase
end

endmodule



// ----------------------------------------------------------------------------
// EOF
// ----------------------------------------------------------------------------
