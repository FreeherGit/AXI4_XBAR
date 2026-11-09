`ifndef AXI_SCOREBOARD_SV
`define AXI_SCOREBOARD_SV

// =============================================================================
// axi_scoreboard.sv  (included inside axi_tb_pkg)
//   Compares DUT behaviour with the reference model.
//
//   Inputs : completed transactions from the 2 master-port monitors and the
//            2 slave-port monitors.
//
//   Checks done for every transaction
//     [ROUTE]   a slave port only receives addresses of its own region
//     [ROUTE]   every master request mapped to Sx appears on Sx exactly once,
//               with the same ID / ADDR / LEN / SIZE / BURST
//     [WDATA]   W data and WSTRB arrive at the slave unchanged
//     [RESP]    BRESP / RRESP / RDATA / BID / RID go back to the master unchanged
//     [RESP]    response code equals the reference model prediction
//     [DECERR]  unmapped requests never reach a slave, get DECERR on every
//               beat, correct number of R beats, correct ID
//     [GHOST]   nothing appears on a slave that no master sent
//     [DATA]    read data matches the reference memory model
//     [PROTO]   protocol problems flagged by the monitors
//
//   Master-side and slave-side copies are paired by request fields, so the
//   checks do not depend on DUT latency or on which side is reported first.
//
//   verbose = 1 (or plusarg +SB_VERBOSE): one [SB] line per checked transaction
//   saying exactly which fields were compared and what was proved.
// =============================================================================

class axi_txn_pool;
  axi_txn q[$];

  // Prefer an exact (request + data) match, else the oldest request match
  function int find(axi_txn t);
    int first = -1;
    foreach (q[i]) begin
      if (q[i].same_request(t)) begin
        if (first < 0) first = i;
        if (q[i].same_payload(t)) return i;
      end
    end
    return first;
  endfunction
endclass


