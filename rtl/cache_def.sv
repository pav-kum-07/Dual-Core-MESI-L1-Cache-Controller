// ============================================================================
// File: cache_def.sv
// Description: SystemVerilog package defining all constants, parameters,
//              types, enums, and address field slices for the 2-Way
//              Set-Associative MESI Cache Controller Subsystem.
// ============================================================================
`ifndef CACHE_DEF_SV
`define CACHE_DEF_SV
package cache_def;

    // ------------------------------------------------------------------------
    // Cache Architectural Parameters
    // ------------------------------------------------------------------------
    localparam int ADDR_WIDTH       = 32;       // 32-bit memory address
    localparam int DATA_WIDTH       = 32;       // 32-bit CPU word width
    localparam int LINE_SIZE_BYTES  = 16;       // 16 Bytes per cache line (4 words)
    localparam int LINE_WIDTH_BITS  = 128;      // 16 * 8 = 128 bits per line
    localparam int WORDS_PER_LINE   = 4;        // 4 words in a line (16 / 4)
    localparam int NUM_WAYS         = 2;        // 2-Way Set-Associative
    // NUM_SETS depends on: Total Cache Capacity / (LINE_SIZE_BYTES * NUM_WAYS) = 512B / (16B * 2) = 16
    localparam int NUM_SETS         = 16;       // 16 Sets (Rows in SRAM)

    // ------------------------------------------------------------------------
    // Address Bit Slices & Width Calculations
    // ------------------------------------------------------------------------
    // Offset: log2(16) = 4 bits -> [3:0]
    //   - Byte Offset: [1:0] (2 bits: Byte 0, 1, 2, 3 in a word)
    //   - Word Select: [3:2] (2 bits: Word 0, 1, 2, 3 in a line)
    // Set Index: log2(16) = 4 bits -> [7:4] (Set 0 to Set 15)
    // Tag: 32 - 4 - 4 = 24 bits -> [31:8]
    localparam int BYTE_OFFSET_WIDTH = 2;       // [1:0]
    localparam int WORD_OFFSET_WIDTH = 2;       // [3:2]
    localparam int BLOCK_OFFSET_WIDTH = 4;      // [3:0]
    localparam int SET_INDEX_WIDTH   = 4;       // [7:4]
    localparam int TAG_WIDTH         = 24;      // [31:8]

    // ------------------------------------------------------------------------
    // MESI Coherence States (2 bits per way)
    // ------------------------------------------------------------------------
    typedef enum logic [1:0] {
        INVALID   = 2'b00,  // Line holds no valid data (empty/stale)
        SHARED    = 2'b01,  // Line is clean, shared among multiple cores
        EXCLUSIVE = 2'b10,  // Line is clean, exclusive to this core
        MODIFIED  = 2'b11   // Line is dirty, exclusive to this core
    } mesi_state_t;

    // ------------------------------------------------------------------------
    // Shared Snooping Bus Commands
    // ------------------------------------------------------------------------
    // Used across the shared interconnect between Cores, Snoopers, and Memory.
    //
    // Miss Handling & Hierarchy Rule:
    // - CPU NEVER accesses memory directly. The Cache Controller transparently
    //   handles memory transactions, refills lines, and feeds words to the CPU.
    // - On a Read Miss:
    //     * Clean victim: Controller issues BUS_RD directly to DRAM.
    //     * Dirty victim: Controller FIRST issues BUS_WB (saves dirty line to DRAM),
    //       THEN issues BUS_RD (fetches the requested line).
    //
    // Command Operation Details:
    // 1. BUS_IDLE:
    //    - When: No core has an active request on the bus.
    //    - How: Bus arbiter idle; no snoop lookups or memory accesses occur.
    // 2. BUS_RD (Bus Read):
    //    - When: CPU Read Miss occurs in FSM_ALLOCATE.
    //    - How: 
    //        * If peer does NOT have the line (bus_snoop_hit = 0):
    //          Line is fetched from Main Memory (DRAM). Initiator installs it as
    //          EXCLUSIVE (E), allowing subsequent local writes to hit silently (0 bus cycles).
    //        * If peer DOES have the line (bus_snoop_hit = 1):
    //          Peer downgrades its state (M/E -> S; if M, peer supplies dirty line).
    //          Initiator installs line as SHARED (S) since multiple cores now share it.
    // 3. BUS_RDX (Bus Read with Intent to Modify / Read Invalidate):
    //    - When: CPU Write Miss occurs in FSM_ALLOCATE.
    //    - How: Fetches 16B line from DRAM/peer AND invalidates all peer copies
    //           (peers transition to I). Initiator installs line as M.
    // 4. BUS_UPGR (Bus Upgrade / Invalidation):
    //    - When: CPU Write Hit on a line in SHARED (S) state in FSM_UPGRADE.
    //    - How: Broadcasts invalidate without data fetch. Peers in S drop to I.
    //           Initiator upgrades line from S -> M and writes the CPU word.
    // 5. BUS_WB (Write-Back):
    //    - When: Dirty line (MODIFIED) eviction during replacement in FSM_WRITE_BACK.
    //    - How: Transmits the evicted 16B dirty line back to DRAM before allocating
    //           the new requested line.
    // ------------------------------------------------------------------------
    typedef enum logic [2:0] {
        BUS_IDLE   = 3'b000, // No transaction on bus
        BUS_RD     = 3'b001, // Read request (fetch line, intent to read)
        BUS_RDX    = 3'b010, // Read with Intent to Modify (fetch & invalidate peers)
        BUS_UPGR   = 3'b011, // Upgrade request (hit on S, invalidate peers)
        BUS_WB     = 3'b100  // Write-Back dirty line (16 bytes) to Main Memory
    } bus_cmd_t;

    // ------------------------------------------------------------------------
    // Cache Controller Main FSM States
    // ------------------------------------------------------------------------
    // 1. FSM_IDLE:
    //    - When: Waiting for new CPU requests (cpu_req_valid).
    //    - How: Evaluates tag match combinatorially. On read hit: delivers data
    //           and asserts cpu_ready in 1 cycle. On write hit (M/E): writes word
    //           in 1 cycle. On write hit (S): goes to FSM_UPGRADE. On miss:
    //           selects victim (clean -> FSM_ALLOCATE, dirty -> FSM_WRITE_BACK).
    // 2. FSM_COMPARE_TAG:
    //    - When: Pipelined tag comparison cycle (used if request is registered).
    // 3. FSM_WRITE_BACK:
    //    - When: Cache miss chose a MODIFIED (dirty) victim line to evict.
    //    - How: Drives bus_req_cmd = BUS_WB with dirty data. Once mem_resp_valid
    //           is received, transitions to FSM_ALLOCATE.
    // 4. FSM_ALLOCATE:
    //    - When: Miss occurred (or write-back completed) and line must be fetched.
    //    - How: Drives bus_req_cmd = BUS_RD (read miss) or BUS_RDX (write miss).
    //           When mem_resp_data arrives: writes 16B to data SRAM, sets tag &
    //           MESI state (E/S or M), updates LRU, delivers data, asserts cpu_ready.
    // 5. FSM_UPGRADE:
    //    - When: CPU write hit on a SHARED (S) line.
    //    - How: Drives bus_req_cmd = BUS_UPGR. Once bus_req_gnt is granted,
    //           upgrades local state S -> M, writes CPU word, asserts cpu_ready.
    // ------------------------------------------------------------------------
    typedef enum logic [2:0] {
        FSM_IDLE         = 3'b000, // Awaiting CPU request / 1-cycle hit handling
        FSM_COMPARE_TAG  = 3'b001, // Tag match & hit/miss evaluation
        FSM_WRITE_BACK   = 3'b010, // Evicting dirty victim line to Memory (BUS_WB)
        FSM_ALLOCATE     = 3'b011, // Refilling 16B line from Memory (BUS_RD/BUS_RDX)
        FSM_UPGRADE      = 3'b100  // Invalidation upgrade on Write Hit to S (BUS_UPGR)
    } cache_fsm_state_t;

    // ------------------------------------------------------------------------
    // Address Field Extraction Functions
    // ------------------------------------------------------------------------
    function automatic logic [TAG_WIDTH-1:0] get_tag(input logic [ADDR_WIDTH-1:0] addr);
        return addr[31 : 8];
    endfunction

    function automatic logic [SET_INDEX_WIDTH-1:0] get_index(input logic [ADDR_WIDTH-1:0] addr);
        return addr[7 : 4];
    endfunction

    function automatic logic [WORD_OFFSET_WIDTH-1:0] get_word_offset(input logic [ADDR_WIDTH-1:0] addr);
        return addr[3 : 2];
    endfunction

    function automatic logic [BYTE_OFFSET_WIDTH-1:0] get_byte_offset(input logic [ADDR_WIDTH-1:0] addr);
        return addr[1 : 0];
    endfunction

    function automatic logic [LINE_WIDTH_BITS-1:0] apply_word_write(
        input logic [LINE_WIDTH_BITS-1:0]   curr_line,
        input logic [WORD_OFFSET_WIDTH-1:0] word_idx,
        input logic [DATA_WIDTH-1:0]        new_word,
        input logic [3:0]                   b_en
    );
        logic [LINE_WIDTH_BITS-1:0] updated_line;
        updated_line = curr_line;
        for (int b = 0; b < 4; b++) begin
            if (b_en[b]) begin
                updated_line[word_idx*32 + b*8 +: 8] = new_word[b*8 +: 8];
            end
        end
        return updated_line;
    endfunction

endpackage: cache_def
`endif
