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
// --  The pre-decode block. Does partial instruction decoding and sequencing --
// --  before passing the instruction onto the next stage.                    --
// --                                                                         --
// -----------------------------------------------------------------------------


module zap_predecode_main #( parameter PHY_REGS = 46     )

(
        // Clock and reset.
        input   logic                            i_clk,
        input   logic                            i_reset,

        // Branch state.
        input   logic     [1:0]                  i_taken,
        input   logic                            i_force32,
        input   logic                            i_und,

        // Clear and stall signals. From high to low priority.
        input logic                              i_clear_from_writeback, // |Pri 
        input logic                              i_data_stall,           // |
        input logic                              i_clear_from_alu,       // |
        input logic                              i_stall_from_shifter,   // |
        input logic                              i_stall_from_issue,     // V

        // Interrupt events.
        input   logic                            i_irq,
        input   logic                            i_fiq,
        input   logic                            i_abt,

        // Is 0 if all pipeline is invalid. Used for coprocessor.
        input   logic                            i_pipeline_dav, 

        // Coprocessor done.
        input   logic                            i_copro_done,

        // PC input.
        input logic  [31:0]                      i_pc_ff,
        input logic  [31:0]                      i_pc_plus_8_ff,

        // CPU mode. Taken from CPSR in the ALU.
        input   logic                            i_cpu_mode_t, // T mode.
        input   logic [4:0]                      i_cpu_mode_mode, // CPU mode.

        // Instruction input.
        input     logic  [34:0]                  i_instruction,    
        input     logic                          i_instruction_valid,

        // Instruction output      
        output logic [39:0]                       o_instruction_ff,
        output logic                              o_instruction_valid_ff,
     
        // Stall of PC and fetch.
        output  logic                             o_stall_from_decode,

        // PC output.
        output  logic  [31:0]                     o_pc_plus_8_ff,       
        output  logic  [31:0]                     o_pc_ff,

        // Interrupts.
        output  logic                             o_irq_ff,
        output  logic                             o_fiq_ff,
        output  logic                             o_abt_ff,
        output  logic                             o_und_ff,

        // Force 32-bit alignment on memory accesses.
        output logic                              o_force32align_ff,

        // Coprocessor interface.
        output logic                             o_copro_dav_ff,
        output logic  [31:0]                     o_copro_word_ff,

        // Branch.
        output logic   [1:0]                      o_taken_ff,

        // Clear from decode.
        output logic                              o_clear_from_decode,
        output logic [31:0]                       o_pc_from_decode
);

`include "zap_defines.svh"
`include "zap_localparams.svh"

localparam ST = 3; 

logic [39:0]                     o_instruction_nxt;
logic                            o_instruction_valid_nxt;
logic                            mem_fetch_stall;
logic                            arm_irq;
logic                            arm_fiq;
logic                            irq_mask;
logic                            fiq_mask;
logic [34:0]                     arm_instruction;
logic                            arm_instruction_valid;
logic                            cp_stall;
logic [34:0]                     cp_instruction;
logic                            cp_instruction_valid;
logic                            cp_irq;
logic                            cp_fiq;
logic [1:0]                      taken_nxt;

///////////////////////////////////////////////////////////////////////////////

// Flop the outputs to break the pipeline at this point.
always_ff @ (posedge i_clk)
begin
        if ( i_reset )
        begin
                reset;
                clear;
        end
        else if ( i_clear_from_writeback )
        begin
                clear;
        end
        else if ( i_data_stall )
        begin
                // Preserve state.
        end
        else if ( i_clear_from_alu )
        begin
                clear;
        end
        else if ( i_stall_from_shifter )
        begin
                // Preserve state.
        end
        else if ( i_stall_from_issue )
        begin
                // Preserve state.
        end
        // If no stall, only then update...
        else
        begin
                // Do not pass IRQ and FIQ if mask is 1.
                o_irq_ff               <= i_irq & irq_mask; 
                o_fiq_ff               <= i_fiq & fiq_mask; 
                o_abt_ff               <= i_abt;                    
                o_und_ff               <= i_und && i_instruction_valid;
                o_pc_plus_8_ff         <= i_pc_plus_8_ff;
                o_pc_ff                <= i_pc_ff;
                o_force32align_ff      <= i_force32;
                o_taken_ff             <= taken_nxt;
                o_instruction_ff       <= o_instruction_nxt;
                o_instruction_valid_ff <= o_instruction_valid_nxt;
        end
end

task automatic reset;
begin
                o_irq_ff               <= 0; 
                o_fiq_ff               <= 0; 
                o_abt_ff               <= 0; 
                o_und_ff               <= 0; 
                o_pc_plus_8_ff         <= 0; 
                o_pc_ff                <= 0; 
                o_force32align_ff      <= 0; 
                o_taken_ff             <= 0; 
                o_instruction_ff       <= 0; 
                o_instruction_valid_ff <= 0; 
