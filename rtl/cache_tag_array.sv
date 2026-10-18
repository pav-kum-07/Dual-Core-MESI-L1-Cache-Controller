// ============================================================================
// File: cache_tag_array.sv
// Description: Tag and MESI Coherence State Storage Array for the 2-Way
//              Set-Associative Cache.
//
// Core Responsibilities:
// 1. Physical Metadata Storage:
//    - Holds 24-bit Tags for Way 0 & Way 1 across all 16 sets (768 bits total).
//    - Holds 2-bit MESI states for Way 0 & Way 1 across all 16 sets (64 bits total).
//
// 2. Parallel Hit Evaluation & Status Driving (Combinational Logic):
//    - Port A (CPU): Concurrently checks cpu_tag against Way 0 and Way 1.
//      Drives hit_way0, hit_way1, state_way0, state_way1, tag_way0_out, tag_way1_out.
//      (A Hit occurs when: Stored Tag == CPU Tag AND Stored State != INVALID).
//    - Port B (Snooper): Dual-port read of OUR cache at snoop_index.
//      Compares snoop_tag against our Way 0 and Way 1 tags to detect if a peer's
//      bus request hits in our cache, driving snoop_hit, snoop_hit_way, snoop_state.
//
// 3. Synchronous Updates (Sequential Logic on clk edge):
//    - Local Writes: Updates Tag & State on miss refills (FSM_ALLOCATE) or
//      write upgrades (FSM_IDLE / FSM_UPGRADE) using wr_en_way0 / wr_en_way1.
//    - Snoop Updates: Invalidation (-> INVALID) or downgrades (M/E -> SHARED)
//      requested by peer bus transactions using snoop_wr_en.
// ============================================================================

`include "cache_def.sv"
import cache_def::*;

module cache_tag_array (
    input  logic                     clk,
    input  logic                     rst_n,

    // ------------------------------------------------------------------------
    // Port A: CPU / Local FSM Lookup & Update Port
    // ------------------------------------------------------------------------
    input  logic [SET_INDEX_WIDTH-1:0] cpu_index,
    input  logic [TAG_WIDTH-1:0]       cpu_tag,
    
    // Combinational Hit & State Outputs for CPU
    output logic                       hit_way0,
    output logic                       hit_way1,
    output mesi_state_t                state_way0,
    output mesi_state_t                state_way1,
    output logic [TAG_WIDTH-1:0]       tag_way0_out,
    output logic [TAG_WIDTH-1:0]       tag_way1_out,

    // Write / State Update Controls (from local FSM)
    input  logic                       wr_en_way0,
    input  logic                       wr_en_way1,
    input  logic [TAG_WIDTH-1:0]       wr_tag,
    input  mesi_state_t                wr_state,

    // ------------------------------------------------------------------------
    // Port B: Snooping Port (Peer Core Bus Invalidation / Interrogation)
    // ------------------------------------------------------------------------
    input  logic [SET_INDEX_WIDTH-1:0] snoop_index,
    input  logic [TAG_WIDTH-1:0]       snoop_tag,

    // Snoop Hit & State Outputs
    output logic                       snoop_hit,
    output logic                       snoop_hit_way, // 0 = Way 0, 1 = Way 1
    output mesi_state_t                snoop_state,

    // Snoop State Invalidation/Downgrade Controls (e.g. S -> I, M -> S/I)
    input  logic                       snoop_wr_en,
    input  logic                       snoop_wr_way,
    input  mesi_state_t                snoop_wr_state
);

    // ------------------------------------------------------------------------
    // Internal Tag and State Storage (16 Sets x 2 Ways)
    // ------------------------------------------------------------------------
    logic [TAG_WIDTH-1:0] tag_ram_way0 [0:NUM_SETS-1];
    logic [TAG_WIDTH-1:0] tag_ram_way1 [0:NUM_SETS-1];
    mesi_state_t          state_ram_way0 [0:NUM_SETS-1];
    mesi_state_t          state_ram_way1 [0:NUM_SETS-1];

    // ------------------------------------------------------------------------
    // Port A: Combinational Read & Parallel Comparators (Local CPU)
    // ------------------------------------------------------------------------
    assign tag_way0_out = tag_ram_way0[cpu_index];
    assign tag_way1_out = tag_ram_way1[cpu_index];
    assign state_way0   = state_ram_way0[cpu_index];
    assign state_way1   = state_ram_way1[cpu_index];

    // A Hit requires: Tag matches AND State is not INVALID
    assign hit_way0 = (cpu_tag == tag_way0_out) && (state_way0 != INVALID);
    assign hit_way1 = (cpu_tag == tag_way1_out) && (state_way1 != INVALID);

    // ------------------------------------------------------------------------
    // Port B: Combinational Read & Parallel Comparators (Bus Snooping)
    // ------------------------------------------------------------------------
    logic [TAG_WIDTH-1:0] snoop_tag_way0;
    logic [TAG_WIDTH-1:0] snoop_tag_way1;
    mesi_state_t          snoop_state_way0;
    mesi_state_t          snoop_state_way1;
    logic                 snoop_hit_way0;
    logic                 snoop_hit_way1;

    // Dual-Port Read: Reads OUR local cache's stored tags & states at snoop_index.
    // (Checks if our cache holds the block currently being requested by a peer on the bus)
    assign snoop_tag_way0   = tag_ram_way0[snoop_index];
    assign snoop_tag_way1   = tag_ram_way1[snoop_index];
    assign snoop_state_way0 = state_ram_way0[snoop_index];
    assign snoop_state_way1 = state_ram_way1[snoop_index];

    assign snoop_hit_way0 = (snoop_tag == snoop_tag_way0) && (snoop_state_way0 != INVALID);
    assign snoop_hit_way1 = (snoop_tag == snoop_tag_way1) && (snoop_state_way1 != INVALID);

    assign snoop_hit     = snoop_hit_way0 | snoop_hit_way1;
    assign snoop_hit_way = snoop_hit_way1; // 1 if Way 1 hit, 0 if Way 0 hit
    assign snoop_state   = snoop_hit_way1 ? snoop_state_way1 : snoop_state_way0;

    // ------------------------------------------------------------------------
    // Sequential Updates: Reset and Synchronous Writes
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all 16 Sets to INVALID
            for (int i = 0; i < NUM_SETS; i++) begin
                tag_ram_way0[i]   <= '0;
                tag_ram_way1[i]   <= '0;
                state_ram_way0[i] <= INVALID;
                state_ram_way1[i] <= INVALID;
            end
        end else begin
            // 1. Local FSM Updates (Refill, Allocate, or Local Write)
            if (wr_en_way0) begin
                tag_ram_way0[cpu_index]   <= wr_tag;
                state_ram_way0[cpu_index] <= wr_state;
            end
            if (wr_en_way1) begin
                tag_ram_way1[cpu_index]   <= wr_tag;
                state_ram_way1[cpu_index] <= wr_state;
            end

            // 2. Snoop Port Updates (Downgrades or Invalidation from Peer Core)
            if (snoop_wr_en) begin
                if (snoop_wr_way == 1'b0) begin
                    state_ram_way0[snoop_index] <= snoop_wr_state;
                end else begin
                    state_ram_way1[snoop_index] <= snoop_wr_state;
                end
            end
        end
    end

endmodule