class axi_scoreboard;

  axi_ref_model        rm;
  mailbox #(axi_txn)   m_mbx[NUM_M];
  mailbox #(axi_txn)   s_mbx[NUM_S];
  axi_txn_pool         m_wait[NUM_S];   // master txns waiting for their slave copy
  axi_txn_pool         s_wait[NUM_S];   // slave txns waiting for their master copy

  int unsigned  n_err;
  int unsigned  n_wr_ok, n_rd_ok, n_dec_wr, n_dec_rd, n_slverr;
  int unsigned  n_m_seen[NUM_M];
  int unsigned  n_s_seen[NUM_S];
  int unsigned  max_err_print = 30;
  bit           verbose       = 1'b0;

  function new(axi_ref_model rm);
    this.rm = rm;
    foreach (m_mbx[i]) m_mbx[i] = new();
    foreach (s_mbx[i]) s_mbx[i] = new();
    foreach (m_wait[i]) begin
      m_wait[i] = new();
      s_wait[i] = new();
    end
  endfunction

  function void error(string tag, string msg);
    n_err++;
    if (n_err <= max_err_print) $error("[SB][%s] %s", tag, msg);
    else if (n_err == max_err_print + 1) $display("[SB] ... further errors suppressed");
  endfunction

  // ---------------------------------------------------------------------------
  task run();
    for (int i = 0; i < NUM_M; i++) begin
      automatic int k = i;
      fork master_loop(k); join_none
    end
    for (int i = 0; i < NUM_S; i++) begin
      automatic int k = i;
      fork slave_loop(k); join_none
    end
  endtask

  task master_loop(int k);
    axi_txn t;
    forever begin
      m_mbx[k].get(t);
      check_master(k, t);
    end
  endtask

  task slave_loop(int k);
    axi_txn t;
    forever begin
      s_mbx[k].get(t);
      check_slave(k, t);
    end
  endtask

  // ---------------------------------------------------------------------------
  function void check_master(int m, axi_txn t);
    int       tg, idx;
    bit [1:0] er;
    n_m_seen[m]++;
    tg = rm.target_of(t.addr);
    er = rm.expected_resp(t);

    if (t.proto_err)
      error("PROTO", $sformatf("M%0d side: %s :: %s", m, t.err_msg, t.convert2string()));
    if (t.rsp_id !== t.id)
      error("RESP", $sformatf("M%0d %s : response ID %0h != request ID %0h",
                              m, t.req_str(), t.rsp_id, t.id));

    // ---- unmapped address: DECERR, never forwarded
    if (tg == NUM_S) begin
      foreach (t.resp[i])
        if (t.resp[i] !== RESP_DECERR)
          error("DECERR", $sformatf("M%0d %s : beat %0d resp=%s, expected DECERR",
                                    m, t.req_str(), i, axi_resp_str(t.resp[i])));
      if (t.kind == AXI_WRITE) n_dec_wr++; else n_dec_rd++;
      if (verbose)
        $display("[%0t] [SB] DECERR  M%0d %s : resp=%s on all %0d beat(s), ID %0h -> %0h, nothing forwarded to S0/S1",
                 $time, m, t.req_str(), axi_resp_str(t.resp[0]), t.resp.size(), t.id, t.rsp_id);
      return;
    end

    // ---- mapped address: response code must match the prediction
    foreach (t.resp[i])
      if (t.resp[i] !== er)
        error("RESP", $sformatf("M%0d %s : beat %0d resp=%s, expected %s",
                                m, t.req_str(), i, axi_resp_str(t.resp[i]), axi_resp_str(er)));
    if (er == RESP_SLVERR) n_slverr++;

    if (t.kind == AXI_WRITE) rm.write_done(t);
    else                     rm.read_done(t);

    idx = s_wait[tg].find(t);
    if (idx >= 0) begin
      compare(t, s_wait[tg].q[idx], tg);
      s_wait[tg].q.delete(idx);
    end else begin
      m_wait[tg].q.push_back(t);
    end
  endfunction

  // ---------------------------------------------------------------------------
  function void check_slave(int p, axi_txn s);
    int tg, idx;
    n_s_seen[p]++;
    if (s.proto_err)
      error("PROTO", $sformatf("S%0d side: %s :: %s", p, s.err_msg, s.convert2string()));
    tg = rm.target_of(s.addr);
    if (tg != p) begin
      error("ROUTE", $sformatf("S%0d received %s but that address belongs to %s",
                               p, s.req_str(), rm.target_str(tg)));
      return;
    end
    idx = m_wait[p].find(s);
    if (idx >= 0) begin
      compare(m_wait[p].q[idx], s, p);
      m_wait[p].q.delete(idx);
    end else begin
      s_wait[p].q.push_back(s);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // m = master-side copy, s = slave-side copy of the same transaction
  function void compare(axi_txn m, axi_txn s, int p);
    int unsigned errs = 0;
    string       where;
    where = $sformatf("M%0d->S%0d %s", m.master, p, m.req_str());

    if (m.kind == AXI_WRITE) begin
      for (int i = 0; i < m.beats(); i++) begin
        if (m.data[i] !== s.data[i] || m.strb[i] !== s.strb[i]) begin
          errs++;
          error("WDATA", $sformatf("%s beat %0d: master sent data=%h strb=%h, slave got data=%h strb=%h",
                                   where, i, m.data[i], m.strb[i], s.data[i], s.strb[i]));
        end
      end
      if (m.resp[0] !== s.resp[0]) begin
        errs++;
        error("RESP", $sformatf("%s : slave BRESP=%s but master got %s",
                                where, axi_resp_str(s.resp[0]), axi_resp_str(m.resp[0])));
      end
      if (m.rsp_id !== s.rsp_id) begin
        errs++;
        error("RESP", $sformatf("%s : slave BID=%0h but master got %0h", where, s.rsp_id, m.rsp_id));
      end
   // ---- axi_scoreboard.sv এর compare() ফাংশনের WRITE অংশের শেষে:
      if (errs == 0) begin
        n_wr_ok++;
        if (verbose)
          $display("[%0t] [SB-WRITE-PASS] %s : WROTE Data[0]=0x%0h (Strb=0x%0h, %0d beats) -> S%0d received identically, BRESP=%s / BID=0x%0h --> [MATCHED!]",
                   $time, where, m.data[0], m.strb[0], m.beats(), p, axi_resp_str(m.resp[0]), m.rsp_id);
      end
 end else begin
      for (int i = 0; i < m.beats(); i++) begin
        if (m.data[i] !== s.data[i] || m.resp[i] !== s.resp[i]) begin
          errs++;
          error("RDATA", $sformatf("%s beat %0d: slave sent data=%h resp=%s, master got data=%h resp=%s",
                                   where, i, s.data[i], axi_resp_str(s.resp[i]),
                                   m.data[i], axi_resp_str(m.resp[i])));
        end
      end
      if (m.rsp_id !== s.rsp_id) begin
        errs++;
        error("RESP", $sformatf("%s : slave RID=%0h but master got %0h", where, s.rsp_id, m.rsp_id));
      end
    // ---- axi_scoreboard.sv এর compare() ফাংশনের READ অংশের শেষে:
      if (errs == 0) begin
        n_rd_ok++;
        if (verbose)
          $display("[%0t] [SB-READ-PASS ] %s : READ  Data[0]=0x%0h (%0d beats) <- S%0d sent 0x%0h, RRESP=%s / RID=0x%0h --> [MATCHED!]",
                   $time, where, m.data[0], m.beats(), p, s.data[0], axi_resp_str(m.resp[0]), m.rsp_id);
      end
     end
  endfunction

  // ---------------------------------------------------------------------------
  // Reset: anything still in flight is legally lost
  function void on_reset();
    int unsigned e;
    foreach (m_wait[i]) begin
      m_wait[i].q.delete();
      s_wait[i].q.delete();
    end
    e = rm.on_reset();
    n_err += e;
  endfunction

  function bit pending();
    foreach (m_wait[i]) if (m_wait[i].q.size() || s_wait[i].q.size()) return 1;
    foreach (m_mbx[i]) if (m_mbx[i].num()) return 1;
    foreach (s_mbx[i]) if (s_mbx[i].num()) return 1;
    return 0;
  endfunction

  // ---------------------------------------------------------------------------
  function void final_check();
    foreach (m_wait[p]) begin
      foreach (m_wait[p].q[i])
        error("ROUTE", $sformatf("M%0d %s never appeared on S%0d (dropped or misrouted)",
                                 m_wait[p].q[i].master, m_wait[p].q[i].req_str(), p));
      foreach (s_wait[p].q[i])
        error("GHOST", $sformatf("S%0d saw %s that no master issued (duplicate / corrupted request)",
                                 p, s_wait[p].q[i].req_str()));
      m_wait[p].q.delete();
      s_wait[p].q.delete();
    end
    n_err += rm.check_reads();
  endfunction

  function void report();
    $display("------------------------------------------------------------------");
    $display(" SCOREBOARD SUMMARY");
    for (int m = 0; m < NUM_M; m++) $display("   M%0d transactions seen      : %0d", m, n_m_seen[m]);
    for (int s = 0; s < NUM_S; s++) $display("   S%0d transactions seen      : %0d", s, n_s_seen[s]);
    $display("   writes routed + matched   : %0d", n_wr_ok);
    $display("   reads  routed + matched   : %0d", n_rd_ok);
    $display("   DECERR writes / reads     : %0d / %0d", n_dec_wr, n_dec_rd);
    $display("   SLVERR responses          : %0d", n_slverr);
    $display("   read bytes checked (ref)  : %0d", rm.n_bytes_checked);
    $display("   ERRORS                    : %0d", n_err);
    $display("------------------------------------------------------------------");
  endfunction

endclass
`endif // AXI_SCOREBOARD_SV
