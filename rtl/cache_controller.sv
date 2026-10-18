// ============================================================================
// File: cache_controller.sv
// Description: Top-level L1 2-Way Set-Associative Cache Controller with MESI
//              coherence protocol, True LRU replacement, write-back/allocate,
//              and non-blocking snooping logic.
//
// Internal Architecture (4 Key Sub-Units):
// 1. MAIN CONTROL UNIT (Main FSM):
//    - Serves local CPU requests, handles hits/misses, and orchestrates line refills.
//    - SOLE ISSUER of bus commands (bus_req_cmd):
//        * BUS_RD   : Issued during FSM_ALLOCATE on CPU Read Miss.
//        * BUS_RDX  : Issued during FSM_ALLOCATE on CPU Write Miss.
//        * BUS_WB   : Issued during FSM_WRITE_BACK to evict a dirty (MODIFIED) line.
//        * BUS_UPGR : Issued during FSM_UPGRADE on a CPU Write Hit to a SHARED line.
//        * BUS_IDLE : Default resting bus state during FSM_IDLE.
//
// 2. SNOOP CONTROL UNIT (Concurrent Snooper):
//    - Background coherence engine listening to peer requests on Port B.
//    - Enforces MESI rules (downgrading to S or invalidating to I).
//    - Supplies dirty lines directly to peer via snoop_resp_data when in MODIFIED state.
//
// 3. DATAPATH UNIT:
//    - Address bit slicer (Tag[31:8], Index[7:4], Word[3:2], Byte[1:0]).
//    - Request latches (req_addr_q, req_wdata_q) for multi-cycle memory transactions.
//    - Read MUX Tree (2:1 128-bit Way Select MUX + 4:1 32-bit Word Select MUX).
//    - Write-Merge Formatter (merges CPU store word into 128-bit line via byte enables).
//
// 4. CACHE STORAGE UNIT (3 Dedicated SRAM Modules):
//    - cache_tag_array  : Dual-port Tag & MESI state RAM (16 sets x 2 ways x 26 bits).
//    - cache_data_array : Dual-port Data RAM (16 sets x 2 ways x 128 bits = 512 Bytes).
//    - lru_array        : 1-bit True LRU replacement RAM (16 sets x 1 bit).
// ============================================================================

