# Dual-Core 2-Way Set-Associative Cache Subsystem with MESI Coherence Protocol
## Comprehensive Architectural Design, Hardware Implementation & Verification Report

---

## 1. Executive Summary & Project Motivation

### 1.1 Background & The "Memory Wall"
In modern computing systems, processing cores operate at clock frequencies orders of magnitude higher than off-chip Dynamic Random Access Memory (DRAM). A typical CPU executes an instruction in $\sim 1\text{ ns}$, whereas an access to off-chip DRAM requires $\sim 50\text{--}100\text{ ns}$ (tens to hundreds of clock cycles). Without intermediate high-speed memory, the processor would spend upwards of 95% of its execution cycles stalled.

To bridge this gap, hardware designers implement a **Cache Hierarchy** using on-chip Static RAM (SRAM) that exploits two fundamental principles of workload locality:
1. **Temporal Locality:** Memory locations accessed recently are likely to be accessed again in the near future (e.g., loop counters, stack variables).
2. **Spatial Locality:** Memory locations adjacent to recently accessed addresses are likely to be accessed soon (e.g., sequential instruction execution, array traversals).

### 1.2 The Multi-Core Coherence Challenge
When multiple processing cores execute concurrently on a shared physical address space, each core possesses its own private L1 cache. This architecture introduces the **Cache Coherence Problem**:
* If Core 0 reads variable `x = 5`, it caches `x` in its local L1.
* If Core 1 reads `x = 5`, it also caches `x` in its local L1.
* If Core 0 subsequently writes `x = 10` locally, Core 1's local copy becomes **stale**. If Core 1 executes based on its cached `x = 5`, computational errors or system crashes occur.

To maintain a globally consistent view of memory, hardware must implement a **Coherence Protocol**. This project designs, specifies, and documents a **Dual-Core 2-Way Set-Associative L1 Cache Subsystem** implementing the hardware **MESI (Modified, Exclusive, Shared, Invalid) Snooping Protocol** over a shared split-transaction bus.

---

## 2. Architectural Specifications

| Parameter | Specification | Engineering Rationale |
| :--- | :--- | :--- |
| **Target Architecture** | 32-bit RISC-V / MIPS compatible | Standard 32-bit byte-addressable address space ($2^{32} = 4\text{ GB}$). |
| **Total Cache Capacity** | **512 Bytes** per core (1 KB total L1) | Parameterized for rapid simulation turnover, fast corner-case triggering, and zero-overhead scaling to 32 KB+. |
| **Associativity** | **2-Way Set-Associative** | Balances low conflict-miss rate with minimal hardware comparator overhead and low hit latency. |
| **Line / Block Size** | **16 Bytes (4 words = 128 bits)** | Maximizes spatial locality while allowing 4-word burst transfers over memory buses. |
| **Number of Sets** | **16 Sets (Rows 0 to 15)** | $\text{Capacity} / (\text{Line Size} \times \text{Ways}) = 512 / (16 \times 2) = 16$. |
| **Write Policy** | **Write-Back + Write-Allocate** | Minimizes memory bus congestion. Modifies data in fast SRAM and only writes to DRAM on dirty eviction. |
| **Replacement Policy** | **1-Bit True LRU (Least Recently Used)** | Exactly 1 bit per set yields perfect true LRU tracking between 2 candidate ways. |
| **Coherence Protocol** | **MESI Snooping Protocol** | 2 bits per way (`M`, `E`, `S`, `I`) to maintain coherence over a shared broadcast bus. |

---

## 3. 32-Bit Address Bit Decomposition & Calculations

Every memory address issued by a core is a 32-bit byte address (`addr[31:0]`). Hardware circuits partition this address into three distinct fields:

```
Bit:   31..........................8   7.........4   3.....2   1.....0
      +-----------------------------+-------------+---------+---------+
Name: |             TAG             |  SET INDEX  | WORD SEL| BYTE OFF|
Width:|           24 bits           |   4 bits    | 2 bits  | 2 bits  |
      +-----------------------------+-------------+---------+---------+
      \____________________________/ \___________/ \_________________/
                 Tag                   Set Index      Block Offset
               [31:8]                    [7:4]           [3:0]
```

### 3.1 Mathematical Derivation of Field Widths

#### 1. Block Offset (`addr[3:0]`, 4 bits)
* A cache line is **16 Bytes**. To address any individual byte within a 16-byte block:
  $$\text{Offset Width} = \log_2(\text{Line Size in Bytes}) = \log_2(16) = 4\text{ bits}$$
