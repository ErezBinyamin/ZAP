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
// --  This is the simple I-cache frontend to the processor. This stage       --
// --  serves as a buffer for instructions. Data aborts are handled by adding --
// --  an extra signal down the pipeline. Data aborts piggyback off           --
// --  AND R0, R0, R0.                                                        --
// --                                                                         --
// -----------------------------------------------------------------------------



module zap_fetch_main #(
        // Branch predictor entries.
        parameter BP_ENTRIES = 1024
)
(
// Clock and reset.
input logic i_clk,          // ZAP clock.        
input logic i_reset,        // Active high synchronous reset.

// 
// From other parts of the pipeline. These
// signals either tell the unit to invalidate
// its outputs or freeze in place.
//
input logic i_code_stall,           // |      
input logic i_clear_from_writeback, // | High Priority.
input logic i_data_stall,           // |
input logic i_clear_from_alu,       // |
input logic i_stall_from_shifter,   // |
input logic i_stall_from_issue,     // |
input logic i_stall_from_decode,    // | Low Priority.
input logic i_clear_from_decode,    // V

// Comes from WB unit.
input logic [31:0] i_pc_ff,         // Program counter.

// Comes from CPSR
input logic        i_cpsr_ff_t,     // CPSR T bit.

// From I-cache.
input logic [31:0] i_instruction,   // A 32-bit ZAP instruction.

input logic        i_valid,         // Instruction valid indicator.
input logic        i_instr_abort,   // Instruction abort fault.


// To decode.
output logic [31:0]  o_instruction,  // The 32-bit instruction.
output logic         o_valid,        // Instruction valid.
output logic         o_instr_abort,  // Indication of an abort.       
output logic [31:0]  o_pc_plus_8_ff, // PC +8 ouput.
output logic [31:0]  o_pc_ff,        // PC output.

// For BP.
input logic         i_confirm_from_alu,  // Confirm branch prediction from ALU.
input logic [31:0]  i_pc_from_alu,       // Address of branch. 
input logic [1:0]   i_taken,             // Predicted status.
output logic [1:0]  o_taken              // Prediction. Not a flip-flop...

);

`include "zap_defines.svh"
`include "zap_localparams.svh"

// If an instruction abort occurs, this unit sleeps until it is woken up.
logic sleep_ff;

// Taken_v
logic [1:0] taken_v;

// Unused.
logic unused;

// Branch states.
localparam  [1:0]    SNT     =       2'b00; // Strongly Not Taken.
localparam  [1:0]    WNT     =       2'b01; // Weakly Not Taken.
localparam  [1:0]    WT      =       2'b10; // Weakly Taken.
localparam  [1:0]    ST      =       2'b11; // Strongly Taken.

// Predict non branches as not taken...
assign o_taken    = o_instruction[28:26] == 3'b101 ? taken_v : SNT;

// Unused
assign unused = |{i_pc_from_alu[0], i_pc_from_alu[31:$clog2(BP_ENTRIES)+1]};

// ----------------------------------------------------------------------------



//
// NOTE: If an instruction is invalid, only then can it be tagged with any
// kind of interrupt. Thus, the MMU must make instruction valid as 1 before
// attaching an abort interrupt to it even though the instruction generated
// might be invalid. Such an instruction is not actually executed.
//

