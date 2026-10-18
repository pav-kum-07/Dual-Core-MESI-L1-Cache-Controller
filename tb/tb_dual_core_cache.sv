// ============================================================================
// File: tb_dual_core_cache.sv
// Description: Non-UVM Directed Testbench for Dual-Core MESI Cache Subsystem.
//              Verifies Read/Write Hits, Misses, DRAM Refills, and MESI
//              Cross-Snoop Coherence between Core 0 and Core 1.
// ============================================================================

`timescale 1ns/1ps

`include "../rtl/cache_def.sv"
import cache_def::*;

module tb_dual_core_cache;

    // ------------------------------------------------------------------------
    // Clock & Reset Generation
    // ------------------------------------------------------------------------
    logic clk;
    logic rst_n;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk; // 100 MHz clock (10 ns period)
    end

    // ------------------------------------------------------------------------
    // DUT Interconnect Signals
    // ------------------------------------------------------------------------
    // Core 0 Interface
    logic                  core0_req_valid;
    logic                  core0_req_rw;
    logic [ADDR_WIDTH-1:0] core0_req_addr;
    logic [DATA_WIDTH-1:0] core0_req_wdata;
    logic [3:0]            core0_byte_en;
    logic                  core0_ready;
    logic [DATA_WIDTH-1:0] core0_resp_rdata;
    logic                  core0_resp_valid;

    // Core 1 Interface
    logic                  core1_req_valid;
    logic                  core1_req_rw;
    logic [ADDR_WIDTH-1:0] core1_req_addr;
    logic [DATA_WIDTH-1:0] core1_req_wdata;
    logic [3:0]            core1_byte_en;
    logic                  core1_ready;
    logic [DATA_WIDTH-1:0] core1_resp_rdata;
    logic                  core1_resp_valid;

    // Main Memory Interface
    logic                       mem_req_valid;
    bus_cmd_t                   mem_req_cmd;
    logic [ADDR_WIDTH-1:0]      mem_req_addr;
    logic [LINE_WIDTH_BITS-1:0] mem_req_wdata;
    logic                       mem_resp_valid;
    logic [LINE_WIDTH_BITS-1:0] mem_resp_data;

    // Test tracking counters
    int test_count = 0;
    int pass_count = 0;
    int fail_count = 0;

    // ========================================================================
    // Functional Coverage Model
    // ========================================================================
    covergroup cache_functional_cov @(posedge clk);
        // CPU Read / Write requests
        cp_c0_rw: coverpoint core0_req_rw iff (core0_req_valid) {
            bins read  = {1'b0};
            bins write = {1'b1};
        }
        cp_c1_rw: coverpoint core1_req_rw iff (core1_req_valid) {
            bins read  = {1'b0};
            bins write = {1'b1};
        }
        // Word Offsets within the 128-bit cache line (Words 0, 1, 2, 3)
        cp_c0_word: coverpoint core0_req_addr[3:2] iff (core0_req_valid) {
            bins word0 = {2'b00};
            bins word1 = {2'b01};
            bins word2 = {2'b10};
            bins word3 = {2'b11};
        }
        cp_c1_word: coverpoint core1_req_addr[3:2] iff (core1_req_valid) {
            bins word0 = {2'b00};
            bins word1 = {2'b01};
            bins word2 = {2'b10};
            bins word3 = {2'b11};
        }
        // Byte Enable Coverage
        cp_c0_byte_en: coverpoint core0_byte_en iff (core0_req_valid) {
            bins full_word = {4'b1111};
            bins half_word = {4'b0011, 4'b1100};
            bins byte_acc  = {4'b0001, 4'b0010, 4'b0100, 4'b1000};
            illegal_bins no_byte   = {4'b0000}; // Throws simulation error if seen during valid req
        }
        cp_c1_byte_en: coverpoint core1_byte_en iff (core1_req_valid) {
            bins full_word = {4'b1111};
            bins half_word = {4'b0011, 4'b1100};
            bins byte_acc  = {4'b0001, 4'b0010, 4'b0100, 4'b1000};
        }
        // Memory Bus Commands (to DRAM)
        cp_mem_cmd: coverpoint mem_req_cmd iff (mem_req_valid) {
            bins bus_read  = {BUS_RD};
            bins bus_readx = {BUS_RDX};
            bins bus_wb    = {BUS_WB};
        }
        // Interconnect Bus Commands (issued by Core 0 & Core 1 to the Arbiter)
        cp_c0_bus_cmd: coverpoint dut.c0_bus_cmd iff (dut.c0_bus_req) {
            bins bus_read  = {BUS_RD};
            bins bus_readx = {BUS_RDX};
            bins bus_upgr  = {BUS_UPGR};
            bins bus_wb    = {BUS_WB};
        }
        cp_c1_bus_cmd: coverpoint dut.c1_bus_cmd iff (dut.c1_bus_req) {
            bins bus_read  = {BUS_RD};
            bins bus_readx = {BUS_RDX};
            bins bus_upgr  = {BUS_UPGR};
            bins bus_wb    = {BUS_WB};
        }
        // Cross Coverage
        cross_c0_rw_word: cross cp_c0_rw, cp_c0_word;
        cross_c1_rw_word: cross cp_c1_rw, cp_c1_word;

        // --------------------------------------------------------------------
        // MESI Protocol & Controller FSM State Coverage
        // --------------------------------------------------------------------
        // Core 0 & Core 1 Reachable FSM States (Tag compare is 1-cycle combinational in IDLE)
        cp_c0_fsm: coverpoint dut.core0_cache.state_q {
            bins idle       = {FSM_IDLE};
            bins write_back = {FSM_WRITE_BACK};
            bins allocate   = {FSM_ALLOCATE};
            bins upgrade    = {FSM_UPGRADE};
            ignore_bins unused_cmp = {FSM_COMPARE_TAG};
        }
        cp_c1_fsm: coverpoint dut.core1_cache.state_q {
            bins idle       = {FSM_IDLE};
            bins write_back = {FSM_WRITE_BACK};
            bins allocate   = {FSM_ALLOCATE};
            bins upgrade    = {FSM_UPGRADE};
            ignore_bins unused_cmp = {FSM_COMPARE_TAG};
        }
        // Core 0 MESI Allocated / Updated States on Port A
        cp_c0_mesi_wr: coverpoint dut.core0_cache.wr_state_d iff (dut.core0_cache.wr_en_tag_way0 || dut.core0_cache.wr_en_tag_way1) {
            bins to_exclusive = {EXCLUSIVE};
            bins to_modified  = {MODIFIED};
            bins to_shared    = {SHARED};
        }
        // Core 1 MESI Allocated / Updated States on Port A
        cp_c1_mesi_wr: coverpoint dut.core1_cache.wr_state_d iff (dut.core1_cache.wr_en_tag_way0 || dut.core1_cache.wr_en_tag_way1) {
            bins to_exclusive = {EXCLUSIVE};
            bins to_modified  = {MODIFIED};
            bins to_shared    = {SHARED};
        }
        // MESI Snoop State Updates on Port B (Downgrade to SHARED or Invalidate to INVALID)
        cp_c0_snoop_update: coverpoint dut.core0_cache.snoop_wr_state iff (dut.core0_cache.snoop_wr_en) {
            bins snoop_shared  = {SHARED};  // Downgrade (M/E -> S) on peer read
            bins snoop_invalid = {INVALID}; // Invalidation (M/E/S -> I) on peer write
        }
        cp_c1_snoop_update: coverpoint dut.core1_cache.snoop_wr_state iff (dut.core1_cache.snoop_wr_en) {
            bins snoop_shared  = {SHARED};
            bins snoop_invalid = {INVALID};
        }
    endgroup

    cache_functional_cov cov_inst = new();

    // ------------------------------------------------------------------------
    // 1. Instantiate the DUT: dual_core_cache_subsystem
    // ------------------------------------------------------------------------
    dual_core_cache_subsystem dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .core0_req_valid  (core0_req_valid),
        .core0_req_rw     (core0_req_rw),
        .core0_req_addr   (core0_req_addr),
        .core0_req_wdata  (core0_req_wdata),
        .core0_byte_en    (core0_byte_en),
        .core0_ready      (core0_ready),
        .core0_resp_rdata (core0_resp_rdata),
        .core0_resp_valid (core0_resp_valid),
        .core1_req_valid  (core1_req_valid),
        .core1_req_rw     (core1_req_rw),
        .core1_req_addr   (core1_req_addr),
        .core1_req_wdata  (core1_req_wdata),
        .core1_byte_en    (core1_byte_en),
        .core1_ready      (core1_ready),
        .core1_resp_rdata (core1_resp_rdata),
        .core1_resp_valid (core1_resp_valid),
        .mem_req_valid    (mem_req_valid),
        .mem_req_cmd      (mem_req_cmd),
        .mem_req_addr     (mem_req_addr),
        .mem_req_wdata    (mem_req_wdata),
        .mem_resp_valid   (mem_resp_valid),
        .mem_resp_data    (mem_resp_data)
    );

    // ------------------------------------------------------------------------
    // 2. Instantiate the Memory Slave Model (Simulated DRAM)
    // ------------------------------------------------------------------------
    mem_slave_model #(
        .MEM_LATENCY_CYCLES (2),
        .VERBOSE            (1'b0)
    ) dram_inst (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_req_valid  (mem_req_valid),
        .mem_req_cmd    (mem_req_cmd),
        .mem_req_addr   (mem_req_addr),
        .mem_req_wdata  (mem_req_wdata),
        .mem_resp_valid (mem_resp_valid),
        .mem_resp_data  (mem_resp_data)
    );

    // ========================================================================
    // SystemVerilog Assertions (SVA) - Protocol & Coherence Invariants
    // ========================================================================

    // 1. Bus Arbiter Mutual Exclusion: Never grant bus to both cores simultaneously
    assert_single_bus_grant: assert property (
        @(posedge clk) disable iff (!rst_n)
        !(dut.arbiter_inst.core0_bus_gnt && dut.arbiter_inst.core1_bus_gnt)
    ) else $error("[SVA VIOLATION @ %0t ps] Arbiter granted bus to both Core 0 and Core 1 simultaneously!", $time);

    // 2. No Phantom Grants: Arbiter must only grant to a core actively requesting
    assert_valid_gnt0: assert property (
        @(posedge clk) disable iff (!rst_n)
        dut.arbiter_inst.core0_bus_gnt |-> dut.arbiter_inst.core0_bus_req
    ) else $error("[SVA VIOLATION @ %0t ps] Core 0 received bus grant without active request!", $time);

    assert_valid_gnt1: assert property (
        @(posedge clk) disable iff (!rst_n)
        dut.arbiter_inst.core1_bus_gnt |-> dut.arbiter_inst.core1_bus_req
    ) else $error("[SVA VIOLATION @ %0t ps] Core 1 received bus grant without active request!", $time);

    // 3. CPU Response Pulse: cpu_resp_valid must be a clean 1-cycle active pulse
    assert_c0_resp_pulse: assert property (
        @(posedge clk) disable iff (!rst_n)
        core0_resp_valid |=> !core0_resp_valid
    ) else $error("[SVA VIOLATION @ %0t ps] Core 0 cpu_resp_valid held high for >1 clock cycle!", $time);

    assert_c1_resp_pulse: assert property (
        @(posedge clk) disable iff (!rst_n)
        core1_resp_valid |=> !core1_resp_valid
    ) else $error("[SVA VIOLATION @ %0t ps] Core 1 cpu_resp_valid held high for >1 clock cycle!", $time);

    // 4. DRAM Memory Response Pulse: mem_resp_valid must be a clean 1-cycle strobe
    assert_mem_resp_pulse: assert property (
        @(posedge clk) disable iff (!rst_n)
        mem_resp_valid |=> !mem_resp_valid
    ) else $error("[SVA VIOLATION @ %0t ps] DRAM mem_resp_valid held high for >1 clock cycle!", $time);

    // 5. Snoop Dirty Forwarding Data Integrity: Dirty line forward payload cannot be empty
    assert_c0_dirty_forward_data: assert property (
        @(posedge clk) disable iff (!rst_n)
        dut.core0_cache.snoop_resp_dirty |-> (dut.core0_cache.snoop_resp_data !== '0)
    ) else $error("[SVA VIOLATION @ %0t ps] Core 0 reported dirty snoop hit but supplied empty data!", $time);

    assert_c1_dirty_forward_data: assert property (
        @(posedge clk) disable iff (!rst_n)
        dut.core1_cache.snoop_resp_dirty |-> (dut.core1_cache.snoop_resp_data !== '0)
    ) else $error("[SVA VIOLATION @ %0t ps] Core 1 reported dirty snoop hit but supplied empty data!", $time);

    // 6. MESI Protocol Invariant: BUS_UPGR can only be issued from FSM_UPGRADE state
    assert_c0_upgr_fsm_check: assert property (
        @(posedge clk) disable iff (!rst_n)
        (dut.c0_bus_req && dut.c0_bus_cmd == BUS_UPGR) |-> (dut.core0_cache.state_q == FSM_UPGRADE)
    ) else $error("[SVA VIOLATION @ %0t ps] Core 0 issued BUS_UPGR while not in FSM_UPGRADE state!", $time);

    assert_c1_upgr_fsm_check: assert property (
        @(posedge clk) disable iff (!rst_n)
        (dut.c1_bus_req && dut.c1_bus_cmd == BUS_UPGR) |-> (dut.core1_cache.state_q == FSM_UPGRADE)
    ) else $error("[SVA VIOLATION @ %0t ps] Core 1 issued BUS_UPGR while not in FSM_UPGRADE state!", $time);

    // ========================================================================
    // MESI Protocol Specific Assertions (Coherence Invariants)
    // ========================================================================

    // 7. Global MESI Single-Writer / Multiple-Reader (SWMR) Invariant:
    // Across all 16 sets and both ways: If both Core 0 and Core 1 hold a valid line
    // for the exact same physical tag, the ONLY legal state for both is SHARED!
    // (Neither core may be in MODIFIED or EXCLUSIVE while the peer holds a copy).
    genvar s_idx;
    generate
        for (s_idx = 0; s_idx < NUM_SETS; s_idx++) begin : gen_mesi_coherence_checker
            // Core 0 Way 0 vs Core 1 Way 0
            assert_mesi_swmr_w00: assert property (
                @(posedge clk) disable iff (!rst_n)
                (dut.core0_cache.tag_array_inst.state_ram_way0[s_idx] != INVALID &&
                 dut.core1_cache.tag_array_inst.state_ram_way0[s_idx] != INVALID &&
                 dut.core0_cache.tag_array_inst.tag_ram_way0[s_idx] == dut.core1_cache.tag_array_inst.tag_ram_way0[s_idx])
                |->
                (dut.core0_cache.tag_array_inst.state_ram_way0[s_idx] == SHARED &&
                 dut.core1_cache.tag_array_inst.state_ram_way0[s_idx] == SHARED)
            ) else $error("[MESI VIOLATION @ %0t ps] Set %0d Way00 Coherence Error: Simultaneous Non-Shared Copy!", $time, s_idx);

            // Core 0 Way 0 vs Core 1 Way 1
            assert_mesi_swmr_w01: assert property (
                @(posedge clk) disable iff (!rst_n)
                (dut.core0_cache.tag_array_inst.state_ram_way0[s_idx] != INVALID &&
                 dut.core1_cache.tag_array_inst.state_ram_way1[s_idx] != INVALID &&
                 dut.core0_cache.tag_array_inst.tag_ram_way0[s_idx] == dut.core1_cache.tag_array_inst.tag_ram_way1[s_idx])
                |->
                (dut.core0_cache.tag_array_inst.state_ram_way0[s_idx] == SHARED &&
                 dut.core1_cache.tag_array_inst.state_ram_way1[s_idx] == SHARED)
            ) else $error("[MESI VIOLATION @ %0t ps] Set %0d Way01 Coherence Error: Simultaneous Non-Shared Copy!", $time, s_idx);

            // Core 0 Way 1 vs Core 1 Way 0
            assert_mesi_swmr_w10: assert property (
                @(posedge clk) disable iff (!rst_n)
                (dut.core0_cache.tag_array_inst.state_ram_way1[s_idx] != INVALID &&
                 dut.core1_cache.tag_array_inst.state_ram_way0[s_idx] != INVALID &&
                 dut.core0_cache.tag_array_inst.tag_ram_way1[s_idx] == dut.core1_cache.tag_array_inst.tag_ram_way0[s_idx])
                |->
                (dut.core0_cache.tag_array_inst.state_ram_way1[s_idx] == SHARED &&
                 dut.core1_cache.tag_array_inst.state_ram_way0[s_idx] == SHARED)
            ) else $error("[MESI VIOLATION @ %0t ps] Set %0d Way10 Coherence Error: Simultaneous Non-Shared Copy!", $time, s_idx);

            // Core 0 Way 1 vs Core 1 Way 1
            assert_mesi_swmr_w11: assert property (
                @(posedge clk) disable iff (!rst_n)
                (dut.core0_cache.tag_array_inst.state_ram_way1[s_idx] != INVALID &&
                 dut.core1_cache.tag_array_inst.state_ram_way1[s_idx] != INVALID &&
                 dut.core0_cache.tag_array_inst.tag_ram_way1[s_idx] == dut.core1_cache.tag_array_inst.tag_ram_way1[s_idx])
                |->
                (dut.core0_cache.tag_array_inst.state_ram_way1[s_idx] == SHARED &&
                 dut.core1_cache.tag_array_inst.state_ram_way1[s_idx] == SHARED)
            ) else $error("[MESI VIOLATION @ %0t ps] Set %0d Way11 Coherence Error: Simultaneous Non-Shared Copy!", $time, s_idx);
        end
    endgenerate

    // 8. Snoop Invalidation Invariant:
    // When a core broadcasts a write (BUS_RDX or BUS_UPGR), if the peer has a snoop hit,
    // the peer cache MUST assert snoop write enable with target state INVALID.
    assert_c1_inval_on_c0_write: assert property (
        @(posedge clk) disable iff (!rst_n)
        (dut.core1_cache.snoop_req_valid && 
         (dut.core1_cache.snoop_req_cmd inside {BUS_RDX, BUS_UPGR}) && 
         dut.core1_cache.snoop_tag_hit)
        |-> 
        (dut.core1_cache.snoop_wr_en && dut.core1_cache.snoop_wr_state == INVALID)
    ) else $error("[MESI VIOLATION @ %0t ps] Core 1 failed to assert snoop invalidation on write broadcast!", $time);

    assert_c0_inval_on_c1_write: assert property (
        @(posedge clk) disable iff (!rst_n)
        (dut.core0_cache.snoop_req_valid && 
         (dut.core0_cache.snoop_req_cmd inside {BUS_RDX, BUS_UPGR}) && 
         dut.core0_cache.snoop_tag_hit)
        |-> 
        (dut.core0_cache.snoop_wr_en && dut.core0_cache.snoop_wr_state == INVALID)
    ) else $error("[MESI VIOLATION @ %0t ps] Core 0 failed to assert snoop invalidation on write broadcast!", $time);

    // 9. Snoop Dirty Downgrade Invariant:
    // When a core reads (BUS_RD), if the peer has a snoop hit on a MODIFIED line,
    // the peer cache MUST assert snoop write enable with target state SHARED.
    assert_c1_downgrade_on_c0_rd: assert property (
        @(posedge clk) disable iff (!rst_n)
        (dut.core1_cache.snoop_req_valid && 
         (dut.core1_cache.snoop_req_cmd == BUS_RD) && 
         dut.core1_cache.snoop_tag_hit && 
         dut.core1_cache.snoop_tag_state == MODIFIED)
        |-> 
        (dut.core1_cache.snoop_wr_en && dut.core1_cache.snoop_wr_state == SHARED)
    ) else $error("[MESI VIOLATION @ %0t ps] Core 1 failed to downgrade dirty line to SHARED on BUS_RD!", $time);

    assert_c0_downgrade_on_c1_rd: assert property (
        @(posedge clk) disable iff (!rst_n)
        (dut.core0_cache.snoop_req_valid && 
         (dut.core0_cache.snoop_req_cmd == BUS_RD) && 
         dut.core0_cache.snoop_tag_hit && 
         dut.core0_cache.snoop_tag_state == MODIFIED)
        |-> 
        (dut.core0_cache.snoop_wr_en && dut.core0_cache.snoop_wr_state == SHARED)
    ) else $error("[MESI VIOLATION @ %0t ps] Core 0 failed to downgrade dirty line to SHARED on BUS_RD!", $time);

    // 10. Read Hit Silence Invariant:
    // If a core has a Read Hit during FSM_IDLE, it must never request the shared bus.
    assert_c0_read_hit_silent: assert property (
        @(posedge clk) disable iff (!rst_n)
        (dut.core0_cache.state_q == FSM_IDLE && 
         core0_req_valid && !core0_req_rw && 
         dut.core0_cache.cache_hit)
        |-> (!dut.c0_bus_req)
    ) else $error("[MESI VIOLATION @ %0t ps] Core 0 raised bus request despite Read Hit!", $time);

    assert_c1_read_hit_silent: assert property (
        @(posedge clk) disable iff (!rst_n)
        (dut.core1_cache.state_q == FSM_IDLE && 
         core1_req_valid && !core1_req_rw && 
         dut.core1_cache.cache_hit)
        |-> (!dut.c1_bus_req)
    ) else $error("[MESI VIOLATION @ %0t ps] Core 1 raised bus request despite Read Hit!", $time);

    // ========================================================================
    // Golden Shared-Memory Scoreboard (Step 2 Verification)
    // ========================================================================
    logic [31:0] golden_mem [logic [31:0]]; // Key: Word-aligned 32-bit addr, Value: 32-bit golden data
    int unsigned scb_total_checks = 0;
    int unsigned scb_pass_count   = 0;
    int unsigned scb_fail_count   = 0;

    // Helper: Initialize a 128-bit block in golden memory (used when preloading DRAM)
    task automatic scoreboard_init_line(input logic [ADDR_WIDTH-1:0] base_addr, input logic [127:0] line_data);
        golden_mem[{base_addr[31:4], 4'h0}] = line_data[31:0];
        golden_mem[{base_addr[31:4], 4'h4}] = line_data[63:32];
        golden_mem[{base_addr[31:4], 4'h8}] = line_data[95:64];
        golden_mem[{base_addr[31:4], 4'hC}] = line_data[127:96];
    endtask

    // Update golden memory upon any Core Write (with byte enable granularity)
    task automatic scoreboard_write(
        input string                 core_id,
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [DATA_WIDTH-1:0] wdata,
        input logic [3:0]            byte_en
    );
        logic [31:0] current_val;
        logic [31:0] aligned_addr;
        aligned_addr = {addr[31:2], 2'b00};

        // If location has not been written in golden memory yet, fetch DRAM baseline
        if (!golden_mem.exists(aligned_addr)) begin
            logic [127:0] dram_line;
            dram_inst.backdoor_read_line(aligned_addr, dram_line);
            case (aligned_addr[3:2])
                2'b00: current_val = dram_line[31:0];
                2'b01: current_val = dram_line[63:32];
                2'b10: current_val = dram_line[95:64];
                2'b11: current_val = dram_line[127:96];
            endcase
        end else begin
            current_val = golden_mem[aligned_addr];
        end

        // Apply byte enable mask
        if (byte_en[0]) current_val[7:0]   = wdata[7:0];
        if (byte_en[1]) current_val[15:8]  = wdata[15:8];
        if (byte_en[2]) current_val[23:16] = wdata[23:16];
        if (byte_en[3]) current_val[31:24] = wdata[31:24];

        golden_mem[aligned_addr] = current_val;
    endtask

    // Verify CPU read data against golden memory
    task automatic scoreboard_check_read(
        input string                 core_id,
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [DATA_WIDTH-1:0] actual_rdata
    );
        logic [31:0] expected_val;
        logic [31:0] aligned_addr;
        aligned_addr = {addr[31:2], 2'b00};

        if (golden_mem.exists(aligned_addr)) begin
            expected_val = golden_mem[aligned_addr];
        end else begin
            // Baseline from DRAM for unwritten location
            logic [127:0] dram_line;
            dram_inst.backdoor_read_line(aligned_addr, dram_line);
            case (aligned_addr[3:2])
                2'b00: expected_val = dram_line[31:0];
                2'b01: expected_val = dram_line[63:32];
                2'b10: expected_val = dram_line[95:64];
                2'b11: expected_val = dram_line[127:96];
            endcase
            golden_mem[aligned_addr] = expected_val;
        end

        scb_total_checks++;
        if (actual_rdata === expected_val) begin
            scb_pass_count++;
            $display("   [SCB MATCH] Core=%s ADDR=0x%08h Data=0x%08h", core_id, addr, actual_rdata);
        end else begin
            scb_fail_count++;
            $error("   [SCB MISMATCH @ %0t ps] Core=%s ADDR=0x%08h | Expected=0x%08h | Actual=0x%08h",
                   $time, core_id, addr, expected_val, actual_rdata);
        end
    endtask

    // ========================================================================
    // Constrained-Random Transaction Generator (Step 3 Verification)
    // ========================================================================
    class cache_trans;
        rand bit                  rw;       // 0 = Read, 1 = Write
        rand bit [ADDR_WIDTH-1:0] addr;     // Word-aligned target address
        rand bit [DATA_WIDTH-1:0] data;     // Random write data payload
        rand bit [3:0]            byte_en;  // Sub-word byte enable mask

        constraint c_word_aligned {
            addr[1:0] == 2'b00; // Must be 32-bit word aligned
        }

        constraint c_byte_en_valid {
            byte_en != 4'b0000;
            byte_en dist {
                4'b1111 := 70,
                4'b0011 := 10,
                4'b1100 := 10,
                4'b0001 := 5,
                4'b1000 := 5
            };
        }

        constraint c_rw_dist {
            rw dist { 0 := 50, 1 := 50 };
        }
    endclass

    // ------------------------------------------------------------------------
    // CPU Emulation Tasks (Non-UVM Drivers with Scoreboard Interception)
    // ------------------------------------------------------------------------
    // Core 0 Write Task
    task automatic core0_write(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [DATA_WIDTH-1:0] data,
        input logic [3:0]            be = 4'b1111
    );
        @(posedge clk);
        core0_req_valid <= 1'b1;
        core0_req_rw    <= 1'b1;
        core0_req_addr  <= addr;
        core0_req_wdata <= data;
        core0_byte_en   <= be;

        @(posedge clk);
        while (!core0_ready) @(posedge clk);
        scoreboard_write("Core0", addr, data, be);
        core0_req_valid <= 1'b0;
        core0_req_rw    <= 1'b0;
        @(posedge clk);
    endtask

    // Core 0 Read Task
    task automatic core0_read(
        input  logic [ADDR_WIDTH-1:0] addr,
        output logic [DATA_WIDTH-1:0] data,
        input  logic [3:0]            be = 4'b1111
    );
        @(posedge clk);
        core0_req_valid <= 1'b1;
        core0_req_rw    <= 1'b0;
        core0_req_addr  <= addr;
        core0_byte_en   <= be;

        @(posedge clk);
        while (!core0_ready) @(posedge clk);
        data = core0_resp_rdata;
        core0_req_valid <= 1'b0;
        @(posedge clk);
        scoreboard_check_read("Core0", addr, data);
    endtask

    // Core 1 Write Task
    task automatic core1_write(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [DATA_WIDTH-1:0] data,
        input logic [3:0]            be = 4'b1111
    );
        @(posedge clk);
        core1_req_valid <= 1'b1;
        core1_req_rw    <= 1'b1;
        core1_req_addr  <= addr;
        core1_req_wdata <= data;
        core1_byte_en   <= be;

        @(posedge clk);
        while (!core1_ready) @(posedge clk);
        scoreboard_write("Core1", addr, data, be);
        core1_req_valid <= 1'b0;
        core1_req_rw    <= 1'b0;
        @(posedge clk);
    endtask

    // Core 1 Read Task
    task automatic core1_read(
        input  logic [ADDR_WIDTH-1:0] addr,
        output logic [DATA_WIDTH-1:0] data,
        input  logic [3:0]            be = 4'b1111
    );
        @(posedge clk);
        core1_req_valid <= 1'b1;
        core1_req_rw    <= 1'b0;
        core1_req_addr  <= addr;
        core1_byte_en   <= be;

        @(posedge clk);
        while (!core1_ready) @(posedge clk);
        data = core1_resp_rdata;
        core1_req_valid <= 1'b0;
        @(posedge clk);
        scoreboard_check_read("Core1", addr, data);
    endtask

    // Check Helper
    task automatic check_data(
        input string test_name,
        input logic [31:0] actual,
        input logic [31:0] expected
    );
        test_count++;
        if (actual === expected) begin
            $display("[PASS] %s: Got 0x%08h (Expected 0x%08h)", test_name, actual, expected);
            pass_count++;
        end else begin
            $display("[FAIL] %s: Got 0x%08h, Expected 0x%08h", test_name, actual, expected);
            fail_count++;
        end
    endtask

    // ------------------------------------------------------------------------
    // Main Verification Flow
    // ------------------------------------------------------------------------
    logic [31:0] rdata;

    initial begin
        // Reset initialization
        core0_req_valid = 1'b0;
        core0_req_rw    = 1'b0;
        core0_req_addr  = '0;
        core0_req_wdata = '0;
        core0_byte_en   = '0;

        core1_req_valid = 1'b0;
        core1_req_rw    = 1'b0;
        core1_req_addr  = '0;
        core1_req_wdata = '0;
        core1_byte_en   = '0;

        rst_n = 1'b0;
        #30;
        rst_n = 1'b1;
        #20;

        $display("==================================================================");
        $display("   STARTING NON-UVM DUAL-CORE CACHE VERIFICATION TESTBENCH        ");
        $display("==================================================================");

        // Pre-initialize a memory block in DRAM and Scoreboard
        dram_inst.backdoor_write_line(32'h0000_1000, 128'hCAFE_BABE_BEEF_DEAD_1234_5678_AAAA_5555);
        scoreboard_init_line(32'h0000_1000, 128'hCAFE_BABE_BEEF_DEAD_1234_5678_AAAA_5555);

        // --------------------------------------------------------------------
        // Test 1: Core 0 Cold Read Miss (DRAM Line Refill)
        // --------------------------------------------------------------------
        $display("\n--- Test 1: Core 0 Cold Read Miss from DRAM ---");
        core0_read(32'h0000_1000, rdata);
        check_data("Core 0 Read Miss (Word 0)", rdata, 32'hAAAA_5555);

        // --------------------------------------------------------------------
        // Test 2: Core 0 Read Hit (1-Cycle Cache Hit)
        // --------------------------------------------------------------------
        $display("\n--- Test 2: Core 0 Read Hit on Installed Line ---");
        core0_read(32'h0000_1004, rdata); // Word 1
        check_data("Core 0 Read Hit (Word 1)", rdata, 32'h1234_5678);

        // --------------------------------------------------------------------
        // Test 3: Core 0 Local Write (State becomes MODIFIED)
        // --------------------------------------------------------------------
        $display("\n--- Test 3: Core 0 Local Write to Word 0 ---");
        core0_write(32'h0000_1000, 32'hDEAD_9999);
        core0_read(32'h0000_1000, rdata);
        check_data("Core 0 Read after Write", rdata, 32'hDEAD_9999);

        // --------------------------------------------------------------------
        // Test 4: MESI Cross-Snoop Coherence Test
        // Core 1 reads 0x1000. Core 0 must snoop, detect MODIFIED state,
        // and supply its dirty data DIRECTLY to Core 1 without reading stale DRAM!
        // --------------------------------------------------------------------
        $display("\n--- Test 4: MESI Cross-Snoop Dirty Forwarding (Core 1 reads Core 0's modified data) ---");
        core1_read(32'h0000_1000, rdata);
        check_data("Core 1 Snoop Hit on Dirty Line", rdata, 32'hDEAD_9999);

        // --------------------------------------------------------------------
        // Test 5: Core 1 Read Hit on Shared Line
        // --------------------------------------------------------------------
        $display("\n--- Test 5: Core 1 Read Hit (Now in SHARED state) ---");
        core1_read(32'h0000_1004, rdata);
        check_data("Core 1 Read Hit (Word 1)", rdata, 32'h1234_5678);

        // --------------------------------------------------------------------
        // Test 6: Core 0 Write Hit on SHARED Line (Upgrades S -> M via BUS_UPGR)
        // --------------------------------------------------------------------
        $display("\n--- Test 6: Core 0 Write Hit on SHARED Line (BUS_UPGR invalidates Core 1) ---");
        core0_write(32'h0000_1000, 32'hCAFE_1111);
        core0_read(32'h0000_1000, rdata);
        check_data("Core 0 Read after Upgrade Write", rdata, 32'hCAFE_1111);

        // --------------------------------------------------------------------
        // Test 7: Core 1 Write Miss (Issues BUS_RDX to DRAM, installs in MODIFIED)
        // --------------------------------------------------------------------
        $display("\n--- Test 7: Core 1 Write Miss (BUS_RDX Line Allocation) ---");
        core1_write(32'h0000_2000, 32'hBEEF_2222);
        core1_read(32'h0000_2000, rdata);
        check_data("Core 1 Read after Write Miss", rdata, 32'hBEEF_2222);

        // --------------------------------------------------------------------
        // Test 8: Exercise All Word Offsets (Words 0, 1, 2, 3) for Core 0 & Core 1
        // --------------------------------------------------------------------
        $display("\n--- Test 8: All Word Offsets Coverage (Words 2 & 3) ---");
        // Core 0 Word 2 and Word 3
        core0_write(32'h0000_1008, 32'h0000_0002); // Word 2
        core0_read(32'h0000_1008, rdata);
        check_data("Core 0 Read Word 2", rdata, 32'h0000_0002);

        core0_write(32'h0000_100C, 32'h0000_0003); // Word 3
        core0_read(32'h0000_100C, rdata);
        check_data("Core 0 Read Word 3", rdata, 32'h0000_0003);

        // Core 1 Word 1, 2, 3
        core1_write(32'h0000_2004, 32'h0000_1001); // Word 1
        core1_read(32'h0000_2004, rdata);
        check_data("Core 1 Read Word 1", rdata, 32'h0000_1001);

        core1_write(32'h0000_2008, 32'h0000_1002); // Word 2
        core1_read(32'h0000_2008, rdata);
        check_data("Core 1 Read Word 2", rdata, 32'h0000_1002);

        core1_write(32'h0000_200C, 32'h0000_1003); // Word 3
        core1_read(32'h0000_200C, rdata);
        check_data("Core 1 Read Word 3", rdata, 32'h0000_1003);

        // --------------------------------------------------------------------
        // Test 9: Sub-Word Byte & Halfword Writes (Byte-Enables Coverage)
        // --------------------------------------------------------------------
        $display("\n--- Test 9: Sub-Word Byte Enables (Halfwords & Single Bytes) ---");
        // Core 0 Halfwords
        core0_write(32'h0000_1000, 32'h5555_0000, 4'b1100); // Upper halfword
        core0_write(32'h0000_1000, 32'h0000_3333, 4'b0011); // Lower halfword
        core0_read(32'h0000_1000, rdata);
        check_data("Core 0 Halfwords Combined", rdata, 32'h5555_3333);

        // Core 0 Individual Bytes
        core0_write(32'h0000_1000, 32'h0000_0011, 4'b0001); // Byte 0
        core0_write(32'h0000_1000, 32'h0000_2200, 4'b0010); // Byte 1
        core0_write(32'h0000_1000, 32'h0044_0000, 4'b0100); // Byte 2
        core0_write(32'h0000_1000, 32'h8800_0000, 4'b1000); // Byte 3
        core0_read(32'h0000_1000, rdata);
        check_data("Core 0 Individual Bytes Combined", rdata, 32'h8844_2211);

        // Core 1 Sub-words
        core1_write(32'h0000_2000, 32'hAAAA_0000, 4'b1100); // Upper halfword
        core1_write(32'h0000_2000, 32'h0000_BBBB, 4'b0011); // Lower halfword
        core1_write(32'h0000_2000, 32'h0000_00CC, 4'b0001); // Byte 0
        core1_write(32'h0000_2000, 32'h0000_DD00, 4'b0010); // Byte 1
        core1_write(32'h0000_2000, 32'h00EE_0000, 4'b0100); // Byte 2
        core1_write(32'h0000_2000, 32'hFF00_0000, 4'b1000); // Byte 3
        core1_read(32'h0000_2000, rdata);
        check_data("Core 1 Individual Bytes Combined", rdata, 32'hFFEE_DDCC);

        // --------------------------------------------------------------------
        // Test 10: 2-Way Conflict Miss & Dirty Write-Back (Triggers BUS_WB)
        // --------------------------------------------------------------------
        $display("\n--- Test 10: 2-Way Conflict Eviction & Dirty Write-Back (BUS_WB) ---");
        // Pre-initialize addresses that map to Set 5 (addr[7:4] = 4'h5)
        // Way 0 allocation:
        core0_write(32'h0000_0150, 32'hA150_A150); // Set 5, Way 0 (Dirty)
        // Way 1 allocation:
        core0_write(32'h0000_0250, 32'hB250_B250); // Set 5, Way 1 (Dirty)
        // 3rd conflicting address triggers LRU eviction of Way 0 -> BUS_WB written to DRAM!
        core0_write(32'h0000_0350, 32'hC350_C350); // Set 5, Way 0 victim evicted
        core0_read(32'h0000_0350, rdata);
        check_data("Core 0 Read 3rd Conflicting Line", rdata, 32'hC350_C350);

        // Confirm evicted dirty line 0x0150 was safely committed to DRAM
        core0_read(32'h0000_0150, rdata);
        check_data("Core 0 Read Back Evicted Dirty Line from DRAM", rdata, 32'hA150_A150);

        // --------------------------------------------------------------------
        // Test 11: Core 0 Word 1 Write (Cross Coverage cp_c0_rw x word1)
        // --------------------------------------------------------------------
        $display("\n--- Test 11: Core 0 Word 1 Store (Cross Coverage) ---");
        core0_write(32'h0000_1004, 32'hCAFE_2222);
        core0_read(32'h0000_1004, rdata);
        check_data("Core 0 Read Word 1 after Write", rdata, 32'hCAFE_2222);

        // --------------------------------------------------------------------
        // Test 12: Core 1 Cold Read Miss on Clean Address (Installs EXCLUSIVE)
        // --------------------------------------------------------------------
        $display("\n--- Test 12: Core 1 Cold Read Miss (Installs to EXCLUSIVE) ---");
        core1_read(32'h0000_4000, rdata);

        // --------------------------------------------------------------------
        // Test 13: Core 0 Reads Core 1's Line (Core 0 to_shared, Core 1 snoop_shared)
        // --------------------------------------------------------------------
        $display("\n--- Test 13: Core 0 Reads Core 1 Line (Core 0 SHARED, Core 1 Downgrade) ---");
        core0_read(32'h0000_4000, rdata);

        // --------------------------------------------------------------------
        // Test 14: Core 1 Upgrade Write (Core 1 FSM_UPGRADE, Core 0 snoop_invalid)
        // --------------------------------------------------------------------
        $display("\n--- Test 14: Core 1 Upgrade Write on SHARED Line (BUS_UPGR) ---");
        core1_write(32'h0000_4000, 32'h1111_4000);
        core1_read(32'h0000_4000, rdata);
        check_data("Core 1 Read 0x4000 after Upgrade", rdata, 32'h1111_4000);

        // --------------------------------------------------------------------
        // Test 15: Core 1 2-Way Conflict Miss & Eviction (Core 1 FSM_WRITE_BACK & BUS_WB)
        // --------------------------------------------------------------------
        $display("\n--- Test 15: Core 1 Conflict Eviction & Dirty Write-Back ---");
        core1_write(32'h0000_0160, 32'h1160_1160); // Set 6, Way 0 (Dirty)
        core1_write(32'h0000_0260, 32'h2260_2260); // Set 6, Way 1 (Dirty)
        // 3rd conflicting address forces eviction of Way 0 -> FSM_WRITE_BACK & BUS_WB
        core1_write(32'h0000_0360, 32'h3360_3360);
        core1_read(32'h0000_0360, rdata);
        check_data("Core 1 Read 3rd Conflicting Line", rdata, 32'h3360_3360);

        // --------------------------------------------------------------------
        // Test 16: Constrained-Random Multi-Core Stress Testing (Step 3)
        // --------------------------------------------------------------------
        $display("\n==================================================================");
        $display("   TEST 16: CONSTRAINED-RANDOM MULTI-CORE STRESS TEST (STEP 3)    ");
        $display("==================================================================");

        // --- Phase 16A: Concurrent Multi-Core Parallel Stress ---
        // Both cores issue randomized requests simultaneously via fork...join
        // Core 0 targets Set 2 & Set 5 conflicting lines + Word variations
        // Core 1 targets Set 6 & Set 7 conflicting lines + Word variations
        $display("\n--- Test 16A: Concurrent Multi-Core Parallel Traffic (Arbiter & Cache Conflicts) ---");
        fork
            begin : core0_random_thread
                cache_trans tr0 = new();
                logic [31:0] rdata0;
                for (int i = 0; i < 40; i++) begin
                    void'(tr0.randomize() with {
                        addr inside {
                            32'h0000_0120, 32'h0000_0124, 32'h0000_0128, 32'h0000_012C, // Set 2 Tag 1
                            32'h0000_0220, 32'h0000_0224, 32'h0000_0228, 32'h0000_022C, // Set 2 Tag 2
                            32'h0000_0320, 32'h0000_0324, 32'h0000_0328, 32'h0000_032C, // Set 2 Tag 3 (eviction)
                            32'h0000_0150, 32'h0000_0250, 32'h0000_0350, 32'h0000_0450  // Set 5 conflict
                        };
                    });
                    if (tr0.rw) begin
                        core0_write(tr0.addr, tr0.data, tr0.byte_en);
                    end else begin
                        core0_read(tr0.addr, rdata0, tr0.byte_en);
                    end
                end
            end

            begin : core1_random_thread
                cache_trans tr1 = new();
                logic [31:0] rdata1;
                for (int j = 0; j < 40; j++) begin
                    void'(tr1.randomize() with {
                        addr inside {
                            32'h0000_0170, 32'h0000_0174, 32'h0000_0178, 32'h0000_017C, // Set 7 Tag 1
                            32'h0000_0270, 32'h0000_0274, 32'h0000_0278, 32'h0000_027C, // Set 7 Tag 2
                            32'h0000_0370, 32'h0000_0374, 32'h0000_0378, 32'h0000_037C, // Set 7 Tag 3 (eviction)
                            32'h0000_0160, 32'h0000_0260, 32'h0000_0360, 32'h0000_0460  // Set 6 conflict
                        };
                    });
                    if (tr1.rw) begin
                        core1_write(tr1.addr, tr1.data, tr1.byte_en);
                    end else begin
                        core1_read(tr1.addr, rdata1, tr1.byte_en);
                    end
                end
            end
        join

        $display("\n[PASS] Test 16A Completed: 80 Parallel Transactions processed with 0 SVA & 0 Scoreboard errors.");

        // --- Phase 16B: Shared-Line MESI Coherence Ping-Pong Stress ---
        // Both cores randomly read & write to the SAME cache lines (forcing cross-snooping,
        // invalidations, dirty data forwarding, upgrades, and shared read hits).
        $display("\n--- Test 16B: Multi-Core Shared-Line Coherency Stress (MESI Invalidation/Forwarding) ---");
        begin
            cache_trans tr_shared = new();
            logic [31:0] rdata_s;
            for (int k = 0; k < 40; k++) begin
                bit select_core = $urandom_range(0, 1);
                void'(tr_shared.randomize() with {
                    addr inside {
                        32'h0000_5000, 32'h0000_5004, 32'h0000_5008, 32'h0000_500C, // Shared Block 1
                        32'h0000_6000, 32'h0000_6004, 32'h0000_6008, 32'h0000_600C  // Shared Block 2
                    };
                });
                if (select_core == 0) begin
                    if (tr_shared.rw) core0_write(tr_shared.addr, tr_shared.data, tr_shared.byte_en);
                    else              core0_read(tr_shared.addr, rdata_s, tr_shared.byte_en);
                end else begin
                    if (tr_shared.rw) core1_write(tr_shared.addr, tr_shared.data, tr_shared.byte_en);
                    else              core1_read(tr_shared.addr, rdata_s, tr_shared.byte_en);
                end
            end
        end
        $display("\n[PASS] Test 16B Completed: 40 Shared-Line Coherence Transactions verified with 0 errors.");

        // --------------------------------------------------------------------
        // Summary Report
        // --------------------------------------------------------------------
        #50;
        $display("\n==================================================================");
        $display("   DIRECTED TESTS:       TOTAL=%0d | PASSED=%0d | FAILED=%0d", test_count, pass_count, fail_count);
        $display("   GOLDEN SCOREBOARD:    CHECKS=%0d | PASSED=%0d | FAILED=%0d", scb_total_checks, scb_pass_count, scb_fail_count);
        $display("   FUNCTIONAL COVERAGE:  %0.2f%%", cov_inst.get_inst_coverage());
        $display("==================================================================");

        if (fail_count == 0 && scb_fail_count == 0) begin
            $display(">>> ALL TESTS & SCOREBOARD CHECKS PASSED WITH 0 ERRORS! <<<\n");
        end else begin
            $display(">>> VERIFICATION FAILED (Check errors above)! <<<\n");
        end

        $finish;
    end

endmodule