* Subdivided into:
  * **`addr[1:0]` (Byte Offset, 2 bits):** Addresses bytes 0, 1, 2, or 3 within a 32-bit word ($\log_2(4) = 2\text{ bits}$).
  * **`addr[3:2]` (Word Select, 2 bits):** Selects Word 0, Word 1, Word 2, or Word 3 from the 128-bit cache line ($16\text{ bytes} / 4\text{ bytes per word} = 4\text{ words} \implies \log_2(4) = 2\text{ bits}$).

#### 2. Set Index (`addr[7:4]`, 4 bits)
* Total capacity per core = 512 Bytes. Line size = 16 Bytes. Associativity = 2 Ways.
  $$\text{Number of Sets } (S) = \frac{\text{Total Capacity}}{\text{Line Size} \times \text{Number of Ways}} = \frac{512}{16 \times 2} = 16\text{ Sets}$$
  $$\text{Set Index Width} = \log_2(S) = \log_2(16) = 4\text{ bits}$$
* Used directly by the SRAM row decoder to activate Set 0 through Set 15.

#### 3. Tag (`addr[31:8]`, 24 bits)
* The remaining upper address bits uniquely identify the memory block:
  $$\text{Tag Width} = \text{Total Address Width} - \text{Set Index Width} - \text{Offset Width} = 32 - 4 - 4 = 24\text{ bits}$$

---

## 4. Physical Storage Organization: What Is (and Isn't) Stored

A fundamental hardware design concept is the distinction between **stored state bits** (flip-flops / SRAM cells) and **decoded addresses**.

```
                       WAY 0                                        WAY 1                       LRU
      +------------+-----------+--------------------+   +------------+-----------+--------------------+   +---+
      | MESI State | Tag Array |     Data Array     |   | MESI State | Tag Array |     Data Array     |   |LRU|
      |   [1:0]    |  [23:0]   | [127:0] (16 Bytes) |   |   [1:0]    |  [23:0]   | [127:0] (16 Bytes) |   |bit|
      +------------+-----------+--------------------+   +------------+-----------+--------------------+   +---+
Set 0 |    M/E/S/I |  24 bits  | W3 | W2 | W1 | W0  |   |    M/E/S/I |  24 bits  | W3 | W2 | W1 | W0  |   | 0 |
Set 1 |    M/E/S/I |  24 bits  | W3 | W2 | W1 | W0  |   |    M/E/S/I |  24 bits  | W3 | W2 | W1 | W0  |   | 1 |
  :   |       :    |     :     |         :          |   |       :    |     :     |         :          |   | : |
Set 15|    M/E/S/I |  24 bits  | W3 | W2 | W1 | W0  |   |    M/E/S/I |  24 bits  | W3 | W2 | W1 | W0  |   | 0 |
      +------------+-----------+--------------------+   +------------+-----------+--------------------+   +---+
```

### 4.1 Stored Elements:
1. **Data Array:** 128 bits per way $\times$ 2 ways $\times$ 16 sets = 4,096 bits (512 Bytes).
2. **Tag Array:** 24 bits per way $\times$ 2 ways $\times$ 16 sets = 768 bits.
3. **MESI State Array:** 2 bits per way $\times$ 2 ways $\times$ 16 sets = 64 bits.
4. **LRU Array:** 1 bit per set $\times$ 16 sets = 16 bits.
* **Total Physical Storage Bits:** $4096 + 768 + 64 + 16 = \mathbf{4,944\text{ bits}}$ per core.

### 4.2 Why the "Set" is NOT Stored:
The "Set" is **not a bit stored in memory**. It is the **physical row index**. The 4-bit `addr[7:4]` is routed into a **4-to-16 Binary Decoder**. When `addr[7:4] == 4'b0010`, the decoder asserts Wordline 2 (`wl[2] = 1`), enabling the access transistors for Row 2 only. Just like an array index in C (`array[2]`), the index indicates *where* the data is stored, not a value inside the storage cell.

---

## 5. Hardware Datapath & Parallel Evaluation

When a 32-bit address arrives from the CPU, the cache executes parallel evaluation in combinatorial logic:

```
                            CPU Address [31:0]
               +--------------------+-----------+--------+
               |     Tag [31:8]     | Set [7:4] | Offset |
               +--------------------+-----------+--------+
                         |                |          |
                         |                |          | [3:2] (Word Select)
                         |                v          |
                         |          +------------+   |
                         |          | Row Decode |   |
                         |          +------------+   |
                         |                |          |
                         |     +----------+----------+
                         |     |                     |
                         v     v                     v
                +---------------------+       +---------------------+
                |     WAY 0 SRAM      |       |     WAY 1 SRAM      |
                |  Tag0  | Data0      |       |  Tag1  | Data1      |
                | [23:0] | [127:0]    |       | [23:0] | [127:0]    |
                +---------------------+       +---------------------+
                    |         |                   |         |
                    | Tag0    | Data0             | Tag1    | Data1
                    v         |                   v         |
     Tag [31:8] -> [ == ]     |    Tag [31:8] -> [ == ]     |
                    |         |                   |         |
           hit_way0 |         |          hit_way1 |         |
                    |         |                   |         |
                    |         +---------+---------+         |
                    |                   |                   |
                    |                   v                   |
                    |          +-----------------+          |
                    +--------> | Way Select Mux  | <--------+
                               +-----------------+
                                        |
                                        v Hit Data Line [127:0]
                               +-----------------+
               Word Sel [3:2] -+-> Word MUX      |
                               +-----------------+
                                        |
                                        v
                                 Read Data [31:0] ---> (To CPU)
```

### 5.1 Hit/Miss Boolean Decision Equation
A Cache Hit requires both **Tag Equality** AND a **Non-Invalid State**:
$$\text{hit\_way0} = (\text{cpu\_tag} == \text{tag\_way0}) \land (\text{state\_way0} \neq \text{INVALID})$$
$$\text{hit\_way1} = (\text{cpu\_tag} == \text{tag\_way1}) \land (\text{state\_way1} \neq \text{INVALID})$$
$$\text{cache\_hit} = \text{hit\_way0} \lor \text{hit\_way1}$$
$$\text{cache\_miss} = \neg\text{cache\_hit}$$

* **Safety Invariant:** A valid tag can **never** match both Way 0 and Way 1 simultaneously. This is enforced with an SVA assertion:
  ```systemverilog
  assert property (@(posedge clk) !(hit_way0 && hit_way1));
  ```

---

## 6. True LRU Replacement Policy (1 Bit Per Set)

In a 2-way set-associative cache, replacement decisions are binary (either Way 0 or Way 1). Therefore, **exactly 1 bit per set** achieves mathematically perfect True LRU tracking.

### 6.1 Direct Victim Pointer Convention
We define `lru_bit` to point directly to the candidate victim:
* **`lru_bit == 1'b0`** $\implies$ **Way 0 is the older line (replace Way 0).**
* **`lru_bit == 1'b1`** $\implies$ **Way 1 is the older line (replace Way 1).**

### 6.2 The Seesaw Update Rule
Whenever an access (Hit or Line Refill) touches a way, the LRU pointer updates to point to the **opposite** way:
$$\text{lru\_ram}[\text{set\_index}] \Leftarrow \sim\text{accessed\_way}$$
* Access Way 0 $\implies \text{lru\_ram} \Leftarrow 1$ (Way 1 is the next victim).
* Access Way 1 $\implies \text{lru\_ram} \Leftarrow 0$ (Way 0 is the next victim).

---

## 7. The MESI Protocol Detailed Specification

### 7.1 State Definitions
Every cache line maintains a 2-bit state tag:
1. **Modified (M):** Line is dirty and present **only** in this cache. Local copy is newer than Main Memory. Exclusive read/write access permitted without bus transactions.
2. **Exclusive (E):** Line is clean and present **only** in this cache. Local copy matches Main Memory. Exclusive read/write access permitted (write silently upgrades $E \rightarrow M$).
3. **Shared (S):** Line is clean and may be present in **multiple** caches. Local copy matches Main Memory. Read access permitted. Write access requires a bus invalidation (`BUS_UPGR`).
4. **Invalid (I):** Line contains no valid data (empty/stale). All accesses result in a cache miss.

### 7.2 State Transition Matrix (Local Processor Actions)

| Current State | Local Read (`PrRd`) | Local Write (`PrWr`) | Bus Action Initiated |
| :---: | :---: | :---: | :---: |
| **`I`** | If `snoop_hit == 0` $\rightarrow$ **`E`**<br>If `snoop_hit == 1` $\rightarrow$ **`S`** | $\rightarrow$ **`M`** | `BUS_RD` (for read)<br>`BUS_RDX` (for write) |
| **`S`** | $\rightarrow$ **`S`** (Hit, 1 cycle) | $\rightarrow$ **`M`** (Write Hit) | `BUS_UPGR` (Invalidate peers) |
| **`E`** | $\rightarrow$ **`E`** (Hit, 1 cycle) | $\rightarrow$ **`M`** (Silent Hit, 1 cycle) | None (Zero bus traffic!) |
| **`M`** | $\rightarrow$ **`M`** (Hit, 1 cycle) | $\rightarrow$ **`M`** (Silent Hit, 1 cycle) | None (Zero bus traffic!) |