//
// This stage simply forwards data from the
// I-cache downwards.
//
always_ff @ (posedge i_clk)
begin
        if (  i_reset )                          
        begin
                o_pc_plus_8_ff  <= 0;
                o_pc_ff         <= 0;
                o_instruction   <= 0;

                // Unit has no valid output.
                o_valid         <= 1'd0;

                // Do not signal any abort.
                o_instr_abort   <= 1'd0;

                // Wake unit up.
                sleep_ff        <= 1'd0;
        end
        else if ( i_clear_from_writeback )       clear_unit;
        else if ( i_data_stall)                  begin end // Save state.
        else if ( i_clear_from_alu )             clear_unit;
        else if ( i_stall_from_shifter )         begin end // Save state.
        else if ( i_stall_from_issue )           begin end // Save state.
        else if ( i_stall_from_decode)           begin end // Save state.
        else if ( i_clear_from_decode )          clear_unit;
        else if ( i_code_stall )                 begin end

        // If unit is sleeping.
        else if ( sleep_ff ) 
        begin
                // Nothing valid to be sent.
                o_valid         <= 1'd0;

                // No aborts.
                o_instr_abort   <= 1'd0;

                // Keep sleeping.
                sleep_ff        <= 1'd1;        
        end

        // Data from memory is valid. This could also be used to signal
        // an instruction access abort.
        else if ( i_valid )
        begin
                // Instruction aborts occur with i_valid as 1. See NOTE.
                o_valid         <= 1'd1;
                o_instr_abort   <= i_instr_abort;

                // Put unit to sleep on an abort.
                sleep_ff        <= i_instr_abort;

                //
                // Pump PC + 8 or 4 down the pipeline. The number depends on
                // ARM/Compressed mode.
                //
                o_pc_plus_8_ff <= i_cpsr_ff_t ? ( i_pc_ff + 32'd4 ) : 
                                                ( i_pc_ff + 32'd8 );

                // PC is pumped down the pipeline.
                o_pc_ff <= i_pc_ff;

                // Instruction. If 16-bit aligned address, move data from
                // cache by 16-bit to focus on the instruction.
                o_instruction <= i_pc_ff[1] ? i_instruction >> 16 : i_instruction;
        end
        else
        begin
                // Invalidate the output.
                o_valid        <= 1'd0;
        end
end

// ----------------------------------------------------------------------------

//
// Branch State RAM.
// Holds the 2-bit state for a range of branches. Whenever a branch is
// either detected as correctly taken or incorrectly taken, this RAM is
// updated. Each entry in the RAM corresponds to a virtual memory address
// whether or not it be a legit branch or not. 
//
zap_ram_simple
#(.DEPTH(BP_ENTRIES), .WIDTH(2)) u_br_ram
(
        .i_clk(i_clk),

        // The reason that a no-stall condition is included is that
        // if the pipeline stalls, this memory should be trigerred multiply
        // times.
        .i_wr_en(       !i_data_stall             && 
                        !i_stall_from_issue       && 
                        !i_stall_from_decode      && 
                        !i_stall_from_shifter     && 
                        (i_clear_from_alu || i_confirm_from_alu)),

        // Lower bits of the PC index into the branch RAM for read and
        // write addresses.
        .i_wr_addr(i_pc_from_alu[$clog2(BP_ENTRIES):1]),
        .i_rd_addr(i_pc_ff[$clog2(BP_ENTRIES):1]),

        // Write the new state.
        .i_wr_data(compute(i_taken, i_clear_from_alu)),

        // Read when there is no stall.
        .i_rd_en( 
                        !i_code_stall             &&
                        !i_data_stall             && 
                        !i_stall_from_issue       && 
                        !i_stall_from_decode      && 
                        !i_stall_from_shifter      
        ),

        // Send the read data over to o_taken_ff which is a 2-bit value.
        .o_rd_data(taken_v) 
);

// ----------------------------------------------------------------------------

//
// Branch Memory writes.
// Implements a 4-state predictor. 
//
function [1:0] compute ( input [1:0] taken, input clear_from_alu );
begin
                // Branch was predicted incorrectly. 
                if ( clear_from_alu )
                begin
                        case ( taken )
                        SNT: compute = WNT;
                        WNT: compute = WT;
                        WT:  compute = WNT;
                        ST:  compute = WT;
                        endcase
                end
                else // Confirm from alu that branch was correctly predicted.
                begin
                        case ( taken )
                        SNT: compute = SNT;
                        WNT: compute = SNT;
                        WT:  compute = ST;
                        ST:  compute = ST;
                        endcase
                end
end
endfunction

// ----------------------------------------------------------------------------

//
// This task automatic clears out the unit and refreshes it for a new
// service session. Will wake the unit up and clear the outputs.
//
task automatic clear_unit;
begin
                // No valid output.
                o_valid         <= 1'd0;

                // No aborts since we are clearing out the unit.
                o_instr_abort   <= 1'd0;

                // Wake up the unit.
                sleep_ff        <= 1'd0;
end
endtask

// ----------------------------------------------------------------------------

zap_decompile u_zap_decompile (
        .i_instruction  ({4'd0, o_instruction}),
        .i_dav          (o_valid),
        /* verilator lint_off PINCONNECTEMPTY */
        .o_decompile    ()
        /* verilator lint_on PINCONNECTEMPTY */

);


endmodule // zap_fetch_main.v



// ----------------------------------------------------------------------------
// EOF
// ----------------------------------------------------------------------------