end
endtask

task automatic clear;
begin
                o_irq_ff                                <= 0;
                o_fiq_ff                                <= 0;
                o_abt_ff                                <= 0; 
                o_und_ff                                <= 0;
                o_taken_ff                              <= 0;
                o_instruction_valid_ff                  <= 0;
end
endtask

always_comb
begin
        o_stall_from_decode = mem_fetch_stall || cp_stall;
end

///////////////////////////////////////////////////////////////////////////////

// This unit handles coprocessor stuff.
zap_predecode_coproc 
#(
        .PHY_REGS(PHY_REGS)
)
u_zap_decode_coproc
(
        // Inputs from outside world.
        .i_clk(i_clk),
        .i_reset(i_reset),
        .i_irq(i_irq),
        .i_fiq(i_fiq),
        .i_instruction(i_instruction_valid ? i_instruction : 35'd0),
        .i_valid(i_instruction_valid),
        .i_cpsr_ff_t(i_cpu_mode_t),
        .i_cpsr_ff_mode(i_cpu_mode_mode),

        // Clear and stall signals.
        .i_clear_from_writeback(i_clear_from_writeback),
        .i_data_stall(i_data_stall),          
        .i_clear_from_alu(i_clear_from_alu),      
        .i_stall_from_issue(i_stall_from_issue), 
        .i_stall_from_shifter(i_stall_from_shifter),

        // Valid signals.
        .i_pipeline_dav (i_pipeline_dav),

        // Coprocessor
        .i_copro_done(i_copro_done),

        // Output to next block.
        .o_instruction(cp_instruction),
        .o_valid(cp_instruction_valid),
        .o_irq(cp_irq),
        .o_fiq(cp_fiq),

        // Stall.
        .o_stall_from_decode(cp_stall),

        // Coprocessor interface.
        .o_copro_dav_ff(o_copro_dav_ff),
        .o_copro_word_ff(o_copro_word_ff)
);



///////////////////////////////////////////////////////////////////////////////

assign arm_instruction          = cp_instruction;
assign arm_instruction_valid    = cp_instruction_valid;
assign arm_irq                  = cp_irq;
assign arm_fiq                  = cp_fiq;

///////////////////////////////////////////////////////////////////////////////

always_comb
begin:bprblk1
        logic [31:0] addr;
        logic [31:0] addr_final;

        o_clear_from_decode     = 1'd0;
        o_pc_from_decode        = 32'd0;
        taken_nxt               = i_taken;
        addr                    = {{8{arm_instruction[23]}},arm_instruction[23:0]}; // Offset.
        
        if ( arm_instruction[34] )      // Indicates a left shift of 1 i.e., X = X * 2.
                addr_final = addr << 1;
        else                            // Indicates a left shift of 2 i.e., X = X * 4.
                addr_final = addr << 2;

        //
        // Perform actions as mentioned by the predictor unit in the fetch
        // stage.
        //
        if ( arm_instruction[27:25] == 3'b101 && arm_instruction_valid )
        begin
                if ( i_taken[1] || arm_instruction[31:28] == AL ) 
                // Taken or Strongly Taken or Always taken.
                begin
                        // Take the branch. Clear pre-fetched instruction.
                        o_clear_from_decode = 1'd1;

                        // Predict new PC.
                        o_pc_from_decode    = i_pc_plus_8_ff + addr_final;

                       if ( arm_instruction[31:28] == AL ) 
                                taken_nxt = ST;  
                end
                else // Not Taken or Weakly Not Taken.
                begin
                        // Else dont take the branch since pre-fetched 
                        // instruction is correct.
                        o_clear_from_decode = 1'd0;
                        o_pc_from_decode    = 32'd0;
                end
        end
end

///////////////////////////////////////////////////////////////////////////////

// This FSM handles LDM/STM/SWAP/SWAPB/BL/LMULT
zap_predecode_uop_sequencer u_zap_uop_sequencer (
        .i_clk(i_clk),
        .i_reset(i_reset),
        .i_instruction(arm_instruction),
        .i_instruction_valid(arm_instruction_valid),
        .i_fiq(arm_fiq),
        .i_irq(arm_irq),
        .i_cpsr_t(i_cpu_mode_t),


        .i_clear_from_writeback(i_clear_from_writeback),
        .i_data_stall(i_data_stall),          
        .i_clear_from_alu(i_clear_from_alu),      
        .i_issue_stall(i_stall_from_issue), 
        .i_stall_from_shifter(i_stall_from_shifter),

        .o_irq(irq_mask),
        .o_fiq(fiq_mask),
        .o_instruction(o_instruction_nxt), // 40-bit, upper 4 bits RESERVED.
        .o_instruction_valid(o_instruction_valid_nxt),
        .o_stall_from_decode(mem_fetch_stall)
);

///////////////////////////////////////////////////////////////////////////////

endmodule