### 7.3 State Transition Matrix (Peer Snooping Actions)

| Current State | Peer Read (`BUS_RD`) | Peer Write (`BUS_RDX` or `BUS_UPGR`) | Hardware Response |
| :---: | :---: | :---: | :--- |
| **`M`** | $\rightarrow$ **`S`** | $\rightarrow$ **`I`** | Assert `snoop_resp_dirty = 1`, supply latest line to bus/memory. |
| **`E`** | $\rightarrow$ **`S`** | $\rightarrow$ **`I`** | Assert `snoop_resp_hit = 1`, downgrade/invalidate. |
| **`S`** | $\rightarrow$ **`S`** | $\rightarrow$ **`I`** | Assert `snoop_resp_hit = 1`, invalidate copy. |
| **`I`** | $\rightarrow$ **`I`** | $\rightarrow$ **`I`** | No action (`snoop_resp_hit = 0`). |

### 7.4 Shared Bus Commands (`bus_cmd_t`): How and When Each Operates

| Bus Command | When It Operates (Trigger) | How It Operates (Hardware Action) | Peer Snooper Action | Data Transferred |
| :--- | :--- | :--- | :--- | :--- |
| **`BUS_IDLE`** (`3'b000`) | No active memory or coherence transaction on the bus. | Bus arbiter is idle; no snoop lookups or memory accesses are performed. | Idle (no tag lookup). | None |
| **`BUS_RD`** (`3'b001`) | Initiated during `FSM_ALLOCATE` when a **CPU Read Miss** occurs. | Cache Controller requests the 16-byte block from Main Memory (or dirty peer). | Peers holding line in `MODIFIED` or `EXCLUSIVE` downgrade to `SHARED`. Dirty peer supplies data. | 16 Bytes (DRAM/Peer $\rightarrow$ Cache) |
| **`BUS_RDX`** (`3'b010`) | Initiated during `FSM_ALLOCATE` when a **CPU Write Miss** occurs. | Cache Controller fetches the 16-byte block from DRAM and asserts intent to modify. | **All peers** holding the block (`M`, `E`, `S`) must invalidate $\rightarrow$ transition to `INVALID`. | 16 Bytes (DRAM/Peer $\rightarrow$ Cache) |
| **`BUS_UPGR`** (`3'b011`) | Initiated during `FSM_UPGRADE` when a **CPU Write Hit on `SHARED`** occurs. | Line data is already present in cache. Broadcasts invalidation signal to acquire exclusive ownership without data payload. | Peers holding line in `SHARED` invalidate $\rightarrow$ transition to `INVALID`. | None (Address & Command only) |
| **`BUS_WB`** (`3'b100`) | Initiated during `FSM_WRITE_BACK` when an eviction selects a **`MODIFIED` (dirty)** victim. | Cache Controller transmits the 16-byte dirty block to Main Memory before allocating a new line. | Ignored by peers (handled by DRAM memory controller). | 16 Bytes (Cache $\rightarrow$ Main Memory) |

---

## 8. Detailed Operation Flows

### 8.1 Read Hit Flow (1 Clock Cycle)
1. CPU drives `cpu_req_valid = 1`, `cpu_req_rw = 0`, `cpu_req_addr`.
2. Combinatorial logic decodes `cpu_index` and checks tags for Way 0 and Way 1.
3. Tag matches on Way $W$ with state $\in \{E, S, M\}$.
4. `cache_hit = 1`. Way Select Mux selects Way $W$'s 128-bit line.
5. Word Select Mux extracts 32-bit word using `addr[3:2]`.
6. Cache drives `cpu_resp_rdata`, asserts `cpu_ready = 1`, updates LRU ($\text{lru} \Leftarrow \sim W$). Total latency: **1 cycle**.

### 8.2 Write Hit Flow
* **Case 1: Hit on `M` or `E`:**
  * Core holds exclusive ownership.
  * Overwrites word in Data Array with `cpu_req_wdata` using `cpu_byte_en`.
  * State becomes/stays **`M`**. Updates LRU. Asserts `cpu_ready = 1`. Total latency: **1 cycle (Zero bus overhead)**.
* **Case 2: Hit on `S`:**
  * Core does not hold exclusive ownership.
  * Stalls CPU (`cpu_ready = 0`).
  * FSM enters `FSM_UPGRADE` and asserts `BUS_UPGR` on shared bus.
  * Peer core snoops and drops its copy to `INVALID`.
  * Upon grant, local line updates to `MODIFIED`, writes word, asserts `cpu_ready = 1`.

### 8.3 Miss & Eviction Flow: How and When Each State Operates

