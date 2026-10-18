// ============================================================================
// File: cache_data_array.sv
// Description: Stores 16 sets x 2 ways x 128-bit (16-Byte) cache lines.
//              Supports whole-line refills, byte-enabled CPU word writes,
//              and snoop read-out for dirty cache-to-cache / cache-to-memory sharing.
// ============================================================================

`include "cache_def.sv" 
import cache_def::*;

module cache_data_array (
    input  logic                          clk,

    // ------------------------------------------------------------------------
    // Port A: Local CPU / FSM Port
    // ------------------------------------------------------------------------
    input  logic [SET_INDEX_WIDTH-1:0]    cpu_index,
    input  logic [WORD_OFFSET_WIDTH-1:0]  cpu_word_offset, // Which of the 4 words?
    
    // Read-Out Lines for Local Hit Evaluation
    output logic [LINE_WIDTH_BITS-1:0]    line_way0_out,
    output logic [LINE_WIDTH_BITS-1:0]    line_way1_out,

    // Full 128-bit Line Write (Used during Refill from Main Memory)
    input  logic                          fill_en_way0,
    input  logic                          fill_en_way1,
    input  logic [LINE_WIDTH_BITS-1:0]    fill_data,

    // Single 32-bit Word Write with Byte Enables (Used on CPU Write Hit)
    input  logic                          word_wr_en_way0,
    input  logic                          word_wr_en_way1,
    input  logic [DATA_WIDTH-1:0]         word_wr_data,
    input  logic [3:0]                    byte_en,

    // ------------------------------------------------------------------------
    // Port B: Snoop Read Port (Supplying dirty line to peer core/memory)
    // ------------------------------------------------------------------------
    input  logic [SET_INDEX_WIDTH-1:0]    snoop_index,
    input  logic                          snoop_way, // 0 = Way 0, 1 = Way 1
    output logic [LINE_WIDTH_BITS-1:0]    snoop_data_out
);

    // ------------------------------------------------------------------------
    // Internal Storage: 16 Sets x 2 Ways x 128 bits
    // ------------------------------------------------------------------------
    logic [LINE_WIDTH_BITS-1:0] data_ram_way0 [0:NUM_SETS-1];
    logic [LINE_WIDTH_BITS-1:0] data_ram_way1 [0:NUM_SETS-1];

    // ------------------------------------------------------------------------
    // Combinational Reads
    // ------------------------------------------------------------------------
    assign line_way0_out   = data_ram_way0[cpu_index];
    assign line_way1_out   = data_ram_way1[cpu_index];

    assign snoop_data_out  = (snoop_way == 1'b0) ? data_ram_way0[snoop_index] 
                                                 : data_ram_way1[snoop_index];

    // ------------------------------------------------------------------------
    // Synchronous Writes
    // ------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        // --- WAY 0 WRITES ---
        if (fill_en_way0) begin
            // 128-bit line refill has highest priority
            data_ram_way0[cpu_index] <= fill_data;
        end else if (word_wr_en_way0) begin
            // 32-bit word write with byte-enables
            data_ram_way0[cpu_index] <= apply_word_write(
                data_ram_way0[cpu_index],
                cpu_word_offset,
                word_wr_data,
                byte_en
            );
        end

        // --- WAY 1 WRITES ---
        if (fill_en_way1) begin
            // 128-bit line refill has highest priority
            data_ram_way1[cpu_index] <= fill_data;
        end else if (word_wr_en_way1) begin
            // 32-bit word write with byte-enables
            data_ram_way1[cpu_index] <= apply_word_write(
                data_ram_way1[cpu_index],
                cpu_word_offset,
                word_wr_data,
                byte_en
            );
        end
    end

endmodule
