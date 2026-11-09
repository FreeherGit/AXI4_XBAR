`ifndef AXI_REF_MODEL_SV
`define AXI_REF_MODEL_SV

// =============================================================================
// axi_ref_model.sv  (included inside axi_tb_pkg)
//   Reference model = "what SHOULD happen". It knows the spec, not the RTL.
//     1. Routing   : target_of(addr)  -> 0 (S0), 1 (S1) or NUM_S (DECERR)
//     2. Response  : expected_resp(t) -> OKAY / SLVERR (slave error window) / DECERR
//     3. Data      : a byte-level history of every completed OKAY write.
//                    Each read (master side) is checked against it.
//
//   Why a history and not a plain memory?  Two masters can write and read
//   the same address at the same time; the exact order inside the slave is
//   then not known from the master side. For every byte we compute the set of
//   values the read may legally return:
//     - value of the last write that FINISHED before the read started
//       (+ writes overlapping that one in time: their order is unknown)
//     - values of writes running at the same time as the read
//     - initial value 0 if no write finished before the read
//     - ANY value if a write that was cut by a reset may have touched it
//   Reads are checked at the end of the test (or at a reset), when all
//   writes are known.
// =============================================================================

typedef struct {
  bit [7:0]    val;
  time         ts;    // write AW handshake time (master side)
  time         te;    // write B handshake time  (master side)
  int unsigned uid;
  bit          any;   // 1: write aborted by reset, data unknown
} axi_wbyte_t;

class axi_byte_hist;
  axi_wbyte_t q[$];
endclass