#### Important Architectural Clarifications:
1. **Does the CPU read directly from Main Memory on a Read Miss?**
   * **No.** The CPU never accesses memory or the interconnect directly. The CPU stalls (`cpu_ready = 0`). The **Cache Controller** orchestrates the bus transaction, receives the 16-byte line, installs it in SRAM, and multiplexes out the requested 32-bit word to the CPU via `cpu_resp_rdata`.
2. **What is the state of the bus during a Miss (`BUS_WB` vs `BUS_RD`)?**
   * **Clean Victim:** Directly enters `FSM_ALLOCATE` and drives **`BUS_RD`** (or `BUS_RDX`).
   * **Dirty Victim (`MODIFIED`):** A **two-step sequence** is required:
     * **Step 1:** Controller enters `FSM_WRITE_BACK` and drives **`BUS_WB`** to write the 16-byte dirty block to DRAM.
     * **Step 2:** Upon completion (`mem_resp_valid`), controller transitions to `FSM_ALLOCATE` and drives **`BUS_RD`** (read miss) or **`BUS_RDX`** (write miss).

#### Sequence of Events:
```
CPU Miss Occurs
      │
      ▼
Check Victim Way State
      │
      ├─── If Victim is MODIFIED (Dirty) ────┐
      │                                       ▼
      │                                 FSM_WRITE_BACK
      │                                 Bus Command: BUS_WB
      │                                 (Writes 16B dirty line to DRAM)
      │                                       │
      │                                       ▼ (mem_resp_valid)
      └─── If Victim is Clean / Invalid ─────► FSM_ALLOCATE
                                              Bus Command: BUS_RD (or BUS_RDX)
                                              (Fetches 16B new line from DRAM)
                                                      │
                                                      ▼ (mem_resp_valid)
                                              Install line into Data/Tag SRAM
                                              Extract 32-bit word -> cpu_resp_rdata
                                              Assert cpu_ready = 1
                                                      │
                                                      ▼
                                                   FSM_IDLE
```

1. CPU issues request $\rightarrow$ both comparators miss (`cache_hit = 0`).
2. Cache stalls CPU (`cpu_ready = 0`).
3. **Victim Selection:**
   * Checks if Way 0 is `INVALID` $\rightarrow$ victim is Way 0.
   * Else if Way 1 is `INVALID` $\rightarrow$ victim is Way 1.
   * Else both valid $\rightarrow$ victim is `lru_victim`.
4. **Victim Eviction Check:**
   * **If victim state is `M` (Modified / Dirty):** FSM enters `FSM_WRITE_BACK`, transmits victim's 16 bytes to DRAM over `BUS_WB`.
   * **If victim state is `E`, `S`, or `I` (Clean):** Discards victim immediately; skips `FSM_WRITE_BACK`.
5. **Line Refill (`FSM_ALLOCATE`):**
   * Issues `BUS_RD` (for read) or `BUS_RDX` (for write) to Main Memory.
   * Main memory returns 16-byte line.
   * Data Array writes full 128-bit line; Tag Array updates tag.
   * MESI state set to `E`/`S` (read) or `M` (write).
   * Updates LRU. Drives data to CPU and releases stall (`cpu_ready = 1`).

---

## 9. Hardware RTL Module Architecture

The subsystem is implemented as 7 modular, parameterized SystemVerilog files. The following block diagrams detail the complete pin-level and architectural interconnects.

### 9.1 Level 1: Multi-Core System Block Diagram (`dual_core_cache_subsystem.sv`)

This diagram shows how **Core 0**, **Core 1**, the **Shared Bus Arbiter**, and **Main Memory** are interconnected:

```
    [ CORE 0 CPU / BFM ]                                       [ CORE 1 CPU / BFM ]
   (req_valid, rw, addr,                                      (req_valid, rw, addr,
     wdata, byte_en)                                            wdata, byte_en)
          |        ^                                                 |        ^
          v        | (ready, resp_rdata)                             v        | (ready, resp_rdata)
+------------------------------------+             +------------------------------------+
|                                    |             |                                    |
|      CORE 0 CACHE CONTROLLER       |             |      CORE 1 CACHE CONTROLLER       |
|       (cache_controller.sv)        |             |       (cache_controller.sv)        |
|                                    |             |                                    |
|  Master Port         Snoop Port    |             |  Master Port         Snoop Port    |
| (bus_req, cmd,     (snoop_req,     |             | (bus_req, cmd,     (snoop_req,     |
|  addr, wdata)       hit, dirty,    |             |  addr, wdata)       hit, dirty,    |
|                     resp_data)     |             |                     resp_data)     |
+------------------------------------+             +------------------------------------+
     |        ^         ^        |                      |        ^         ^        |
     |        |         |        |                      |        |         |        |
     | bus_gnt|         | snoop  |                      | bus_gnt|         | snoop  |
     | mem_   |         | bcast  |                      | mem_   |         | bcast  |
     | resp   |         |        |                      | resp   |         |        |
     v        |         |        v                      v        |         |        v
+---------------------------------------------------------------------------------------+
|                                    BUS ARBITER                                        |
|                                 (bus_arbiter.sv)                                      |
|                                                                                       |
|   1. Round-Robin Priority Resolver (last_gnt_q)                                       |
|   2. Cross-Snoop Router:                                                              |
|      - When Core 0 is granted  ===> Broadcasts address to Core 1 Snoop Port           |
|      - When Core 1 is granted  ===> Broadcasts address to Core 0 Snoop Port           |
|   3. Dirty Cache-to-Cache Forwarding:                                                 |
|      - If peer asserts snoop_resp_dirty, route peer's data instead of stale DRAM!     |
|   4. Memory Request Multiplexer                                                       |
+---------------------------------------------------------------------------------------+
                                    |               ^
                                    | mem_req_valid | mem_resp_valid
                                    | mem_req_cmd   | mem_resp_data [127:0]
                                    | mem_req_addr  |
                                    | mem_wdata     |
                                    v               |
                     +---------------------------------------------+
                     |           MAIN MEMORY CONTROLLER            |
                     |                 (DRAM / BFM)                |
                     +---------------------------------------------+
```

---

### 9.2 Level 2: Inside a Single L1 Cache Controller (`cache_controller.sv`)

This diagram shows how the **Main FSM**, **Tag Array**, **Data Array**, and **LRU Array** are wired together inside each core's cache:

```
                            CPU Request [31:0]
                      +-------------+-----------+--------+
                      | Tag [31:8]  | Set [7:4] | Offset |
                      +-------------+-----------+--------+
                             |            |         |
           +-----------------+            |         | [3:2] (Word Select)
           |                              |         |
           |   +--------------------------+         |
           |   |                                    |
           v   v                                    |
+-----------------------------------+               |
|          TAG & STATE ARRAY        |               |
|        (cache_tag_array.sv)       |               |
|                                   |               |
|   [Port A: CPU / Local FSM]       |               |
|   - cpu_index   [3:0]             |               |
|   - cpu_tag     [23:0]            |               |
|     --> hit_way0, hit_way1        |               |
|     --> state_way0, state_way1    |               |
|     --> tag_way0, tag_way1        |               |
|   - wr_en_way0/1, wr_tag, wr_state|               |
|                                   |               |
|   [Port B: Peer Snoop Port]       |               |
|   - snoop_index [3:0]             |               |
|   - snoop_tag   [23:0]            |               |
|     --> snoop_hit, snoop_state    |               |
|   - snoop_wr_en, snoop_wr_state   |               |
+-----------------------------------+               |
       |                |                           |
       | hit_way0/1     | wr_en, wr_state           |
       v                v                           |
+-----------------------------------+               |
|        MAIN CONTROLLER FSM        |               |
|                                   |               |
|  States:                          |               |
|   - FSM_IDLE                      |               |
|   - FSM_COMPARE_TAG               |               |
|   - FSM_WRITE_BACK (on dirty evict|               |
|   - FSM_ALLOCATE   (on line refill|               |
|   - FSM_UPGRADE    (on S -> M)    |               |
|                                   |               |
|  Controls:                        |               |
|   - cpu_ready, cpu_resp_valid     |               |
|   - bus_req_valid, bus_req_cmd    |               |
+-----------------------------------+               |
       |                |                           |
       | fill_en,       | update_en,                |
       | word_wr_en     | accessed_way              |
       v                v                           |
+------------------------------+     +--------------------------+
|          DATA ARRAY          |     |        LRU ARRAY         |
|     (cache_data_array.sv)    |     |      (lru_array.sv)      |
|                              |     |                          |
| - cpu_index, cpu_word_offset |     | - set_index [3:0]        |
| - fill_data [127:0]          |     | - update_en              |
| - word_wr_data [31:0]        |     | - accessed_way           |
| - byte_en [3:0]              |     |   --> lru_victim (0 or 1)|
|   --> line_way0_out [127:0]  |     +--------------------------+
|   --> line_way1_out [127:0]  |                  |
| - snoop_data_out [127:0]     |                  | lru_victim (picks
+------------------------------+                  | Way 0 or 1 on miss)
       |                |                         |
       v                v                         v
   [ Way 0 Line ]   [ Way 1 Line ]          (To FSM Victim Logic)
          \              /
           \            /
            v          v
       +--------------------+
       |   Way Select MUX   | <--- Selects based on hit_way0 / hit_way1
       +--------------------+
                 |
                 v Selected Line [127:0]
       +--------------------+
       | 4-to-1 Word MUX    | <--- Selects Word 0, 1, 2, or 3 using Offset [3:2]
       +--------------------+
                 |
                 v
           cpu_resp_rdata [31:0] ===> (Back to CPU)
```

