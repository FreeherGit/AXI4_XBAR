`ifndef AXI_TXN_SV
`define AXI_TXN_SV

// =============================================================================
// axi_txn.sv  (included inside axi_tb_pkg)
//   One complete AXI4 transaction (a whole burst, not a single beat).
//   Used everywhere: sequences create it, drivers execute it, monitors
//   rebuild it from the pins, scoreboard / reference model / coverage check it.
//
//   Directed use :  t = new(); t.kind = AXI_WRITE; t.addr = ...; t.fill_payload();
//   Random use   :  t = new(); t.max_len = 15;            // knob
//                   t.region = 1; t.region.rand_mode(0);   // fix a field
//                   void'(t.randomize());
// =============================================================================

class axi_txn;

  static int unsigned uid_cnt = 0;
  int unsigned        uid;                 // unique number, handy in logs

  // ---------------- request fields
  rand axi_kind_e          kind;
  rand bit [AXI_IDW-1:0]   id;
  rand bit [AXI_AW-1:0]    addr;
  rand bit [7:0]           len;            // beats - 1
  rand bit [2:0]           size;           // bytes per beat = 2**size
  rand bit [1:0]           burst;
  bit      [AXI_DW-1:0]    data[];         // write: data to send / read: data received
  bit      [AXI_SW-1:0]    strb[];         // write strobes (one per beat)

  // ---------------- stimulus knobs
  rand bit [1:0]           region;         // 0: S0   1: S1   2: unmapped (DECERR)
  rand bit [3:0]           unmapped_hi;    // addr[31:28] used when region == 2
  rand int unsigned        req_delay;      // idle clocks before AWVALID/ARVALID
  int unsigned             beat_gap[];     // idle clocks before each W beat
  int unsigned             gap_pct     = 15;            // % of W beats that get a gap
  bit [AXI_AW-1:0]         addr_window = 32'h0001_0000; // offset range inside a region
  bit                      sparse_strb = 1'b0;          // randomly clear some strobes
  bit [7:0]                max_len     = 8'd255;        // upper limit for len
  bit [AXI_IDW-1:0]        id_min      = '0;            // ID range for randomization
  bit [AXI_IDW-1:0]        id_max      = '1;

  // ---------------- response fields
  bit [1:0]                resp[];         // write: resp[0] = BRESP, read: RRESP per beat
  bit [AXI_IDW-1:0]        rsp_id;         // BID / RID seen with the response

  // ---------------- bookkeeping (filled by drivers / monitors)
  int                      master = -1;    // master port that issued it
  int                      port   = -1;    // port where the monitor saw it
  time                     t_req;          // AW/AR handshake time
  time                     t_end;          // B / last-R handshake time
  int unsigned             beat_cnt;       // beats transferred so far
  int unsigned             outstanding_at_issue;
  bit                      data_done;      // monitor: all W beats collected
  bit                      done;           // driver: transaction finished
  bit                      aborted;        // killed by a reset
  bit                      proto_err;
  string                   err_msg = "";

  // ---------------------------------------------------------------------------
  // Constraints (legal AXI4 + useful distributions)
  // ---------------------------------------------------------------------------
  constraint c_size   { size <= $clog2(AXI_SW); }
  constraint c_burst  { burst dist {BURST_FIXED := 15, BURST_INCR := 65, BURST_WRAP := 20}; }
  constraint c_len    { len dist {0 := 20, [1:15] := 50, [16:63] := 20, [64:255] := 10}; }
  constraint c_wrap   { burst == BURST_WRAP  -> len inside {1, 3, 7, 15}; }
  constraint c_fixed  { burst == BURST_FIXED -> len <= 15; }
  constraint c_align  { burst == BURST_WRAP  -> ((addr & ((32'd1 << size) - 32'd1)) == 32'd0); }
  constraint c_4k     { burst == BURST_INCR  ->
                          ({20'd0, addr[11:0]} + ((32'd1 + {24'd0, len}) << size)) <= 32'd4096; }
  constraint c_region { region dist {2'd0 := 45, 2'd1 := 45, 2'd2 := 10}; region != 2'd3; }
  constraint c_map    { region == 2'd0 -> addr[31:28] == 4'h0;
                        region == 2'd1 -> addr[31:28] == 4'h1;
                        region == 2'd2 -> addr[31:28] == unmapped_hi; }
  constraint c_unmapped { unmapped_hi dist {4'h2 := 35, [4'h3:4'hE] := 30, 4'hF := 35};
                          unmapped_hi >= 4'h2; }   // favour the edges 0x2 and 0xF
  constraint c_window { {4'h0, addr[27:0]} < addr_window; }
  constraint c_delay  { req_delay dist {0 := 70, [1:5] := 30}; }
  constraint c_maxlen { len <= max_len; }
  constraint c_idrng  { id >= id_min; id <= id_max; }

  function new();
    uid = uid_cnt++;
  endfunction

  function void post_randomize();
    fill_payload();
  endfunction

  function int unsigned beats();
    return int'(len) + 1;
  endfunction

  // Random write data + legal strobes + W beat gaps
  function void fill_payload();
    data     = new[beats()];
    beat_gap = new[beats()];
    for (int i = 0; i < beats(); i++) begin
      for (int w = 0; w < AXI_DW; w += 32) data[i][w +: 32] = $urandom;
      beat_gap[i] = axi_chance(gap_pct) ? $urandom_range(3, 1) : 0;
    end
    fill_strb();
  endfunction

  // Strobes that match the byte lanes of each beat (call after setting data)
  function void fill_strb();
    strb = new[beats()];
    for (int i = 0; i < beats(); i++) begin
      strb[i] = axi_lane_mask(axi_beat_addr(addr, size, len, burst, i), size);
      if (sparse_strb) strb[i] = strb[i] & AXI_SW'($urandom);
    end
    if (beat_gap.size() != beats()) begin
      beat_gap = new[beats()];
      foreach (beat_gap[i]) beat_gap[i] = 0;
    end
  endfunction

  // Same request (used by the scoreboard to pair master-side and slave-side)
  function bit same_request(axi_txn o);
    return (o != null) && (kind == o.kind) && (id == o.id) && (addr == o.addr) &&
           (len == o.len) && (size == o.size) && (burst == o.burst);
  endfunction

  // Same request AND same data / responses
  function bit same_payload(axi_txn o);
    if (!same_request(o)) return 0;
    if (data.size() != o.data.size()) return 0;
    foreach (data[i]) if (data[i] !== o.data[i]) return 0;
    if (kind == AXI_WRITE) begin
      if (strb.size() != o.strb.size()) return 0;
      foreach (strb[i]) if (strb[i] !== o.strb[i]) return 0;
    end
    return 1;
  endfunction

  function string req_str();
    return $sformatf("%s id=%0h addr=%08h len=%0d(%0d beats) size=%0d burst=%s",
                     (kind == AXI_WRITE) ? "WR" : "RD", id, addr, len, beats(), size,
                     axi_burst_str(burst));
  endfunction

  function string convert2string();
    string s;
    s = $sformatf("#%0d %s", uid, req_str());
    if (master >= 0) s = {s, $sformatf(" M%0d", master)};
    if (resp.size() > 0) s = {s, $sformatf(" resp=%s rsp_id=%0h", axi_resp_str(resp[0]), rsp_id)};
    return s;
  endfunction

  function axi_txn clone();
    axi_txn c = new();
    c.kind = kind; c.id = id; c.addr = addr; c.len = len; c.size = size; c.burst = burst;
    c.data = data; c.strb = strb; c.region = region; c.req_delay = req_delay;
    c.beat_gap = beat_gap; c.gap_pct = gap_pct; c.addr_window = addr_window;
    c.sparse_strb = sparse_strb; c.max_len = max_len; c.id_min = id_min; c.id_max = id_max; c.resp = resp; c.rsp_id = rsp_id;
    c.master = master; c.port = port; c.t_req = t_req; c.t_end = t_end;
    return c;
  endfunction

endclass
`endif // AXI_TXN_SV
