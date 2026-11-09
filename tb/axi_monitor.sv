`ifndef AXI_MONITOR_SV
`define AXI_MONITOR_SV

// =============================================================================
// axi_monitor.sv  (included inside axi_tb_pkg)
//   Passive monitor, used on BOTH master ports and slave ports.
//   Samples all five channels every clock (through vif.cb) and rebuilds
//   complete transactions:
//     write = AW + all W beats + B      (published after the B handshake)
//     read  = AR + all R beats          (published after the last R beat)
//   W beats are paired with AWs in order (AXI4 has no write interleaving);
//   B / R are paired with the oldest outstanding request that has the same ID.
//   Protocol problems (wrong beat count, missing WLAST/RLAST, response with an
//   unknown ID ...) are flagged in t.proto_err / t.err_msg.
//   Finished transactions are sent to every connected mailbox
//   (scoreboard, coverage) - like a UVM analysis port.
//
//   Error injection (axi_bad_id_test):
//     stray_ok_b / stray_ok_r = how many unknown-ID B / R the test is about to
//     inject on this port. Each such response is counted (n_stray_b/r) and
//     ignored instead of being an error. Any EXTRA unknown-ID response is
//     still an error, exactly as before.
// =============================================================================

class axi_monitor;

  string              name;
  virtual axi_if      vif;
  int                 port_idx;
  bit                 is_master;

  mailbox #(axi_txn)  subs[$];

  axi_txn             w_need[$];    // AW seen, W data not complete yet
  axi_txn             w_early[$];   // W burst finished before its AW (holder objects)
  axi_txn             wr_pend[$];   // AW seen, B not seen yet
  axi_txn             rd_pend[$];   // AR seen, last R not seen yet
  bit [AXI_DW-1:0]    wbuf_d[$];
  bit [AXI_SW-1:0]    wbuf_s[$];

  int unsigned        n_wr, n_rd, n_proto_err;

  // error injection: number of unknown-ID B / R the test expects (not an error)
  int unsigned        stray_ok_b, stray_ok_r, n_stray_b, n_stray_r;

  function new(string name, int port_idx, bit is_master, virtual axi_if vif);
    this.name      = name;
    this.port_idx  = port_idx;
    this.is_master = is_master;
    this.vif       = vif;
  endfunction

  function void connect(mailbox #(axi_txn) m);
    subs.push_back(m);
  endfunction

  function void publish(axi_txn t);
    foreach (subs[i]) void'(subs[i].try_put(t));
  endfunction

  function void flag(axi_txn t, string msg);
    t.proto_err = 1'b1;
    t.err_msg   = (t.err_msg == "") ? msg : {t.err_msg, "; ", msg};
    n_proto_err++;
  endfunction

  function void flush();
    w_need.delete(); w_early.delete(); wr_pend.delete(); rd_pend.delete();
    wbuf_d.delete(); wbuf_s.delete();
  endfunction

  function bit idle();
    return (w_need.size() == 0) && (w_early.size() == 0) && (wr_pend.size() == 0) &&
           (rd_pend.size() == 0) && (wbuf_d.size() == 0);
  endfunction

  function axi_txn new_req(axi_kind_e kind);
    axi_txn t = new();
    t.kind   = kind;
    t.port   = port_idx;
    t.master = is_master ? port_idx : -1;
    t.t_req  = $time;
    return t;
  endfunction

  // ---------------------------------------------------------------------------
  task run();
    forever begin
      @(vif.cb);
      if (vif.arst_n !== 1'b1) begin
        flush();
      end else begin
        sample_aw();
        sample_w();
        sample_b();
        sample_ar();
        sample_r();
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  function void attach_wdata(axi_txn t, axi_txn h);
    if (h.data.size() != t.beats())
      flag(t, $sformatf("W burst had %0d beats (WLAST position) but AWLEN+1 = %0d",
                        h.data.size(), t.beats()));
    for (int i = 0; i < t.beats(); i++) begin
      if (i < h.data.size()) begin
        t.data[i] = h.data[i];
        t.strb[i] = h.strb[i];
      end
    end
    t.data_done = 1'b1;
  endfunction

  function void sample_aw();
    axi_txn t;
    if (vif.cb.awvalid && vif.cb.awready) begin
      t       = new_req(AXI_WRITE);
      t.id    = vif.cb.awid;
      t.addr  = vif.cb.awaddr;
      t.len   = vif.cb.awlen;
      t.size  = vif.cb.awsize;
      t.burst = vif.cb.awburst;
      t.data  = new[t.beats()];
      t.strb  = new[t.beats()];
      t.outstanding_at_issue = wr_pend.size();
      wr_pend.push_back(t);
      if (w_early.size() > 0) attach_wdata(t, w_early.pop_front());
      else                    w_need.push_back(t);
    end
  endfunction

  function void sample_w();
    axi_txn h;
    if (vif.cb.wvalid && vif.cb.wready) begin
      wbuf_d.push_back(vif.cb.wdata);
      wbuf_s.push_back(vif.cb.wstrb);
      if (vif.cb.wlast || wbuf_d.size() >= 256) begin
        h = new();
        h.data = new[wbuf_d.size()];
        h.strb = new[wbuf_s.size()];
        foreach (wbuf_d[i]) begin
          h.data[i] = wbuf_d[i];
          h.strb[i] = wbuf_s[i];
        end
        wbuf_d.delete();
        wbuf_s.delete();
        if (w_need.size() > 0) attach_wdata(w_need.pop_front(), h);
        else                   w_early.push_back(h);
      end
    end
  endfunction

  function void sample_b();
    axi_txn t;
    int     idx = -1;
    if (vif.cb.bvalid && vif.cb.bready) begin
      foreach (wr_pend[i]) if (idx < 0 && wr_pend[i].id == vif.cb.bid) idx = i;
      if (idx < 0 && stray_ok_b > 0) begin
        stray_ok_b--;
        n_stray_b++;
        $display("[%0t] [%s] expected stray B with BID=%0h (error injection), not a transaction",
                 $time, name, vif.cb.bid);
        return;
      end
      if (idx < 0) begin
        t = new_req(AXI_WRITE);
        t.id = vif.cb.bid;
        t.resp = new[1];
        t.resp[0] = vif.cb.bresp;
        t.rsp_id  = vif.cb.bid;
        flag(t, $sformatf("B handshake with BID=%0h but no outstanding AW has that ID", vif.cb.bid));
        $error("[%s] %s", name, t.err_msg);
        publish(t);
        return;
      end
      t = wr_pend[idx];
      wr_pend.delete(idx);
      if (!t.data_done) begin
        flag(t, "B response arrived before the last W beat");
        foreach (w_need[i]) if (w_need[i] == t) begin w_need.delete(i); break; end
      end
      t.resp    = new[1];
      t.resp[0] = vif.cb.bresp;
      t.rsp_id  = vif.cb.bid;
      t.t_end   = $time;
      n_wr++;
      publish(t);
    end
  endfunction

  function void sample_ar();
    axi_txn t;
    if (vif.cb.arvalid && vif.cb.arready) begin
      t       = new_req(AXI_READ);
      t.id    = vif.cb.arid;
      t.addr  = vif.cb.araddr;
      t.len   = vif.cb.arlen;
      t.size  = vif.cb.arsize;
      t.burst = vif.cb.arburst;
      t.data  = new[t.beats()];
      t.resp  = new[t.beats()];
      t.outstanding_at_issue = rd_pend.size();
      rd_pend.push_back(t);
    end
  endfunction

  function void sample_r();
    axi_txn t;
    int     idx = -1;
    bit     finish;
    if (vif.cb.rvalid && vif.cb.rready) begin
      foreach (rd_pend[i]) if (idx < 0 && rd_pend[i].id == vif.cb.rid) idx = i;
      if (idx < 0 && stray_ok_r > 0) begin
        stray_ok_r--;
        n_stray_r++;
        $display("[%0t] [%s] expected stray R with RID=%0h (error injection), not a transaction",
                 $time, name, vif.cb.rid);
        return;
      end
      if (idx < 0) begin
        t = new_req(AXI_READ);
        t.id = vif.cb.rid;
        t.resp = new[1];
        t.resp[0] = vif.cb.rresp;
        t.rsp_id  = vif.cb.rid;
        flag(t, $sformatf("R beat with RID=%0h but no outstanding AR has that ID", vif.cb.rid));
        $error("[%s] %s", name, t.err_msg);
        publish(t);
        return;
      end
      t = rd_pend[idx];
      if (t.beat_cnt < t.beats()) begin
        t.data[t.beat_cnt] = vif.cb.rdata;
        t.resp[t.beat_cnt] = vif.cb.rresp;
      end
      t.rsp_id = vif.cb.rid;
      t.beat_cnt++;
      finish = 1'b0;
      if (vif.cb.rlast) begin
        if (t.beat_cnt != t.beats())
          flag(t, $sformatf("RLAST on beat %0d but ARLEN+1 = %0d", t.beat_cnt, t.beats()));
        finish = 1'b1;
      end else if (t.beat_cnt == t.beats()) begin
        flag(t, $sformatf("RLAST missing on final beat %0d", t.beat_cnt));
        finish = 1'b1;
      end
      if (finish) begin
        rd_pend.delete(idx);
        t.t_end = $time;
        n_rd++;
        publish(t);
      end
    end
  endfunction

endclass
`endif // AXI_MONITOR_SV