---

### 9.3 Key Interconnect & Signal Flow Table

| Transaction | Flow Across Blocks |
| :--- | :--- |
| **Fast Read Hit (1 Cycle)** | `CPU` $\rightarrow$ `tag_array` (hit verified) $\rightarrow$ `data_array` $\rightarrow$ `Way Mux` $\rightarrow$ `Word Mux` $\rightarrow$ `CPU` (all in 1 cycle combinatorially). `lru_array` updates. |
| **Write Hit on `M`/`E`** | `CPU` $\rightarrow$ `tag_array` (hit verified) $\rightarrow$ `data_array` (writes 32-bit word with byte-enables) $\rightarrow$ `tag_array` (state set to `M`). |
| **Write Hit on `S`** | `FSM` enters `FSM_UPGRADE` $\rightarrow$ sends `BUS_UPGR` to `bus_arbiter` $\rightarrow$ peer core snoops and invalidates $\rightarrow$ local line becomes `M`. |
| **Miss with Dirty Eviction** | `tag_array` & `lru_array` pick dirty victim in state `M` $\rightarrow$ `FSM` enters `FSM_WRITE_BACK` $\rightarrow$ transmits dirty 128-bit line to `bus_arbiter` $\rightarrow$ DRAM. Then enters `FSM_ALLOCATE` to fetch new line. |
| **Peer Snoop Event** | Peer core broadcasts address on bus $\rightarrow$ `bus_arbiter` routes to Port B of `tag_array` and `data_array` $\rightarrow$ if `M`, forwards dirty 128-bit data; if peer writes, downgrades local state to `INVALID`. |

---

### 9.4 Module Summary

1. **`cache_def.sv`:** Central package defining parameters, MESI enums, bus command enums, FSM states, and helper extraction functions.
2. **`cache_tag_array.sv` (Tag & State Storage Array):**
   * **Physical Storage:** 16 sets $\times$ 2 ways $\times$ 24-bit tags (768 bits) + 16 sets $\times$ 2 ways $\times$ 2-bit MESI states (64 bits).
   * **Dual-Port Operation:**
     * **Port A (CPU Port):** Evaluates `cpu_tag` against Way 0 and Way 1 in parallel for `cpu_index`. Drives `hit_way0`, `hit_way1`, `state_way0`, `state_way1`, and tag outputs. Updates tags/states on refills and upgrades via `wr_en_way0` / `wr_en_way1`.
     * **Port B (Snooper Port):** Performs a dual-port read of OUR cache tags/states at `snoop_index`. Compares `snoop_tag` against our stored lines to detect peer bus accesses, driving `snoop_hit`, `snoop_hit_way`, and `snoop_state`. Handles peer-induced invalidations/downgrades via `snoop_wr_en`.
   * **Reset State:** Sets all 16 sets to tag `0` and state `INVALID`.
3. **`cache_data_array.sv`:** 16 sets $\times$ 2 ways $\times$ 128-bit storage. Implements full-line write refills, byte-masked 32-bit word writes, and snoop read-out.
4. **`lru_array.sv`:** 16-bit array implementing 1-bit True LRU with direct victim pointer outputs.
5. **`cache_controller.sv`:** Top-level L1 controller FSM executing 1-cycle hit paths, dirty evictions, line refills, upgrade broadcasts, and concurrent snooping downgrades/invalidations.
6. **`bus_arbiter.sv`:** Fairness arbiter multiplexing Core 0 and Core 1 requests, cross-broadcasting snoop addresses, and resolving dirty line forwarding.
7. **`dual_core_cache_subsystem.sv`:** Top-level structural module connecting both L1 caches and the arbiter.

---

## 10. Verification Strategy: Why UVM is Superior

### 10.1 Directed Testbenches vs. UVM Environment
A simple directed Verilog testbench manually drives 10 to 20 hardcoded transactions. While sufficient for basic sanity checks, it suffers from severe limitations:
* **Cannot expose concurrent race conditions:** Subtle bugs (such as Core 0 requesting a write upgrade on address $A$ in the exact cycle Core 1 attempts to evict address $A$) are virtually impossible to manually predict and code.
* **No metric of thoroughness:** Directed tests give no measurement of how many MESI transitions were actually exercised.