class axi_ref_model;

  bit [AXI_AW-1:0]  base [NUM_S];
  bit [AXI_AW-1:0]  limit[NUM_S];
  axi_agent_cfg     s_cfg[NUM_S];      // to know slave SLVERR windows

  axi_byte_hist     hist[bit [AXI_AW-1:0]];
  axi_txn           reads[$];
  bit [7:0]         init_byte = 8'h00;

  int unsigned      n_bytes_checked, n_reads_checked, n_data_err;
  int unsigned      max_err_print = 20;

  function new();
    base[0] = S0_BASE;  limit[0] = S0_LIMIT;
    base[1] = S1_BASE;  limit[1] = S1_LIMIT;
  endfunction

  // ---------------------------------------------------------------------------
  // Routing / response prediction
  // ---------------------------------------------------------------------------
  function int target_of(bit [AXI_AW-1:0] a);
    for (int s = 0; s < NUM_S; s++)
      if (a >= base[s] && a <= limit[s]) return s;
    return NUM_S;   // unmapped -> DECERR
  endfunction

  function string target_str(int tg);
    return (tg == NUM_S) ? "DECERR" : $sformatf("S%0d", tg);
  endfunction

  function bit [1:0] expected_resp(axi_txn t);
    int tg = target_of(t.addr);
    if (tg == NUM_S) return RESP_DECERR;
    if (s_cfg[tg] != null && s_cfg[tg].is_err_addr(t.addr)) return RESP_SLVERR;
    return RESP_OKAY;
  endfunction

  // ---------------------------------------------------------------------------
  // Data model
  // ---------------------------------------------------------------------------
  // Called with a completed MASTER-side write
  function void write_done(axi_txn t);
    bit [AXI_AW-1:0] baddr, a;
    bit [AXI_SW-1:0] m;
    axi_wbyte_t      w;
    if (t.resp.size() == 0 || t.resp[0] != RESP_OKAY) return;
    for (int i = 0; i < t.beats() && i < t.data.size(); i++) begin
      baddr = axi_beat_addr(t.addr, t.size, t.len, t.burst, i);
      m     = t.strb[i] & axi_lane_mask(baddr, t.size);
      for (int b = 0; b < AXI_SW; b++) begin
        if (m[b]) begin
          a     = axi_lane_addr(baddr, b);
          w.val = t.data[i][8*b +: 8];
          w.ts  = t.t_req;
          w.te  = t.t_end;
          w.uid = t.uid;
          w.any = 1'b0;
          if (!hist.exists(a)) hist[a] = new();
          hist[a].q.push_back(w);
        end
      end
    end
  endfunction

  // Called at reset for a write whose AW was accepted but whose B never came:
  // some of its beats may already be in the slave memory -> value unknown.
  function void write_unknown(axi_txn t, time t_rst);
    bit [AXI_AW-1:0] baddr;
    bit [AXI_SW-1:0] m;
    axi_wbyte_t      w;
    if (target_of(t.addr) == NUM_S) return;
    for (int i = 0; i < t.beats(); i++) begin
      baddr = axi_beat_addr(t.addr, t.size, t.len, t.burst, i);
      m     = axi_lane_mask(baddr, t.size);
      for (int b = 0; b < AXI_SW; b++) begin
        if (m[b]) begin
          w.val = 8'h00;  w.ts = t.t_req;  w.te = t_rst;  w.uid = t.uid;  w.any = 1'b1;
          if (!hist.exists(axi_lane_addr(baddr, b))) hist[axi_lane_addr(baddr, b)] = new();
          hist[axi_lane_addr(baddr, b)].q.push_back(w);
        end
      end
    end
  endfunction

  // Called with a completed MASTER-side read (checked later)
  function void read_done(axi_txn t);
    reads.push_back(t);
  endfunction

  // Legal values of byte "a" for a read alive in [r_ts, r_te].
  // Returns 1 when any value is legal (a reset-aborted write may have hit it).
  function bit legal_values(bit [AXI_AW-1:0] a, time r_ts, time r_te, ref bit [7:0] vals[$]);
    axi_byte_hist h;
    axi_wbyte_t   last;
    bit           have_last = 1'b0;
    vals.delete();
    if (!hist.exists(a)) begin
      vals.push_back(init_byte);
      return 1'b0;
    end
    h = hist[a];
    foreach (h.q[i])
      if (h.q[i].any && h.q[i].ts < r_te) return 1'b1;
    foreach (h.q[i])
      if (h.q[i].te <= r_ts && (!have_last || h.q[i].te > last.te)) begin
        last      = h.q[i];
        have_last = 1'b1;
      end
    if (have_last) begin
      foreach (h.q[i])
        if (h.q[i].te <= r_ts && h.q[i].te > last.ts) vals.push_back(h.q[i].val);
    end else begin
      vals.push_back(init_byte);
    end
    foreach (h.q[i])
      if (h.q[i].te > r_ts && h.q[i].ts < r_te) vals.push_back(h.q[i].val);
    return 1'b0;
  endfunction

  function int unsigned check_one_read(axi_txn t);
    bit [AXI_AW-1:0] baddr, a;
    bit [AXI_SW-1:0] m;
    bit [7:0]        act;
    bit [7:0]        vals[$];
    bit              ok;
    string           exp_s;
    int unsigned     errs = 0;
    for (int i = 0; i < t.beats() && i < t.data.size(); i++) begin
      if (t.resp[i] != RESP_OKAY) continue;
      baddr = axi_beat_addr(t.addr, t.size, t.len, t.burst, i);
      m     = axi_lane_mask(baddr, t.size);
      for (int b = 0; b < AXI_SW; b++) begin
        if (!m[b]) continue;
        a   = axi_lane_addr(baddr, b);
        act = t.data[i][8*b +: 8];
        ok  = legal_values(a, t.t_req, t.t_end, vals);
        foreach (vals[k]) if (vals[k] == act) ok = 1'b1;
        n_bytes_checked++;
        if (!ok) begin
          errs++;
          n_data_err++;
          if (n_data_err <= max_err_print) begin
            exp_s = "";
            foreach (vals[k]) exp_s = {exp_s, $sformatf("%02h ", vals[k])};
            $error("[REF] READ DATA MISMATCH M%0d %s : beat %0d byte addr %08h got %02h, expected one of { %s}",
                   t.master, t.req_str(), i, a, act, exp_s);
          end
        end
      end
    end
    n_reads_checked++;
    return errs;
  endfunction

  // Check every collected read; returns number of data errors
  function int unsigned check_reads();
    int unsigned errs = 0;
    foreach (reads[i]) errs += check_one_read(reads[i]);
    reads.delete();
    return errs;
  endfunction

  // At reset: check what we have, then forget (slave memories are cleared too)
  function int unsigned on_reset();
    int unsigned errs = check_reads();
    hist.delete();
    return errs;
  endfunction

endclass
`endif // AXI_REF_MODEL_SV
