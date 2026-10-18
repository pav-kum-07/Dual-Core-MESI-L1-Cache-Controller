// ============================================================================
// File: bus_arbiter.sv
// Description: Central Shared Bus Arbiter and Snooping Cross-Interconnect
//              between Core 0 L1 Cache, Core 1 L1 Cache, and Main Memory (DRAM).
//
// Key Responsibilities:
// 1. Fair Round-Robin Arbitration:
//    - Arbitrates between simultaneous bus requests from Core 0 and Core 1.
//    - Uses last_gnt_q history to alternate priorities and eliminate starvation.
//
// 2. Bus Tenure Lock (Anti-Hijack Protection):
//    - DRAM memory accesses take multiple clock cycles (simulated multi-cycle latency).
//    - Once a core wins arbitration for a memory transaction, bus_locked_q asserts,
//      preventing the peer core from stealing the bus until the transaction finishes.
//
// 3. MESI Cross-Snoop Broadcast:
//    - When Core 0 is active on the bus, its command and address are broadcast to Core 1's
//      snoop port, and Core 1's snoop hit response is returned to Core 0.
//    - When Core 1 is active on the bus, the reverse cross-connection is made.
//
// 4. Cache-to-Cache Dirty Data Forwarding:
//    - If a core requests a line that the peer holds in MODIFIED (M) dirty state,
//      the arbiter captures the peer's dirty line and supplies it directly to the
//      requesting core (and updates DRAM), avoiding stale memory reads.
// ============================================================================
`include "cache_def.sv"
import cache_def::*;

module bus_arbiter (
    // ------------------------------------------------------------------------
    // Global Clock & Reset
    // ------------------------------------------------------------------------
    input  logic                          clk,                    // [Input]  System clock
    input  logic                          rst_n,                  // [Input]  Active-low asynchronous reset

    // ------------------------------------------------------------------------
    // Interface to Core 0 L1 Cache (Master & Response Ports)
    // ------------------------------------------------------------------------
    input  logic                          core0_bus_req,          // [Input]  Core 0 transaction request valid
    input  bus_cmd_t                      core0_bus_cmd,          // [Input]  Core 0 transaction command (BUS_RD/RDX/UPGR/WB)
    input  logic [ADDR_WIDTH-1:0]         core0_bus_addr,         // [Input]  Core 0 memory access byte address
    input  logic [LINE_WIDTH_BITS-1:0]    core0_bus_wdata,        // [Input]  Core 0 dirty write-back line data (128-bit)
    output logic                          core0_bus_gnt,          // [Output] Bus mastership grant acknowledge to Core 0
    output logic                          core0_snoop_hit,        // [Output] Peer (Core 1) snoop hit indicator to Core 0
    output logic                          core0_mem_resp_valid,   // [Output] Refill / completion response valid to Core 0
    output logic [LINE_WIDTH_BITS-1:0]    core0_mem_resp_data,    // [Output] Refill cache line data (128-bit) to Core 0

    // Core 0 Snoop Port (Receiving cross-snoop queries when Core 1 is master)
    output logic                          core0_snoop_req_valid,  // [Output] Inbound snoop valid to Core 0 (driven when Core 1 wins bus)
    output bus_cmd_t                      core0_snoop_req_cmd,    // [Output] Forwarded peer bus command for Core 0 to snoop
    output logic [ADDR_WIDTH-1:0]         core0_snoop_req_addr,   // [Output] Forwarded peer memory address for Core 0 to lookup
    input  logic                          core0_snoop_resp_hit,   // [Input]  Core 0 tag hit indication to arbiter
    input  logic                          core0_snoop_resp_dirty, // [Input]  Core 0 Modified (dirty) tag indication to arbiter
    input  logic [LINE_WIDTH_BITS-1:0]    core0_snoop_resp_data,  // [Input]  Core 0 forwarded dirty line data (128-bit)

    // ------------------------------------------------------------------------
    // Interface to Core 1 L1 Cache (Master & Response Ports)
    // ------------------------------------------------------------------------
    input  logic                          core1_bus_req,          // [Input]  Core 1 transaction request valid
    input  bus_cmd_t                      core1_bus_cmd,          // [Input]  Core 1 transaction command (BUS_RD/RDX/UPGR/WB)
    input  logic [ADDR_WIDTH-1:0]         core1_bus_addr,         // [Input]  Core 1 memory access byte address
    input  logic [LINE_WIDTH_BITS-1:0]    core1_bus_wdata,        // [Input]  Core 1 dirty write-back line data (128-bit)
    output logic                          core1_bus_gnt,          // [Output] Bus mastership grant acknowledge to Core 1
    output logic                          core1_snoop_hit,        // [Output] Peer (Core 0) snoop hit indicator to Core 1
    output logic                          core1_mem_resp_valid,   // [Output] Refill / completion response valid to Core 1
    output logic [LINE_WIDTH_BITS-1:0]    core1_mem_resp_data,    // [Output] Refill cache line data (128-bit) to Core 1

    // Core 1 Snoop Port (Receiving cross-snoop queries when Core 0 is master)
    output logic                          core1_snoop_req_valid,  // [Output] Inbound snoop valid to Core 1 (driven when Core 0 wins bus)
    output bus_cmd_t                      core1_snoop_req_cmd,    // [Output] Forwarded peer bus command for Core 1 to snoop
    output logic [ADDR_WIDTH-1:0]         core1_snoop_req_addr,   // [Output] Forwarded peer memory address for Core 1 to lookup
    input  logic                          core1_snoop_resp_hit,   // [Input]  Core 1 tag hit indication to arbiter
    input  logic                          core1_snoop_resp_dirty, // [Input]  Core 1 Modified (dirty) tag indication to arbiter
    input  logic [LINE_WIDTH_BITS-1:0]    core1_snoop_resp_data,  // [Input]  Core 1 forwarded dirty line data (128-bit)

    // ------------------------------------------------------------------------
    // Interface to Main Memory / DRAM Controller (Downstream Slave)
    // ------------------------------------------------------------------------
    output logic                          mem_req_valid,          // [Output] Memory transaction request valid to DRAM
    output bus_cmd_t                      mem_req_cmd,            // [Output] Memory transaction command (BUS_RD/RDX/WB) to DRAM
    output logic [ADDR_WIDTH-1:0]         mem_req_addr,           // [Output] Target block address to DRAM
    output logic [LINE_WIDTH_BITS-1:0]    mem_req_wdata,          // [Output] Write-back line data (128-bit) to DRAM
    input  logic                          mem_resp_valid,         // [Input]  DRAM read/write completion valid handshake
    input  logic [LINE_WIDTH_BITS-1:0]    mem_resp_data           // [Input]  DRAM read response cache line data (128-bit)
);

    // ========================================================================
    // Internal Signals & Registers
    // ========================================================================

    // Bus lock control (prevents transaction hijacking during multi-cycle DRAM latency)
    logic bus_locked_q, bus_locked_d;   // 1 = Bus is locked to an active transaction
    logic locked_core_q, locked_core_d; // 0 = Locked to Core 0, 1 = Locked to Core 1
    logic last_gnt_q;                   // Tracks last granted core (0 or 1) for fair round-robin

    // Combinational grant signals
    logic gnt0, gnt1;                   // Decoded grant signals for Core 0 and Core 1

    // Registers to latch peer dirty forwarded line across multi-cycle wait cycles
    logic                       snoop_dirty_q; // Latches peer dirty hit indication
    logic [LINE_WIDTH_BITS-1:0] snoop_data_q;  // Latches peer 128-bit dirty line data

    // ------------------------------------------------------------------------
    // 1. Round-Robin Grant Decision with Bus Lock Protection
    // ------------------------------------------------------------------------
    // Evaluates bus requests combinatorially and enforces tenure locks.
    always_comb begin
        // Default assignments: no grants, retain current lock states
        gnt0          = 1'b0;
        gnt1          = 1'b0;
        bus_locked_d  = bus_locked_q;
        locked_core_d = locked_core_q;

        if (bus_locked_q) begin
            // ----------------------------------------------------------------
            // Case A: Bus is LOCKED to an ongoing multi-cycle transaction
            // ----------------------------------------------------------------
            // Retain grant for the locked core until memory finishes (mem_resp_valid)
            // or the core prematurely drops its request.
            if (locked_core_q == 1'b0) begin
                gnt0 = 1'b1;
                if (mem_resp_valid || !core0_bus_req) begin
                    bus_locked_d = 1'b0; // Release lock on completion
                end
            end else begin
                gnt1 = 1'b1;
                if (mem_resp_valid || !core1_bus_req) begin
                    bus_locked_d = 1'b0; // Release lock on completion
                end
            end
        end else begin
            // ----------------------------------------------------------------
            // Case B: Bus is FREE — Evaluate new requests using Round-Robin
            // ----------------------------------------------------------------
            if (core0_bus_req && core1_bus_req) begin
                // Both cores requesting simultaneously: tie-break using last_gnt_q
                if (last_gnt_q == 1'b0) begin
                    gnt1 = 1'b1; // Core 0 had it last, so Core 1 gets priority
                end else begin
                    gnt0 = 1'b1; // Core 1 had it last, so Core 0 gets priority
                end
            end else if (core0_bus_req) begin
                gnt0 = 1'b1;     // Sole request from Core 0
            end else if (core1_bus_req) begin
                gnt1 = 1'b1;     // Sole request from Core 1
            end

            // ----------------------------------------------------------------
            // Lock Initiation: Check if the newly granted transaction needs DRAM
            // ----------------------------------------------------------------
            // If the transaction is a memory access (not BUS_UPGR) and DRAM does
            // not respond in the immediate cycle, lock the bus.
            if (gnt0 && (core0_bus_cmd != BUS_UPGR) && !mem_resp_valid) begin
                bus_locked_d  = 1'b1;
                locked_core_d = 1'b0; // Lock tenure to Core 0
            end else if (gnt1 && (core1_bus_cmd != BUS_UPGR) && !mem_resp_valid) begin
                bus_locked_d  = 1'b1;
                locked_core_d = 1'b1; // Lock tenure to Core 1
            end
        end
    end

    // Drive grant outputs directly to cache controllers
    assign core0_bus_gnt = gnt0;
    assign core1_bus_gnt = gnt1;

    // ------------------------------------------------------------------------
    // Sequential State Update & Dirty Snoop Latch
    // ------------------------------------------------------------------------
    // Updates registered lock states, round-robin history, and snoop data buffers.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_locked_q  <= 1'b0;
            locked_core_q <= 1'b0;
            last_gnt_q    <= 1'b0;
            snoop_dirty_q <= 1'b0;
            snoop_data_q  <= '0;
        end else begin
            bus_locked_q  <= bus_locked_d;
            locked_core_q <= locked_core_d;

            // Update round-robin pointer only at the end of a granted transaction
            if (gnt0 && !bus_locked_d) begin
                last_gnt_q <= 1'b0;
            end else if (gnt1 && !bus_locked_d) begin
                last_gnt_q <= 1'b1;
            end

            // Latch dirty cache line from peer core on cycle 1 of transaction
            if (!bus_locked_q) begin
                if (gnt0 && core1_snoop_resp_dirty) begin
                    snoop_dirty_q <= 1'b1;
                    snoop_data_q  <= core1_snoop_resp_data;
                end else if (gnt1 && core0_snoop_resp_dirty) begin
                    snoop_dirty_q <= 1'b1;
                    snoop_data_q  <= core0_snoop_resp_data;
                end else begin
                    snoop_dirty_q <= 1'b0;
                end
            end else if (mem_resp_valid || (!core0_bus_req && !core1_bus_req)) begin
                snoop_dirty_q <= 1'b0; // Clear dirty latch once transaction completes
            end
        end
    end

    // ------------------------------------------------------------------------
    // 2. Cross-Snoop Broadcast Network
    // ------------------------------------------------------------------------
    // Direct cross-wiring between masters and peer snoop ports:
    // - When Core 0 is granted (gnt0 = 1), Core 1 snoops Core 0's request.
    // - When Core 1 is granted (gnt1 = 1), Core 0 snoops Core 1's request.
    assign core1_snoop_req_valid = gnt0;
    assign core1_snoop_req_cmd   = core0_bus_cmd;
    assign core1_snoop_req_addr  = core0_bus_addr;
    assign core0_snoop_hit       = core1_snoop_resp_hit;   // Tells Core 0 if Core 1 has a copy

    assign core0_snoop_req_valid = gnt1;
    assign core0_snoop_req_cmd   = core1_bus_cmd;
    assign core0_snoop_req_addr  = core1_bus_addr;
    assign core1_snoop_hit       = core0_snoop_resp_hit;   // Tells Core 1 if Core 0 has a copy

    // ------------------------------------------------------------------------
    // 3. Main Memory (DRAM) Request Multiplexing
    // ------------------------------------------------------------------------
    // Routes the granted core's memory request downstream to DRAM.
    // Suppresses memory requests for BUS_UPGR (pure cache-to-cache invalidation).
    // If peer holds dirty data, forwards peer dirty line to DRAM to keep memory in sync.
    always_comb begin
        mem_req_valid = 1'b0;
        mem_req_cmd   = BUS_IDLE;
        mem_req_addr  = '0;
        mem_req_wdata = '0;

        if (gnt0) begin
            mem_req_valid = (core0_bus_cmd != BUS_UPGR); // BUS_UPGR does not touch DRAM
            mem_req_cmd   = core0_bus_cmd;
            mem_req_addr  = core0_bus_addr;
            // If peer Core 1 is dirty, write-back Core 1's line; otherwise write Core 0's data
            mem_req_wdata = core1_snoop_resp_dirty ? core1_snoop_resp_data : core0_bus_wdata;
        end else if (gnt1) begin
            mem_req_valid = (core1_bus_cmd != BUS_UPGR); // BUS_UPGR does not touch DRAM
            mem_req_cmd   = core1_bus_cmd;
            mem_req_addr  = core1_bus_addr;
            // If peer Core 0 is dirty, write-back Core 0's line; otherwise write Core 1's data
            mem_req_wdata = core0_snoop_resp_dirty ? core0_snoop_resp_data : core1_bus_wdata;
        end
    end

    // ------------------------------------------------------------------------
    // 4. Memory Response Routing (With Cache-to-Cache Dirty Forwarding)
    // ------------------------------------------------------------------------
    // Resolves response line data for the granted core:
    // Priority: If peer core has dirty data, supply peer's line (cache-to-cache transfer).
    // Otherwise, supply line data fetched from Main Memory (mem_resp_data).
    logic [LINE_WIDTH_BITS-1:0] final_resp_data_for_c0;
    logic [LINE_WIDTH_BITS-1:0] final_resp_data_for_c1;

    assign final_resp_data_for_c0 = (core1_snoop_resp_dirty | snoop_dirty_q) ? 
                                    (snoop_dirty_q ? snoop_data_q : core1_snoop_resp_data) : mem_resp_data;
    assign final_resp_data_for_c1 = (core0_snoop_resp_dirty | snoop_dirty_q) ? 
                                    (snoop_dirty_q ? snoop_data_q : core0_snoop_resp_data) : mem_resp_data;

    // Response valid pulse:
    // - Memory transactions complete when DRAM asserts mem_resp_valid.
    // - BUS_UPGR completes immediately (1 cycle) since peer invalidation is combinational.
    assign core0_mem_resp_valid = gnt0 ? (mem_resp_valid || core0_bus_cmd == BUS_UPGR) : 1'b0;
    assign core0_mem_resp_data  = final_resp_data_for_c0;

    assign core1_mem_resp_valid = gnt1 ? (mem_resp_valid || core1_bus_cmd == BUS_UPGR) : 1'b0;
    assign core1_mem_resp_data  = final_resp_data_for_c1;

endmodule