### 10.2 Recommended UVM Architecture

```
+---------------------------------------------------------------------------------+
|                                    UVM ENV                                      |
|                                                                                 |
|  +--------------------+   +--------------------+     +-----------------------+  |
|  |   Core 0 Agent     |   |    Core 1 Agent    |     |  Memory Slave Agent   |  |
|  | - Sequencer        |   | - Sequencer        |     | - Memory BFM (DRAM)   |  |
|  | - Driver (Master)  |   | - Driver (Master)  |     | - Randomized Latency  |  |
|  | - Monitor          |   | - Monitor          |     +-----------+-----------+  |
|  +---------+----------+   +---------+----------+                 |              |
|            |                        |                            |              |
|            +-------------------+----+----------------------------+              |
|                                |                                                |
|                                v (TLM Analysis Ports)                           |
|                    +-----------------------+                                    |
|                    |     UVM SCOREBOARD    |                                    |
|                    | - MESI State Tracker  |                                    |
|                    | - Golden Memory Array |                                    |
|                    +-----------------------+                                    |
+---------------------------------------------------------------------------------+
```

1. **Core 0 & Core 1 Master Agents:** Emulate CPUs by executing randomized read/write sequences with constrained address windows (forcing cache line collisions and MESI state ping-ponging).
2. **Memory Slave Agent:** Emulates off-chip DRAM. Accepts read/write requests from the cache arbiter, injects randomized wait-state latencies (e.g., 2 to 10 cycles), and returns data.
3. **Scoreboard & Reference Model:**
   * Maintains a golden associative memory array (`logic [31:0] golden_mem[int]`).
   * Verifies that every read by either core returns the most recently written data.
   * Tracks expected MESI states and flags any coherence protocol violations.
4. **Functional Coverage (`covergroup`):**
   * Cross-coverage of all 16 MESI transition combinations ($I \rightarrow E$, $E \rightarrow M$, $S \rightarrow M$, $M \rightarrow S$, $S \rightarrow I$, etc.).
   * Cross-coverage of concurrent bus requests under backpressure.

---

## 11. Resume Project Presentation & Interview Guide

### 11.1 High-Impact Resume Bullet Points
> **Dual-Core 2-Way Set-Associative MESI Cache Controller Subsystem** | *SystemVerilog, UVM*
> * Designed a parameterized, write-back/write-allocate 2-way set-associative L1 cache subsystem with **MESI snooping coherence protocol** for dual-core architectures.
> * Implemented parallel 24-bit tag comparators for single-cycle hit latency, 1-bit True LRU replacement per set, and a split-transaction round-robin bus arbiter.
> * Architected non-blocking snooping logic with dirty cache-to-cache forwarding, eliminating stale DRAM reads during multi-core sharing.
> * Developed a complete verification strategy with functional coverage and SystemVerilog Assertions (SVA) verifying data integrity across all MESI state transitions.

### 11.2 Key Interview Questions & Crisp Technical Answers

* **Q: Why did you choose 2-way set-associative instead of direct-mapped or fully-associative?**
  * *A:* Direct-mapped caches suffer from high conflict misses when two active variables hash to the same set index. Fully-associative caches eliminate conflict misses but require comparators across every slot, increasing power, area, and cycle time. 2-Way is the optimal trade-off: it drastically cuts conflict misses while requiring only **two parallel comparators** and a **1-bit LRU tracker**.
* **Q: How does your design handle a write to a line in state `Shared (S)`?**
  * *A:* Because other caches may hold a copy, the local cache cannot modify it silently. The controller enters `FSM_UPGRADE` and issues a `BUS_UPGR` on the shared bus. Peer caches snoop this address and invalidate their copies ($S \rightarrow I$). Once granted, the local cache promotes its line to `MODIFIED (M)` and completes the write.
* **Q: Why don't you write back to DRAM on every store?**
  * *A:* We use a **Write-Back** policy. Writing to DRAM takes tens of cycles. With Write-Back, once a line is in `Modified (M)` or `Exclusive (E)`, subsequent stores complete in **1 clock cycle within SRAM**. Data is only written to DRAM when the line is evicted by an LRU conflict miss or requested by another core.
* **Q: How does your LRU logic work?**
  * *A:* With 2 ways, True LRU requires only 1 bit per set. We define the bit directly as the victim pointer (`0 = Way 0 is victim`, `1 = Way 1 is victim`). On any access to Way $W$, the LRU bit updates to $\sim W$.
