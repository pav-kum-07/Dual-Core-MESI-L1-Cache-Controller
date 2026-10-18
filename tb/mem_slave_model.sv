// ============================================================================
// File: mem_slave_model.sv
// Description: Behavioral Non-UVM Main Memory / DRAM Slave Model for the
//              Dual-Core Cache Controller Subsystem.
//
// Features:
// 1. Sparse Associative Storage: Allocates 128-bit cache lines on-demand.
// 2. Deterministic Fallback: Unwritten lines return deterministic data
//    (e.g., word-based pattern derived from address) instead of Xs.
// 3. Configurable Latency: Simulates realistic multi-cycle DRAM access delay.
// 4. Backdoor Access: Helper tasks for testbench initialization & verification.
// ============================================================================

`include "../rtl/cache_def.sv"
import cache_def::*;

module mem_slave_model #(
    parameter int MEM_LATENCY_CYCLES = 3,           // Simulated DRAM latency
    parameter bit VERBOSE            = 1'b0          // 1 = Display transaction logs
)(
    input  logic                          clk,
    input  logic                          rst_n,

    // Memory Bus Interface (Connects directly to dual_core_cache_subsystem)
    input  logic                          mem_req_valid,
    input  bus_cmd_t                      mem_req_cmd,
    input  logic [ADDR_WIDTH-1:0]         mem_req_addr,
    input  logic [LINE_WIDTH_BITS-1:0]    mem_req_wdata,
    output logic                          mem_resp_valid,
    output logic [LINE_WIDTH_BITS-1:0]    mem_resp_data
);

    // ------------------------------------------------------------------------
    // Sparse Associative Memory Storage (Indexed by 16-byte Block Address)
    // ------------------------------------------------------------------------
    // Key: Block address (addr[31:4]), Value: 128-bit cache line (4 words)
    logic [LINE_WIDTH_BITS-1:0] mem_storage [logic [ADDR_WIDTH-1:4]];

    // ------------------------------------------------------------------------
    // State Machine / Request Pipeline for Memory Latency
    // ------------------------------------------------------------------------
    typedef enum logic [1:0] {
        MEM_IDLE,
        MEM_BUSY,
        MEM_RESP
    } mem_fsm_state_t;

    mem_fsm_state_t state_q;
    int unsigned    latency_cnt_q;
    
    // Latched request attributes
    bus_cmd_t                   latched_cmd;
    logic [ADDR_WIDTH-1:0]      latched_addr;
    logic [LINE_WIDTH_BITS-1:0] latched_wdata;
    logic [LINE_WIDTH_BITS-1:0] resp_data_q;

    // Helper: Generate deterministic default data for uninitialized addresses
    function automatic logic [LINE_WIDTH_BITS-1:0] get_default_data(input logic [ADDR_WIDTH-1:0] byte_addr);
        logic [31:0] base_addr;
        base_addr = {byte_addr[31:4], 4'b0000};
        // Word 0 = base_addr, Word 1 = base_addr + 4, etc.
        return {base_addr + 32'd12, base_addr + 32'd8, base_addr + 32'd4, base_addr};
    endfunction

    // ------------------------------------------------------------------------
    // Synchronous Memory Controller
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q        <= MEM_IDLE;
            latency_cnt_q  <= 0;
            mem_resp_valid <= 1'b0;
            mem_resp_data  <= '0;
            resp_data_q    <= '0;
        end else begin
            case (state_q)
                // ------------------------------------------------------------
                // State: MEM_IDLE
                // Description: Waits for a valid memory bus command from the
                //              Bus Arbiter (mem_req_valid = 1).
                // ------------------------------------------------------------
                MEM_IDLE: begin
                    mem_resp_valid <= 1'b0; // Default: no response active

                    if (mem_req_valid && mem_req_cmd != BUS_IDLE) begin
                        // Latch request parameters into internal registers so that
                        // the bus lines can be freed or held stable during latency delay
                        latched_cmd   <= mem_req_cmd;
                        latched_addr  <= mem_req_addr;
                        latched_wdata <= mem_req_wdata;

                        if (VERBOSE) begin
                            $display("[MEM_SLAVE @ %0t ps] Received Req: CMD=%s ADDR=0x%08h",
                                     $time, mem_req_cmd.name(), mem_req_addr);
                        end

                        if (MEM_LATENCY_CYCLES == 0) begin
                            // ------------------------------------------------
                            // Zero-Delay Mode: Serve request combinationally/
                            // immediately in the next clock edge without stall
                            // ------------------------------------------------
                            if (mem_req_cmd == BUS_WB) begin
                                // Write-Back: update associative DRAM storage with the 128-bit dirty block
                                mem_storage[mem_req_addr[ADDR_WIDTH-1:4]] = mem_req_wdata;
                                mem_resp_valid <= 1'b1; // Acknowledge completion
                                mem_resp_data  <= '0;   // No data payload needed for write ack
                                state_q        <= MEM_IDLE;
                            end else begin
                                // Read / ReadX: supply 128-bit cache line immediately
                                mem_resp_valid <= 1'b1;
                                if (mem_storage.exists(mem_req_addr[ADDR_WIDTH-1:4])) begin
                                    mem_resp_data <= mem_storage[mem_req_addr[ADDR_WIDTH-1:4]];
                                end else begin
                                    mem_resp_data <= get_default_data(mem_req_addr);
                                end
                                state_q <= MEM_IDLE;
                            end
                        end else begin
                            // ------------------------------------------------
                            // Pipelined / Realistic Latency Mode:
                            // Initialize latency counter to 1 and transition to
                            // MEM_BUSY to simulate off-chip DRAM access cycles.
                            // ------------------------------------------------
                            latency_cnt_q <= 1;
                            state_q       <= MEM_BUSY;
                        end
                    end
                end

                // ------------------------------------------------------------
                // State: MEM_BUSY
                // Description: Simulates multi-cycle DRAM access delay (e.g. CAS
                //              latency, tRCD, row/column buffer lookup).
                //              Increments latency counter every clock cycle until
                //              MEM_LATENCY_CYCLES threshold is met.
                // ------------------------------------------------------------
                MEM_BUSY: begin
                    if (latency_cnt_q >= MEM_LATENCY_CYCLES) begin
                        // Target memory access latency elapsed:
                        // Move to response state and assert mem_resp_valid
                        state_q        <= MEM_RESP;
                        mem_resp_valid <= 1'b1;

                        if (latched_cmd == BUS_WB) begin
                            // ------------------------------------------------
                            // Handle Write-Back (BUS_WB):
                            // Store the 16-byte (128-bit) evicted dirty line
                            // into memory storage at the 16-byte aligned index.
                            // ------------------------------------------------
                            mem_storage[latched_addr[ADDR_WIDTH-1:4]] = latched_wdata;
                            mem_resp_data <= '0; // DRAM write acknowledgement requires no read data
                            if (VERBOSE) begin
                                $display("[MEM_SLAVE @ %0t ps] BUS_WB written to 0x%08h: DATA=0x%032h",
                                         $time, latched_addr, latched_wdata);
                            end
                        end else begin
                            // ------------------------------------------------
                            // Handle Read / Read-with-Intent-to-Modify (BUS_RD / BUS_RDX):
                            // 1. Check if the block was previously written or initialized.
                            // 2. If present, return stored 128-bit data.
                            // 3. If first-time access, return deterministic default test pattern.
                            // ------------------------------------------------
                            if (mem_storage.exists(latched_addr[ADDR_WIDTH-1:4])) begin
                                mem_resp_data <= mem_storage[latched_addr[ADDR_WIDTH-1:4]];
                            end else begin
                                mem_resp_data <= get_default_data(latched_addr);
                            end

                            if (VERBOSE) begin
                                $display("[MEM_SLAVE @ %0t ps] Supplying Line for 0x%08h", $time, latched_addr);
                            end
                        end
                    end else begin
                        // Still waiting: keep incrementing latency cycle counter
                        // Cache controller remains stalled waiting for DRAM
                        latency_cnt_q <= latency_cnt_q + 1;
                    end
                end

                // ------------------------------------------------------------
                // State: MEM_RESP
                // Description: Enforces a clean 1-cycle active pulse on
                //              mem_resp_valid, then clears signals and returns
                //              to MEM_IDLE ready for the next bus command.
                // ------------------------------------------------------------
                MEM_RESP: begin
                    // De-assert response pulse after exactly 1 clock cycle
                    mem_resp_valid <= 1'b0;
                    mem_resp_data  <= '0;
                    state_q        <= MEM_IDLE;
                end

                default: state_q <= MEM_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // Backdoor Testbench API Tasks
    // ------------------------------------------------------------------------
    // Write full 128-bit line directly into memory
    task automatic backdoor_write_line(
        input logic [ADDR_WIDTH-1:0]      byte_addr,
        input logic [LINE_WIDTH_BITS-1:0] line_data
    );
        mem_storage[byte_addr[ADDR_WIDTH-1:4]] = line_data;
    endtask

    // Read full 128-bit line directly from memory
    task automatic backdoor_read_line(
        input  logic [ADDR_WIDTH-1:0]      byte_addr,
        output logic [LINE_WIDTH_BITS-1:0] line_data
    );
        if (mem_storage.exists(byte_addr[ADDR_WIDTH-1:4])) begin
            line_data = mem_storage[byte_addr[ADDR_WIDTH-1:4]];
        end else begin
            line_data = get_default_data(byte_addr);
        end
    endtask

    // Check if an address block was ever written to DRAM
    function automatic bit is_allocated(input logic [ADDR_WIDTH-1:0] byte_addr);
        return mem_storage.exists(byte_addr[ADDR_WIDTH-1:4]);
    endfunction

    // Clear all memory storage (e.g., between tests)
    task automatic clear_memory();
        mem_storage.delete();
    endtask

endmodule