`include "cache_def.sv"
import cache_def::*;

module cache_controller #(
    parameter int CORE_ID = 0
)(
    input  logic                          clk,
    input  logic                          rst_n,

    // ------------------------------------------------------------------------
    // 1. CPU / Master Core Interface
    // ------------------------------------------------------------------------
    input  logic                          cpu_req_valid,
    input  logic                          cpu_req_rw,       // 0 = READ, 1 = WRITE
    input  logic [ADDR_WIDTH-1:0]         cpu_req_addr,
    input  logic [DATA_WIDTH-1:0]         cpu_req_wdata,
    input  logic [3:0]                    cpu_byte_en,
    output logic                          cpu_ready,        // 1 = Cache ready / hit done
    output logic [DATA_WIDTH-1:0]         cpu_resp_rdata,   // Read data returned to CPU
    output logic                          cpu_resp_valid,   // Pulse on completed read

    // ------------------------------------------------------------------------
    // 2. Memory / Interconnect Master Port (Requests initiated by this Cache)
    // ------------------------------------------------------------------------
    output logic                          bus_req_valid,
    output bus_cmd_t                      bus_req_cmd,      // Bus transaction type: BUS_RD, BUS_RDX, BUS_UPGR, BUS_WB, or BUS_IDLE
    output logic [ADDR_WIDTH-1:0]         bus_req_addr,
    output logic [LINE_WIDTH_BITS-1:0]    bus_req_wdata,    // Used for dirty write-backs
    input  logic                          bus_req_gnt,      // Arbiter granted the bus
    input  logic                          mem_resp_valid,   // DRAM finished read/write
    input  logic [LINE_WIDTH_BITS-1:0]    mem_resp_data,    // 16 bytes from DRAM
    input  logic                          bus_snoop_hit,    // Peer core indicated it has a copy

    // ------------------------------------------------------------------------
    // 3. Snoop Slave Port (MESI Cross-Snoop Interface via Bus Arbiter)
    //    These signals connect directly to the central Bus Arbiter. When the peer
    //    core wins bus arbitration, the arbiter forwards that peer's request here
    //    so this cache can snoop the bus, look up local tags, update MESI states,
    //    and forward dirty data if needed.
    // ------------------------------------------------------------------------
    input  logic                          snoop_req_valid,  // Arbiter indicates peer core is active on the bus
    input  bus_cmd_t                      snoop_req_cmd,    // Peer transaction type: BUS_RD, BUS_RDX, or BUS_UPGR
    input  logic [ADDR_WIDTH-1:0]         snoop_req_addr,   // Memory address being accessed by peer core
    output logic                          snoop_resp_hit,   // Asserts to arbiter if address hits in our tag array
    output logic                          snoop_resp_dirty, // Asserts to arbiter if our hitting line is in MODIFIED state
    output logic [LINE_WIDTH_BITS-1:0]    snoop_resp_data   // Supplies 128-bit dirty line for cache-to-cache forwarding
);

    // ------------------------------------------------------------------------
    // Internal Signals & Registers
    // ------------------------------------------------------------------------

    // --- 1. Controller FSM State Registers ---
    // state_q: Current active state of the cache controller FSM (registers on posedge clk)
    // state_d: Combinational next-state evaluated by the FSM logic
    cache_fsm_state_t state_q, state_d;

    // --- 2. Latched CPU Request Registers ---
    // A cache hit completes in 1 cycle, but a miss/upgrade requires multiple bus cycles.
    // When a miss occurs, these registers freeze the CPU request so it is preserved
    // throughout multi-cycle memory refilling and write-back transactions.
    logic                     req_rw_q;      // Latched read/write command (0 = Read, 1 = Write)
    logic [ADDR_WIDTH-1:0]    req_addr_q;    // Latched 32-bit CPU request address
    logic [DATA_WIDTH-1:0]    req_wdata_q;   // Latched 32-bit CPU write data
    logic [3:0]               req_byte_en_q; // Latched 4-bit byte write enables

    // --- 3. Active Request Address Fields ---
    // Extracted bit slices (Tag [31:8], Index [7:4], Word Offset [3:2])
    logic [TAG_WIDTH-1:0]         active_tag;
    logic [SET_INDEX_WIDTH-1:0]   active_index;
    logic [WORD_OFFSET_WIDTH-1:0] active_word_offset;

    // Fast-path multiplexing: Use raw combinational address during FSM_IDLE
    // for 1-cycle zero-wait-state hits; switch to latched registers during misses.
    assign active_tag         = (state_q == FSM_IDLE) ? get_tag(cpu_req_addr)         : get_tag(req_addr_q);
    assign active_index       = (state_q == FSM_IDLE) ? get_index(cpu_req_addr)       : get_index(req_addr_q);
    assign active_word_offset = (state_q == FSM_IDLE) ? get_word_offset(cpu_req_addr)  : get_word_offset(req_addr_q);

    // --- 4. Tag Array Interconnects ---
    // Signals interfacing with cache_tag_array for local CPU lookups and updates
    logic                hit_way0, hit_way1;          // Comparators: high if requested tag matches and is valid
    mesi_state_t         state_way0, state_way1;      // Current MESI state (M, E, S, I) for each way in set
    logic [TAG_WIDTH-1:0] tag_way0_out, tag_way1_out; // 24-bit stored tag read from Way 0 and Way 1
    logic                wr_en_tag_way0, wr_en_tag_way1; // Write enable to update tag & MESI state on refill/upgrade
    logic [TAG_WIDTH-1:0] wr_tag_d;                    // Tag value to write into tag RAM
    mesi_state_t         wr_state_d;                  // New MESI state to write into tag RAM

    // --- 5. Snoop Tag Interconnects (Cross-Snoop Port) ---
    // Signals interfacing with Port B of cache_tag_array to snoop peer bus accesses
    logic [SET_INDEX_WIDTH-1:0] snoop_index;        // Set index extracted from peer snoop address [7:4]
    logic [TAG_WIDTH-1:0]       snoop_tag;          // Tag extracted from peer snoop address [31:8]
    logic                       snoop_tag_hit;      // High if peer address hits in either way of this cache
    logic                       snoop_tag_hit_way;  // Which way matched the peer address (0 = Way 0, 1 = Way 1)
    mesi_state_t                snoop_tag_state;    // MESI state of the line that matched the snoop request
    logic                       snoop_wr_en;        // Write enable to update state in response to snoop (e.g. invalidate)
    logic                       snoop_wr_way;       // Target way for snoop state update
    mesi_state_t                snoop_wr_state;     // Target MESI state (e.g. SHARED on peer read, INVALID on peer write)

    // Extract Set Index [7:4] and Tag [31:8] from the peer core's snoop address.
    // (Line/byte offsets [3:0] are not needed because MESI coherence tracks entire 16B lines).
    assign snoop_index = get_index(snoop_req_addr); // 4-bit set address for Port B read
    assign snoop_tag   = get_tag(snoop_req_addr);   // 24-bit tag to test for peer hit on Port B

    // --- 6. Data Array Interconnects ---
    // Signals interfacing with cache_data_array for data line read, word write, and refill
    logic [LINE_WIDTH_BITS-1:0] line_way0_out, line_way1_out; // 128-bit cache lines read from Way 0 and Way 1
    logic                       fill_en_way0, fill_en_way1;   // Enables writing full 128-bit line during memory refill
    logic [LINE_WIDTH_BITS-1:0] fill_data_d;                  // 128-bit refill data from DRAM or peer cache
    logic                       word_wr_en_way0, word_wr_en_way1; // Enables 32-bit CPU word write on write hit

    // --- 7. LRU Replacement Interconnects ---
    // Signals interfacing with cache_lru_array (1 bit per set tracking least-recently accessed way)
    logic lru_victim;        // Indicates which way (0 or 1) is selected for eviction on a miss
    logic lru_update_en;     // Strobe to update the LRU status bit
    logic lru_accessed_way;  // The way that was just accessed (to mark it most recently used)

    // --- 8. Hit & Victim Evaluation / Write-Back Buffer ---
    logic cache_hit;         // Combinational hit flag: asserted when either Way 0 or Way 1 hits
    logic hit_way;           // Hit way index: 0 = Way 0 hit, 1 = Way 1 hit

    // Victim Eviction Registers: When a miss selects a MODIFIED (dirty) line for replacement,
    // these registers latch the victim's way, tag, and 128-bit dirty data so it can be safely
    // transmitted back to DRAM via BUS_WB before allocating the new incoming line.
    logic victim_way_q,   victim_way_d;             // Victim way index (0 or 1)
    logic victim_dirty_q, victim_dirty_d;           // High if victim line is dirty (MODIFIED state)
    logic [TAG_WIDTH-1:0]       victim_tag_q, victim_tag_d;   // Victim tag (used to reconstruct DRAM address)
    logic [LINE_WIDTH_BITS-1:0] victim_data_q, victim_data_d; // 128-bit victim data to write back to memory

    assign cache_hit = hit_way0 | hit_way1;
    assign hit_way   = hit_way1; // 1 if Way 1 hit, 0 if Way 0 hit

    // --- 9. Hit Data Multiplexing (Two-Stage Selection Hierarchy) ---
    // In a 2-Way Set-Associative cache, a cache line is 128 bits (4 words), but the CPU
    // only requests one 32-bit word. Data selection happens in two sequential stages:
    //
    // Stage 1 (Way Multiplexer - 2:1 Line Mux):
    //   Both Way 0 and Way 1 output their 128-bit lines in parallel.
    //   hit_line_data selects the 128-bit line from whichever way matched (hit_way1 ? Way 1 : Way 0).
    logic [LINE_WIDTH_BITS-1:0] hit_line_data;

    // Stage 2 (Word Multiplexer - 4:1 Word Mux):
    //   Extracts the specific 32-bit CPU word from the 128-bit line based on active_word_offset (addr[3:2]).
    //   This word is returned to the CPU as cpu_resp_rdata during a 1-cycle read hit.
    logic [DATA_WIDTH-1:0]      hit_word_data;

    // 2-to-1 Way Selection Mux:
    assign hit_line_data = hit_way1 ? line_way1_out : line_way0_out;

    // 4-to-1 Word Slicing Mux (READ HIT PATH):
    // Slices the requested 32-bit CPU word from the local cache SRAM line (hit_line_data).
    // Driven to cpu_resp_rdata in FSM_IDLE to deliver a 1-cycle zero-wait-state read hit.
    always_comb begin
        case (active_word_offset)
            2'b00: hit_word_data = hit_line_data[31:0];   // Word 0 (Bytes 0-3)
            2'b01: hit_word_data = hit_line_data[63:32];  // Word 1 (Bytes 4-7)
            2'b10: hit_word_data = hit_line_data[95:64];  // Word 2 (Bytes 8-11)
            2'b11: hit_word_data = hit_line_data[127:96]; // Word 3 (Bytes 12-15)
        endcase
    end

    // 4-to-1 Word Slicing Mux (READ MISS PATH - Critical-Word Bypass):
    // Slices the requested 32-bit CPU word directly from the incoming 128-bit DRAM response
    // (mem_resp_data). Driven to cpu_resp_rdata in FSM_ALLOCATE so the CPU gets its requested
    // data immediately upon refill completion without needing an extra cache-read cycle.
    logic [DATA_WIDTH-1:0] mem_resp_word;
    always_comb begin
        case (active_word_offset)
            2'b00: mem_resp_word = mem_resp_data[31:0];   // Word 0 (Bytes 0-3)
            2'b01: mem_resp_word = mem_resp_data[63:32];  // Word 1 (Bytes 4-7)
            2'b10: mem_resp_word = mem_resp_data[95:64];  // Word 2 (Bytes 8-11)
            2'b11: mem_resp_word = mem_resp_data[127:96]; // Word 3 (Bytes 12-15)
        endcase
    end

    // ------------------------------------------------------------------------
    // Submodule Instantiations
    // ------------------------------------------------------------------------
    cache_tag_array tag_array_inst (
        .clk              (clk),
        .rst_n            (rst_n),
        .cpu_index        (active_index),
        .cpu_tag          (active_tag),
        .hit_way0         (hit_way0),
        .hit_way1         (hit_way1),
        .state_way0       (state_way0),
        .state_way1       (state_way1),
        .tag_way0_out     (tag_way0_out),
        .tag_way1_out     (tag_way1_out),
        .wr_en_way0       (wr_en_tag_way0),
        .wr_en_way1       (wr_en_tag_way1),
        .wr_tag           (wr_tag_d),
        .wr_state         (wr_state_d),
        .snoop_index      (snoop_index),
        .snoop_tag        (snoop_tag),
        .snoop_hit        (snoop_tag_hit),
        .snoop_hit_way    (snoop_tag_hit_way),
        .snoop_state      (snoop_tag_state),
        .snoop_wr_en      (snoop_wr_en),
        .snoop_wr_way     (snoop_wr_way),
        .snoop_wr_state   (snoop_wr_state)
    );

    cache_data_array data_array_inst (
        .clk              (clk),
        .cpu_index        (active_index),
        .cpu_word_offset  (active_word_offset),
        .line_way0_out    (line_way0_out),
        .line_way1_out    (line_way1_out),
        .fill_en_way0     (fill_en_way0),
        .fill_en_way1     (fill_en_way1),
        .fill_data        (fill_data_d),
        .word_wr_en_way0  (word_wr_en_way0),
        .word_wr_en_way1  (word_wr_en_way1),
        .word_wr_data     ((state_q == FSM_IDLE) ? cpu_req_wdata : req_wdata_q),
        .byte_en          ((state_q == FSM_IDLE) ? cpu_byte_en   : req_byte_en_q),
        .snoop_index      (snoop_index),
        .snoop_way        (snoop_tag_hit_way),
        .snoop_data_out   (snoop_resp_data)
    );

    lru_array lru_array_inst (
        .clk              (clk),
        .rst_n            (rst_n),
        .set_index        (active_index),
        .lru_victim       (lru_victim),
        .update_en        (lru_update_en),
        .accessed_way     (lru_accessed_way)
    );

    // ------------------------------------------------------------------------
    // 4. Concurrent Snooping Logic (MESI Bus Snooper)
    // ------------------------------------------------------------------------
    // Operates independently of the main CPU FSM using Port B of cache_tag_array.
    // Listens to peer core transactions forwarded by the Bus Arbiter, checks for
    // tag matches, alerts the arbiter if a copy or dirty data exists, and updates
    // local MESI states to maintain multi-core cache coherency.
    // ------------------------------------------------------------------------
    always_comb begin
        // Combinational Default Assignments (Prevents unintended hardware latches):
        // Write-enable is OFF by default; INVALID is the baseline safe state.
        snoop_resp_hit   = 1'b0;              // Default: peer address is not present in our cache
        snoop_resp_dirty = 1'b0;              // Default: our line is not dirty
        snoop_wr_en      = 1'b0;              // Default: do not write/update tag array Port B
        snoop_wr_way     = snoop_tag_hit_way; // Point to whichever way matched the peer address
        snoop_wr_state   = INVALID;           // Default target state

        // Evaluates when:
        // 1. snoop_req_valid: Bus Arbiter indicates the peer core has an active bus transaction.
        // 2. snoop_tag_hit  : Port B tag comparators confirm the address matches a valid line in our cache.
        if (snoop_req_valid && snoop_tag_hit) begin
            // Notify Bus Arbiter that we hold a copy (peer installs line as SHARED instead of EXCLUSIVE)
            snoop_resp_hit = 1'b1;

            // If we hold the line in MODIFIED state, our data is newer than DRAM!
            // Asserting snoop_resp_dirty tells the arbiter to forward our data to peer and memory.
            if (snoop_tag_state == MODIFIED) begin
                snoop_resp_dirty = 1'b1; // We hold the latest dirty line!
            end

            // Determine local MESI state transitions based on peer's bus command:
            case (snoop_req_cmd)
                BUS_RD: begin
                    // Peer is reading: both cores now share this line.
                    // If our copy was MODIFIED (M) or EXCLUSIVE (E), downgrade it to SHARED (S).
                    snoop_wr_en    = 1'b1;
                    snoop_wr_state = SHARED;
                end

                BUS_RDX, BUS_UPGR: begin
                    // Peer is writing (intent to modify or upgrading from S -> M).
                    // We must invalidate our local copy (-> INVALID) to prevent reading stale data.
                    snoop_wr_en    = 1'b1;
                    snoop_wr_state = INVALID;
                end

                default: begin
                    snoop_wr_en = 1'b0; // No state change for other bus commands (e.g. BUS_IDLE, BUS_WB)
                end
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // 5. Main Cache Controller FSM Logic
    // ------------------------------------------------------------------------
    // ------------------------------------------------------------------------
    // 5. Main Cache Controller FSM Logic (Combinational Next-State & Outputs)
    // ------------------------------------------------------------------------
    always_comb begin
        // ====================================================================
        // A. Default Register Retentions
        // Prevents inferring unintentional latches by holding registered values
        // across cycles unless explicitly overridden by FSM state transitions.
        // ====================================================================
        state_d         = state_q;          // Retain current FSM state
        victim_way_d    = victim_way_q;     // Retain chosen victim way (Way 0 or 1)
        victim_dirty_d  = victim_dirty_q;   // Retain dirty status of victim line
        victim_tag_d    = victim_tag_q;     // Retain victim tag for write-back address
        victim_data_d   = victim_data_q;    // Retain victim 16-byte line for write-back

        // ====================================================================
        // B. Default Interface & Control Outputs
        // Set all enables and handshakes to inactive (safe default values).
        // ====================================================================
        // CPU Interface
        cpu_ready       = 1'b0;             // CPU handshake deasserted by default
        cpu_resp_rdata  = hit_word_data;    // Speculatively route read-hit data word
        cpu_resp_valid  = 1'b0;             // Response data valid flag

        // Bus/Interconnect Interface
        bus_req_valid   = 1'b0;             // No bus request issued by default
        bus_req_cmd     = BUS_IDLE;         // Bus command idle
        bus_req_addr    = '0;               // Bus address cleared
        bus_req_wdata   = victim_data_q;    // Default bus write data set to victim buffer

        // Tag Array Control
        wr_en_tag_way0  = 1'b0;             // Tag write disable Way 0
        wr_en_tag_way1  = 1'b0;             // Tag write disable Way 1
        wr_tag_d        = active_tag;       // Default write tag is CPU requested tag
        wr_state_d      = INVALID;          // Default target MESI state

        // Line Fill (Data Array) Control
        fill_en_way0    = 1'b0;             // Line fill disable Way 0
        fill_en_way1    = 1'b0;             // Line fill disable Way 1
        fill_data_d     = mem_resp_data;    // Default fill payload from memory/peer

        // Word-level Write (Data Array) Control for CPU Store hits
        word_wr_en_way0 = 1'b0;             // Word write disable Way 0
        word_wr_en_way1 = 1'b0;             // Word write disable Way 1

        // LRU Policy Tracking Control
        lru_update_en   = 1'b0;             // Keep LRU bit unchanged
        lru_accessed_way= 1'b0;             // Accessed way indicator

        case (state_q)
            // ----------------------------------------------------------------
            // FSM_IDLE: Awaiting CPU Request
            // In IDLE, the controller samples incoming CPU read/write requests.
            // Tag comparison occurs combinationally in parallel with data array
            // read, enabling single-cycle (zero penalty) hits.
            // ----------------------------------------------------------------
            FSM_IDLE: begin
                if (cpu_req_valid) begin
                    // Check Hit condition combinationally for 1-cycle hit
                    if (cache_hit) begin
                        if (!cpu_req_rw) begin
                            // ================================================
                            // FAST READ HIT (Single Cycle!)
                            // - Data word is read and returned immediately.
                            // - Acknowledge CPU with cpu_ready & cpu_resp_valid.
                            // - Mark hit way as Most-Recently-Used (MRU).
                            // - Remain in FSM_IDLE for back-to-back hits.
                            // ================================================
                            cpu_ready        = 1'b1;
                            cpu_resp_valid   = 1'b1;
                            cpu_resp_rdata   = hit_word_data;
                            lru_update_en    = 1'b1;
                            lru_accessed_way = hit_way;
                            state_d          = FSM_IDLE;
                        end else begin
                            // ================================================
                            // WRITE HIT
                            // Check the MESI state of the hitting cache line:
                            // ================================================
                            mesi_state_t hit_state;
                            hit_state = hit_way1 ? state_way1 : state_way0;

                            if (hit_state == MODIFIED || hit_state == EXCLUSIVE) begin
                                // --------------------------------------------
                                // SILENT WRITE (Local hit, no bus broadcast):
                                // - M: We already have exclusive dirty ownership.
                                // - E: We have clean exclusive ownership; no peer
                                //      has this line, so we can promote E -> M
                                //      locally without broadcasting to the bus!
                                // - Perform 32-bit word store into data array.
                                // - Upgrade tag state to MODIFIED.
                                // - Update LRU and acknowledge CPU in 1 cycle.
                                // --------------------------------------------
                                cpu_ready        = 1'b1;
                                lru_update_en    = 1'b1;
                                lru_accessed_way = hit_way;
                                
                                // Enable write to the targeted word in the hit way
                                if (hit_way == 1'b0) word_wr_en_way0 = 1'b1;
                                else                 word_wr_en_way1 = 1'b1;

                                // Update MESI state in tag array to MODIFIED (dirty)
                                wr_tag_d   = active_tag;
                                wr_state_d = MODIFIED;
                                if (hit_way == 1'b0) wr_en_tag_way0 = 1'b1;
                                else                 wr_en_tag_way1 = 1'b1;

                                state_d = FSM_IDLE;
                            end else begin
                                // --------------------------------------------
                                // SHARED WRITE (Upgrade Required):
                                // Line is in SHARED (S) state. Other peer caches
                                // may hold valid copies. Writing now would cause
                                // cache incoherence.
                                // Action: Latch hit way and jump to FSM_UPGRADE
                                // to broadcast BUS_UPGR and invalidate peer copies.
                                // --------------------------------------------
                                victim_way_d = hit_way;
                                state_d      = FSM_UPGRADE;
                            end
                        end
                    end else begin
                        // ====================================================
                        // CACHE MISS
                        // The requested tag is not present or valid in any way.
                        // Step 1: Select victim way for replacement.
                        // Priority: Prefer an INVALID (empty) way first.
                        // If both ways are valid, use the LRU bit to evict.
                        // ====================================================
                        if (state_way0 == INVALID) begin
                            victim_way_d = 1'b0;         // Way 0 is empty, allocate here
                        end else if (state_way1 == INVALID) begin
                            victim_way_d = 1'b1;         // Way 1 is empty, allocate here
                        end else begin
                            victim_way_d = lru_victim;   // Both valid: evict LRU candidate
                        end

                        // Step 2: Latch victim line info (dirty flag, tag, and 16-byte data).
                        // Needed if we must perform write-back to memory.
                        if (victim_way_d == 1'b0) begin
                            victim_dirty_d = (state_way0 == MODIFIED);
                            victim_tag_d   = tag_way0_out;
                            victim_data_d  = line_way0_out;
                        end else begin
                            victim_dirty_d = (state_way1 == MODIFIED);
                            victim_tag_d   = tag_way1_out;
                            victim_data_d  = line_way1_out;
                        end

                        // ----------------------------------------------------
                        // Step 3: Determine Next State:
                        // - If victim is DIRTY (MODIFIED):
                        //     Must write-back the 16-byte victim line to DRAM
                        //     via FSM_WRITE_BACK before fetching the new line.
                        // - If victim is CLEAN (INVALID / SHARED / EXCLUSIVE):
                        //     No write-back needed; advance directly to
                        //     FSM_ALLOCATE to request the new line over bus.
                        // ----------------------------------------------------
                        if (victim_dirty_d) begin
                            state_d = FSM_WRITE_BACK;
                        end else begin
                            state_d = FSM_ALLOCATE;
                        end
                    end
                end
            end

            // ----------------------------------------------------------------
            // FSM_WRITE_BACK: Evict dirty 16-byte block to Main Memory
            // Operates: When victim line is in MODIFIED state (dirty).
            // Action:   Issues BUS_WB to write 16 bytes back to DRAM before
            //           fetching the new requested line in FSM_ALLOCATE.
            // ----------------------------------------------------------------
            FSM_WRITE_BACK: begin
                bus_req_valid = 1'b1;
                bus_req_cmd   = BUS_WB;
                bus_req_addr  = {victim_tag_q, active_index, 4'b0000};
                bus_req_wdata = victim_data_q;

                if (bus_req_gnt && mem_resp_valid) begin
                    state_d = FSM_ALLOCATE;
                end
            end

            // ----------------------------------------------------------------
            // FSM_ALLOCATE: Refill missing 16-byte block from Main Memory
            // Operates: On CPU Miss (either directly if clean, or after BUS_WB).
            // Action:   Drives BUS_RD (on read miss) or BUS_RDX (on write miss).
            //           Receives 16-byte line from DRAM, writes into data SRAM,
            //           updates tag/MESI, extracts CPU word, and asserts cpu_ready.
            // ----------------------------------------------------------------
            FSM_ALLOCATE: begin
                bus_req_valid = 1'b1;
                bus_req_addr  = {active_tag, active_index, 4'b0000};
                bus_req_cmd   = req_rw_q ? BUS_RDX : BUS_RD;

                if (bus_req_gnt && mem_resp_valid) begin
                    wr_tag_d = active_tag;
                    if (req_rw_q) begin
                        // Write Miss Allocation: Merge CPU write word into the refill line
                        fill_data_d = apply_word_write(mem_resp_data, active_word_offset, req_wdata_q, req_byte_en_q);
                        wr_state_d  = MODIFIED;
                    end else begin
                        // Read Miss Allocation: Deliver new word directly to CPU
                        fill_data_d    = mem_resp_data;
                        wr_state_d     = bus_snoop_hit ? SHARED : EXCLUSIVE;
                        cpu_resp_rdata = mem_resp_word;
                        cpu_resp_valid = 1'b1;
                    end

                    if (victim_way_q == 1'b0) fill_en_way0 = 1'b1;
                    else                     fill_en_way1 = 1'b1;

                    if (victim_way_q == 1'b0) wr_en_tag_way0 = 1'b1;
                    else                     wr_en_tag_way1 = 1'b1;

                    lru_update_en    = 1'b1;
                    lru_accessed_way = victim_way_q;

                    cpu_ready = 1'b1;
                    state_d   = FSM_IDLE;
                end
            end

            // ----------------------------------------------------------------
            // FSM_UPGRADE: Invalidate Peer Copies on Write Hit to SHARED (S)
            // 
            // Occurs when: A CPU store request hits a cache line in SHARED state.
            // Why needed:  Other peer cores may hold valid copies of this line.
            //              To maintain cache coherence, we cannot write locally
            //              until all peer copies are invalidated.
            // Action:      Broadcast BUS_UPGR on the shared interconnect. DRAM is
            //              NOT accessed because our cache already has valid data;
            //              peer snoop controllers observe the address and transition
            //              their copies to INVALID.
            // ----------------------------------------------------------------
            FSM_UPGRADE: begin
                // Request the shared bus to broadcast an upgrade/invalidation
                bus_req_valid = 1'b1;
                bus_req_cmd   = BUS_UPGR;
                bus_req_addr  = {active_tag, active_index, 4'b0000}; // Align to 16-byte boundary

                // Wait until the arbiter grants the bus (bus transaction completes)
                if (bus_req_gnt) begin
                    // 1. Upgrade the MESI state to MODIFIED (dirty exclusive)
                    wr_tag_d   = active_tag;
                    wr_state_d = MODIFIED;
                    
                    // 2. Perform the word-level write into the data array
                    if (victim_way_q == 1'b0) begin
                        wr_en_tag_way0  = 1'b1;
                        word_wr_en_way0 = 1'b1;
                    end else begin
                        wr_en_tag_way1  = 1'b1;
                        word_wr_en_way1 = 1'b1;
                    end

                    // 3. Update LRU tracking to mark this way as Most Recently Used
                    lru_update_en    = 1'b1;
                    lru_accessed_way = victim_way_q;

                    // 4. Acknowledge CPU write completion and return to IDLE
                    cpu_ready = 1'b1;
                    state_d   = FSM_IDLE;
                end
            end

            // Safe fallback: reset to IDLE on any undefined state
            default: state_d = FSM_IDLE;
        endcase
    end

    // ------------------------------------------------------------------------
    // Sequential State Registers & CPU Request Latching
    // Clocked on posedge clk with asynchronous active-low reset (rst_n)
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // ----------------------------------------------------------------
            // Asynchronous Reset: Clear all internal FSM and latch registers
            // ----------------------------------------------------------------
            state_q        <= FSM_IDLE;
            req_rw_q       <= 1'b0;
            req_addr_q     <= '0;
            req_wdata_q    <= '0;
            req_byte_en_q  <= '0;
            victim_way_q   <= 1'b0;
            victim_dirty_q <= 1'b0;
            victim_tag_q   <= '0;
            victim_data_q  <= '0;
        end else begin
            // ----------------------------------------------------------------
            // Normal Clocked Updates:
            // Advance FSM state and pipeline/victim tracking registers
            // ----------------------------------------------------------------
            state_q        <= state_d;
            victim_way_q   <= victim_way_d;
            victim_dirty_q <= victim_dirty_d;
            victim_tag_q   <= victim_tag_d;
            victim_data_q  <= victim_data_d;

            // ----------------------------------------------------------------
            // CPU Request Latching:
            // When an incoming CPU request requires multi-cycle processing
            // (e.g. miss requiring ALLOCATE / WRITE_BACK or write to SHARED
            // requiring UPGRADE), latch the CPU request parameters into registers.
            // This guarantees stable address, write-data, and byte enables
            // throughout multi-cycle bus transactions even if the CPU drops its
            // request lines before completion.
            // ----------------------------------------------------------------
            if (state_q == FSM_IDLE && cpu_req_valid && (state_d != FSM_IDLE)) begin
                req_rw_q      <= cpu_req_rw;
                req_addr_q    <= cpu_req_addr;
                req_wdata_q   <= cpu_req_wdata;
                req_byte_en_q <= cpu_byte_en;
            end
        end
    end

endmodule
