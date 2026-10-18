// ============================================================================
// File: lru_array.sv
// Description: Implements 1-bit True LRU replacement tracking for 16 sets.
//              Convention: lru_bit points directly to the next victim to replace.
//              - lru_bit == 0 -> Way 0 is the victim
//              - lru_bit == 1 -> Way 1 is the victim
// ============================================================================

`include "cache_def.sv"
import cache_def::*;

module lru_array (
    input  logic                          clk,
    input  logic                          rst_n,

    // Set being accessed
    input  logic [SET_INDEX_WIDTH-1:0]    set_index,

    // Victim output: Which way should be replaced on a miss?
    output logic                          lru_victim,

    // Update controls: Triggered whenever a way is touched (Hit or Refill)
    input  logic                          update_en,
    input  logic                          accessed_way // 0 = Way 0 was used, 1 = Way 1 was used
);

    // 16 Sets x 1 bit
    logic lru_ram [0:NUM_SETS-1];

    // Combinational read of the current set's LRU victim pointer
    assign lru_victim = lru_ram[set_index];

    // Synchronous update
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // On reset, default all victim pointers to Way 0
            for (int i = 0; i < NUM_SETS; i++) begin
                lru_ram[i] <= 1'b0;
            end
        end else if (update_en) begin
            // Point the victim arrow to the OPPOSITE way of what was just used
            lru_ram[set_index] <= ~accessed_way;
        end
    end

endmodule
