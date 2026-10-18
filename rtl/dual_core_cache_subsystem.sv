// ============================================================================
// File: dual_core_cache_subsystem.sv
// Description: Top-Level Dual-Core Cache Subsystem (DUT) instantiating
//              Core 0 L1 Cache, Core 1 L1 Cache, and the Shared Bus Arbiter.
// ============================================================================

`include "cache_def.sv"
import cache_def::*;

module dual_core_cache_subsystem (
    input  logic                          clk,
    input  logic                          rst_n,

    // ========================================================================
    // 1. Core 0 CPU / Master Interface
    // ========================================================================
    input  logic                          core0_req_valid,
    input  logic                          core0_req_rw,       // 0 = READ, 1 = WRITE
    input  logic [ADDR_WIDTH-1:0]         core0_req_addr,
    input  logic [DATA_WIDTH-1:0]         core0_req_wdata,
    input  logic [3:0]                    core0_byte_en,
    output logic                          core0_ready,
    output logic [DATA_WIDTH-1:0]         core0_resp_rdata,
    output logic                          core0_resp_valid,

    // ========================================================================
    // 2. Core 1 CPU / Master Interface
    // ========================================================================
    input  logic                          core1_req_valid,
    input  logic                          core1_req_rw,       // 0 = READ, 1 = WRITE
    input  logic [ADDR_WIDTH-1:0]         core1_req_addr,
    input  logic [DATA_WIDTH-1:0]         core1_req_wdata,
    input  logic [3:0]                    core1_byte_en,
    output logic                          core1_ready,
    output logic [DATA_WIDTH-1:0]         core1_resp_rdata,
    output logic                          core1_resp_valid,

    // ========================================================================
    // 3. Main Memory / DRAM Interface (Connects to Memory Slave)
    // ========================================================================
    output logic                          mem_req_valid,
    output bus_cmd_t                      mem_req_cmd,
    output logic [ADDR_WIDTH-1:0]         mem_req_addr,
    output logic [LINE_WIDTH_BITS-1:0]    mem_req_wdata,
    input  logic                          mem_resp_valid,
    input  logic [LINE_WIDTH_BITS-1:0]    mem_resp_data
);

    // ------------------------------------------------------------------------
    // Internal Wires: Core 0 Bus Master & Snoop Port
    // ------------------------------------------------------------------------
    logic                       c0_bus_req;
    bus_cmd_t                   c0_bus_cmd;
    logic [ADDR_WIDTH-1:0]      c0_bus_addr;
    logic [LINE_WIDTH_BITS-1:0] c0_bus_wdata;
    logic                       c0_bus_gnt;
    logic                       c0_snoop_hit;
    logic                       c0_mem_resp_valid;
    logic [LINE_WIDTH_BITS-1:0] c0_mem_resp_data;

    logic                       c0_snoop_req_valid;
    bus_cmd_t                   c0_snoop_req_cmd;
    logic [ADDR_WIDTH-1:0]      c0_snoop_req_addr;
    logic                       c0_snoop_resp_hit;
    logic                       c0_snoop_resp_dirty;
    logic [LINE_WIDTH_BITS-1:0] c0_snoop_resp_data;

    // ------------------------------------------------------------------------
    // Internal Wires: Core 1 Bus Master & Snoop Port
    // ------------------------------------------------------------------------
    logic                       c1_bus_req;
    bus_cmd_t                   c1_bus_cmd;
    logic [ADDR_WIDTH-1:0]      c1_bus_addr;
    logic [LINE_WIDTH_BITS-1:0] c1_bus_wdata;
    logic                       c1_bus_gnt;
    logic                       c1_snoop_hit;
    logic                       c1_mem_resp_valid;
    logic [LINE_WIDTH_BITS-1:0] c1_mem_resp_data;

    logic                       c1_snoop_req_valid;
    bus_cmd_t                   c1_snoop_req_cmd;
    logic [ADDR_WIDTH-1:0]      c1_snoop_req_addr;
    logic                       c1_snoop_resp_hit;
    logic                       c1_snoop_resp_dirty;
    logic [LINE_WIDTH_BITS-1:0] c1_snoop_resp_data;

    // ------------------------------------------------------------------------
    // Instantiate Core 0 L1 Cache Controller
    // ------------------------------------------------------------------------
    cache_controller #(.CORE_ID(0)) core0_cache (
        // System Clock & Reset
        .clk              (clk),                 // [Input]  Clock source (from Top-level port clk)
        .rst_n            (rst_n),               // [Input]  Active-low asynchronous reset (from Top-level port rst_n)

        // CPU / Master Core 0 Interface
        .cpu_req_valid    (core0_req_valid),     // [Input]  Core 0 CPU request valid (from Top-level port core0_req_valid)
        .cpu_req_rw       (core0_req_rw),        // [Input]  Core 0 CPU read/write cmd: 0=Read, 1=Write (from Top-level port core0_req_rw)
        .cpu_req_addr     (core0_req_addr),      // [Input]  Core 0 CPU memory access address (from Top-level port core0_req_addr)
        .cpu_req_wdata    (core0_req_wdata),     // [Input]  Core 0 CPU write data word (from Top-level port core0_req_wdata)
        .cpu_byte_en      (core0_byte_en),       // [Input]  Core 0 CPU byte enables (from Top-level port core0_byte_en)
        .cpu_ready        (core0_ready),         // [Output] Core 0 CPU ready / hit handshake (to Top-level port core0_ready)
        .cpu_resp_rdata   (core0_resp_rdata),    // [Output] Core 0 CPU read response data word (to Top-level port core0_resp_rdata)
        .cpu_resp_valid   (core0_resp_valid),    // [Output] Core 0 CPU read response valid pulse (to Top-level port core0_resp_valid)

        // Memory / Interconnect Master Port (Core 0 requesting Bus / Memory)
        .bus_req_valid    (c0_bus_req),          // [Output] Core 0 bus transaction request (to Bus Arbiter: arbiter_inst.core0_bus_req)
        .bus_req_cmd      (c0_bus_cmd),          // [Output] Core 0 bus command (Rd/RdX/Upgr/WB) (to Bus Arbiter: arbiter_inst.core0_bus_cmd)
        .bus_req_addr     (c0_bus_addr),         // [Output] Core 0 bus access address (to Bus Arbiter: arbiter_inst.core0_bus_addr)
        .bus_req_wdata    (c0_bus_wdata),        // [Output] Core 0 write-back cache line data (to Bus Arbiter: arbiter_inst.core0_bus_wdata)
        .bus_req_gnt      (c0_bus_gnt),          // [Input]  Core 0 bus mastership grant (from Bus Arbiter: arbiter_inst.core0_bus_gnt)
        .mem_resp_valid   (c0_mem_resp_valid),   // [Input]  Refill data valid (from Bus Arbiter: arbiter_inst.core0_mem_resp_valid)
        .mem_resp_data    (c0_mem_resp_data),    // [Input]  Refill cache line data (from Bus Arbiter: arbiter_inst.core0_mem_resp_data)
        .bus_snoop_hit    (c0_snoop_hit),        // [Input]  Peer snoop hit indicator (from Bus Arbiter: arbiter_inst.core0_snoop_hit)

        // Snoop Slave Port (Core 0 snooping peer Core 1's bus requests)
        .snoop_req_valid  (c0_snoop_req_valid),  // [Input]  Peer snoop request valid (from Bus Arbiter: arbiter_inst.core0_snoop_req_valid)
        .snoop_req_cmd    (c0_snoop_req_cmd),    // [Input]  Peer snoop command type (from Bus Arbiter: arbiter_inst.core0_snoop_req_cmd)
        .snoop_req_addr   (c0_snoop_req_addr),   // [Input]  Peer snoop memory address (from Bus Arbiter: arbiter_inst.core0_snoop_req_addr)
        .snoop_resp_hit   (c0_snoop_resp_hit),   // [Output] Core 0 snoop hit status (to Bus Arbiter: arbiter_inst.core0_snoop_resp_hit)
        .snoop_resp_dirty (c0_snoop_resp_dirty), // [Output] Core 0 snoop Modified/dirty status (to Bus Arbiter: arbiter_inst.core0_snoop_resp_dirty)
        .snoop_resp_data  (c0_snoop_resp_data)   // [Output] Core 0 forwarded dirty line data (to Bus Arbiter: arbiter_inst.core0_snoop_resp_data)
    );

    // ------------------------------------------------------------------------
    // Instantiate Core 1 L1 Cache Controller
    // ------------------------------------------------------------------------
    cache_controller #(.CORE_ID(1)) core1_cache (
        // System Clock & Reset
        .clk              (clk),                 // [Input]  Clock source (from Top-level port clk)
        .rst_n            (rst_n),               // [Input]  Active-low asynchronous reset (from Top-level port rst_n)

        // CPU / Master Core 1 Interface
        .cpu_req_valid    (core1_req_valid),     // [Input]  Core 1 CPU request valid (from Top-level port core1_req_valid)
        .cpu_req_rw       (core1_req_rw),        // [Input]  Core 1 CPU read/write cmd: 0=Read, 1=Write (from Top-level port core1_req_rw)
        .cpu_req_addr     (core1_req_addr),      // [Input]  Core 1 CPU memory access address (from Top-level port core1_req_addr)
        .cpu_req_wdata    (core1_req_wdata),     // [Input]  Core 1 CPU write data word (from Top-level port core1_req_wdata)
        .cpu_byte_en      (core1_byte_en),       // [Input]  Core 1 CPU byte enables (from Top-level port core1_byte_en)
        .cpu_ready        (core1_ready),         // [Output] Core 1 CPU ready / hit handshake (to Top-level port core1_ready)
        .cpu_resp_rdata   (core1_resp_rdata),    // [Output] Core 1 CPU read response data word (to Top-level port core1_resp_rdata)
        .cpu_resp_valid   (core1_resp_valid),    // [Output] Core 1 CPU read response valid pulse (to Top-level port core1_resp_valid)

        // Memory / Interconnect Master Port (Core 1 requesting Bus / Memory)
        .bus_req_valid    (c1_bus_req),          // [Output] Core 1 bus transaction request (to Bus Arbiter: arbiter_inst.core1_bus_req)
        .bus_req_cmd      (c1_bus_cmd),          // [Output] Core 1 bus command (Rd/RdX/Upgr/WB) (to Bus Arbiter: arbiter_inst.core1_bus_cmd)
        .bus_req_addr     (c1_bus_addr),         // [Output] Core 1 bus access address (to Bus Arbiter: arbiter_inst.core1_bus_addr)
        .bus_req_wdata    (c1_bus_wdata),        // [Output] Core 1 write-back cache line data (to Bus Arbiter: arbiter_inst.core1_bus_wdata)
        .bus_req_gnt      (c1_bus_gnt),          // [Input]  Core 1 bus mastership grant (from Bus Arbiter: arbiter_inst.core1_bus_gnt)
        .mem_resp_valid   (c1_mem_resp_valid),   // [Input]  Refill data valid (from Bus Arbiter: arbiter_inst.core1_mem_resp_valid)
        .mem_resp_data    (c1_mem_resp_data),    // [Input]  Refill cache line data (from Bus Arbiter: arbiter_inst.core1_mem_resp_data)
        .bus_snoop_hit    (c1_snoop_hit),        // [Input]  Peer snoop hit indicator (from Bus Arbiter: arbiter_inst.core1_snoop_hit)

        // Snoop Slave Port (Core 1 snooping peer Core 0's bus requests)
        .snoop_req_valid  (c1_snoop_req_valid),  // [Input]  Peer snoop request valid (from Bus Arbiter: arbiter_inst.core1_snoop_req_valid)
        .snoop_req_cmd    (c1_snoop_req_cmd),    // [Input]  Peer snoop command type (from Bus Arbiter: arbiter_inst.core1_snoop_req_cmd)
        .snoop_req_addr   (c1_snoop_req_addr),   // [Input]  Peer snoop memory address (from Bus Arbiter: arbiter_inst.core1_snoop_req_addr)
        .snoop_resp_hit   (c1_snoop_resp_hit),   // [Output] Core 1 snoop hit status (to Bus Arbiter: arbiter_inst.core1_snoop_resp_hit)
        .snoop_resp_dirty (c1_snoop_resp_dirty), // [Output] Core 1 snoop Modified/dirty status (to Bus Arbiter: arbiter_inst.core1_snoop_resp_dirty)
        .snoop_resp_data  (c1_snoop_resp_data)   // [Output] Core 1 forwarded dirty line data (to Bus Arbiter: arbiter_inst.core1_snoop_resp_data)
    );

    // ------------------------------------------------------------------------
    // Instantiate Shared Bus Arbiter & Cross-Snooper
    // ------------------------------------------------------------------------
    bus_arbiter arbiter_inst (
        // System Clock & Reset
        .clk                   (clk),                    // [Input]  Clock source (from Top-level port clk)
        .rst_n                 (rst_n),                  // [Input]  Active-low asynchronous reset (from Top-level port rst_n)

        // Core 0 Bus Master Interface (Requests from Core 0 Cache)
        .core0_bus_req         (c0_bus_req),             // [Input]  Core 0 bus transaction request (from Core 0 Cache: core0_cache.bus_req_valid)
        .core0_bus_cmd         (c0_bus_cmd),             // [Input]  Core 0 bus command: Rd/RdX/Upgr/WB (from Core 0 Cache: core0_cache.bus_req_cmd)
        .core0_bus_addr        (c0_bus_addr),            // [Input]  Core 0 bus access address (from Core 0 Cache: core0_cache.bus_req_addr)
        .core0_bus_wdata       (c0_bus_wdata),           // [Input]  Core 0 write-back line data (from Core 0 Cache: core0_cache.bus_req_wdata)
        .core0_bus_gnt         (c0_bus_gnt),             // [Output] Core 0 bus grant acknowledgement (to Core 0 Cache: core0_cache.bus_req_gnt)
        .core0_snoop_hit       (c0_snoop_hit),           // [Output] Peer snoop hit status (to Core 0 Cache: core0_cache.bus_snoop_hit)
        .core0_mem_resp_valid  (c0_mem_resp_valid),      // [Output] Refill data valid to Core 0 (to Core 0 Cache: core0_cache.mem_resp_valid)
        .core0_mem_resp_data   (c0_mem_resp_data),       // [Output] Refill line data to Core 0 (to Core 0 Cache: core0_cache.mem_resp_data)

        // Core 0 Snoop Port (Arbiter snooping Core 0 on behalf of Core 1)
        .core0_snoop_req_valid (c0_snoop_req_valid),     // [Output] Inbound snoop request valid (to Core 0 Cache: core0_cache.snoop_req_valid)
        .core0_snoop_req_cmd   (c0_snoop_req_cmd),       // [Output] Inbound snoop command type (to Core 0 Cache: core0_cache.snoop_req_cmd)
        .core0_snoop_req_addr  (c0_snoop_req_addr),      // [Output] Inbound snoop target address (to Core 0 Cache: core0_cache.snoop_req_addr)
        .core0_snoop_resp_hit  (c0_snoop_resp_hit),      // [Input]  Core 0 snoop hit status (from Core 0 Cache: core0_cache.snoop_resp_hit)
        .core0_snoop_resp_dirty(c0_snoop_resp_dirty),    // [Input]  Core 0 Modified/dirty status (from Core 0 Cache: core0_cache.snoop_resp_dirty)
        .core0_snoop_resp_data (c0_snoop_resp_data),     // [Input]  Core 0 forwarded dirty line data (from Core 0 Cache: core0_cache.snoop_resp_data)

        // Core 1 Bus Master Interface (Requests from Core 1 Cache)
        .core1_bus_req         (c1_bus_req),             // [Input]  Core 1 bus transaction request (from Core 1 Cache: core1_cache.bus_req_valid)
        .core1_bus_cmd         (c1_bus_cmd),             // [Input]  Core 1 bus command: Rd/RdX/Upgr/WB (from Core 1 Cache: core1_cache.bus_req_cmd)
        .core1_bus_addr        (c1_bus_addr),            // [Input]  Core 1 bus access address (from Core 1 Cache: core1_cache.bus_req_addr)
        .core1_bus_wdata       (c1_bus_wdata),           // [Input]  Core 1 write-back line data (from Core 1 Cache: core1_cache.bus_req_wdata)
        .core1_bus_gnt         (c1_bus_gnt),             // [Output] Core 1 bus grant acknowledgement (to Core 1 Cache: core1_cache.bus_req_gnt)
        .core1_snoop_hit       (c1_snoop_hit),           // [Output] Peer snoop hit status (to Core 1 Cache: core1_cache.bus_snoop_hit)
        .core1_mem_resp_valid  (c1_mem_resp_valid),      // [Output] Refill data valid to Core 1 (to Core 1 Cache: core1_cache.mem_resp_valid)
        .core1_mem_resp_data   (c1_mem_resp_data),       // [Output] Refill line data to Core 1 (to Core 1 Cache: core1_cache.mem_resp_data)

        // Core 1 Snoop Port (Arbiter snooping Core 1 on behalf of Core 0)
        .core1_snoop_req_valid (c1_snoop_req_valid),     // [Output] Inbound snoop request valid (to Core 1 Cache: core1_cache.snoop_req_valid)
        .core1_snoop_req_cmd   (c1_snoop_req_cmd),       // [Output] Inbound snoop command type (to Core 1 Cache: core1_cache.snoop_req_cmd)
        .core1_snoop_req_addr  (c1_snoop_req_addr),      // [Output] Inbound snoop target address (to Core 1 Cache: core1_cache.snoop_req_addr)
        .core1_snoop_resp_hit  (c1_snoop_resp_hit),      // [Input]  Core 1 snoop hit status (from Core 1 Cache: core1_cache.snoop_resp_hit)
        .core1_snoop_resp_dirty(c1_snoop_resp_dirty),    // [Input]  Core 1 Modified/dirty status (from Core 1 Cache: core1_cache.snoop_resp_dirty)
        .core1_snoop_resp_data (c1_snoop_resp_data),     // [Input]  Core 1 forwarded dirty line data (from Core 1 Cache: core1_cache.snoop_resp_data)

        // Main Memory / DRAM Interface (Downstream Memory Controller)
        .mem_req_valid         (mem_req_valid),          // [Output] Memory transaction request valid (to Top-level port mem_req_valid)
        .mem_req_cmd           (mem_req_cmd),            // [Output] Memory transaction command (to Top-level port mem_req_cmd)
        .mem_req_addr          (mem_req_addr),           // [Output] Memory access block address (to Top-level port mem_req_addr)
        .mem_req_wdata         (mem_req_wdata),          // [Output] Memory write-back line data (to Top-level port mem_req_wdata)
        .mem_resp_valid        (mem_resp_valid),         // [Input]  Memory response valid (from Top-level port mem_resp_valid)
        .mem_resp_data         (mem_resp_data)           // [Input]  Memory response line data (from Top-level port mem_resp_data)
    );

endmodule
