`ifndef AXI_MASTER_DRIVER_SV
`define AXI_MASTER_DRIVER_SV

// =============================================================================
// axi_master_driver.sv  (included inside axi_tb_pkg)
//   Active AXI4 master. Takes transactions from the sequence mailbox and
//   drives them on a crossbar MASTER port.
//
//   Five independent threads (one per AXI channel), so the driver supports:
//     * multiple outstanding transactions (cfg.max_outstanding)
//     * AW and W running independently, reads in parallel with writes
//     * random BREADY / RREADY backpressure
//   When a transaction finishes, its response fields are filled in and
//   t.done is set, so a sequence can "wait (t.done)".
//   On reset: all threads are killed, outputs go idle, pending transactions
//   are marked done + aborted (sequences never hang).
// =============================================================================

class axi_master_driver;

  string               name;
  virtual axi_if       vif;
  axi_agent_cfg        cfg;
  mailbox #(axi_txn)   seq_mbx;

  axi_txn              aw_q[$];     // waiting to send AW
  axi_txn              w_q[$];      // waiting to send W data
  axi_txn              ar_q[$];     // waiting to send AR
  axi_txn              wr_pend[$];  // AW accepted, waiting for B
  axi_txn              rd_pend[$];  // AR accepted, waiting for R
  axi_txn              cur_get;     // taken from mailbox, waiting for a free slot

  int unsigned         outstanding;
  int unsigned         n_wr_done, n_rd_done, n_err;

  function new(string name, axi_agent_cfg cfg, virtual axi_if vif, mailbox #(axi_txn) seq_mbx);
    this.name    = name;
    this.cfg     = cfg;
    this.vif     = vif;
    this.seq_mbx = seq_mbx;
  endfunction

  // ---------------------------------------------------------------------------
  function void drive_idle();
    vif.awid    <= '0;  vif.awaddr  <= '0;  vif.awlen   <= '0;
    vif.awsize  <= '0;  vif.awburst <= '0;  vif.awvalid <= 1'b0;
    vif.wdata   <= '0;  vif.wstrb   <= '0;  vif.wlast   <= 1'b0;  vif.wvalid <= 1'b0;
    vif.bready  <= 1'b0;
    vif.arid    <= '0;  vif.araddr  <= '0;  vif.arlen   <= '0;
    vif.arsize  <= '0;  vif.arburst <= '0;  vif.arvalid <= 1'b0;
    vif.rready  <= 1'b0;
  endfunction

  function void abort(axi_txn t);
    if (t != null && !t.done) begin
      t.aborted = 1'b1;
      t.done    = 1'b1;
    end
  endfunction

  function void flush();
    abort(cur_get);
    foreach (aw_q[i])    abort(aw_q[i]);
    foreach (w_q[i])     abort(w_q[i]);
    foreach (ar_q[i])    abort(ar_q[i]);
    foreach (wr_pend[i]) abort(wr_pend[i]);
    foreach (rd_pend[i]) abort(rd_pend[i]);
    aw_q.delete(); w_q.delete(); ar_q.delete(); wr_pend.delete(); rd_pend.delete();
    cur_get     = null;
    outstanding = 0;
  endfunction

  // True when nothing is queued or in flight
  function bit idle();
    return (seq_mbx.num() == 0) && (cur_get == null) && (outstanding == 0) &&
           (aw_q.size() == 0) && (w_q.size() == 0) && (ar_q.size() == 0) &&
           (wr_pend.size() == 0) && (rd_pend.size() == 0);
  endfunction

  // ---------------------------------------------------------------------------
  task run();
    drive_idle();
    forever begin
      wait (vif.arst_n === 1'b1);
      fork
        begin
          fork
            get_loop();
            aw_loop();
            w_loop();
            ar_loop();
            b_loop();
            r_loop();
          join_none
          wait (vif.arst_n === 1'b0);
          disable fork;
        end
      join
      drive_idle();
      flush();
    end
  endtask

  // Wait for the next clock edge unless we are already sitting on one
  task sync(ref time t_last);
    if ($time != t_last) begin
      @(vif.cb);
      t_last = $time;
    end
  endtask

  // ---------------------------------------------------------------------------
  task get_loop();
    axi_txn t;
    forever begin
      seq_mbx.get(t);
      cur_get = t;
      wait (outstanding < cfg.max_outstanding);
      outstanding++;
      cur_get    = null;
      t.master   = cfg.port_idx;
      t.beat_cnt = 0;
      t.done     = 1'b0;
      t.aborted  = 1'b0;
      if (t.kind == AXI_WRITE) begin
        if (t.data.size() != t.beats() || t.strb.size() != t.beats()) t.fill_payload();
        aw_q.push_back(t);
        w_q.push_back(t);
      end else begin
        ar_q.push_back(t);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  task aw_loop();
    axi_txn t;
    time    t_last = -1;
    forever begin
      wait (aw_q.size() > 0);
      t = aw_q[0];              // stays queued until accepted (flush can abort it)
      sync(t_last);
      repeat (t.req_delay) @(vif.cb);
      vif.awid    <= t.id;
      vif.awaddr  <= t.addr;
      vif.awlen   <= t.len;
      vif.awsize  <= t.size;
      vif.awburst <= t.burst;
      vif.awvalid <= 1'b1;
      @(vif.cb);
      while (!vif.cb.awready) @(vif.cb);
      vif.awvalid <= 1'b0;
      t_last  = $time;
      t.t_req = $time;
      void'(aw_q.pop_front());
      wr_pend.push_back(t);
    end
  endtask

  // ---------------------------------------------------------------------------
  task w_loop();
    axi_txn t;
    time    t_last = -1;
    forever begin
      wait (w_q.size() > 0);
      t = w_q[0];               // stays queued until the last beat is accepted
      sync(t_last);
      for (int i = 0; i < t.beats(); i++) begin
        repeat (t.beat_gap[i]) @(vif.cb);
        vif.wdata  <= t.data[i];
        vif.wstrb  <= t.strb[i];
        vif.wlast  <= (i == t.beats() - 1);
        vif.wvalid <= 1'b1;
        @(vif.cb);
        while (!vif.cb.wready) @(vif.cb);
        vif.wvalid <= 1'b0;
        vif.wlast  <= 1'b0;
      end
      void'(w_q.pop_front());
      t_last = $time;
    end
  endtask

  // ---------------------------------------------------------------------------
  task ar_loop();
    axi_txn t;
    time    t_last = -1;
    forever begin
      wait (ar_q.size() > 0);
      t = ar_q[0];              // stays queued until accepted (flush can abort it)
      t.data = new[t.beats()];
      t.resp = new[t.beats()];
      sync(t_last);
      repeat (t.req_delay) @(vif.cb);
      vif.arid    <= t.id;
      vif.araddr  <= t.addr;
      vif.arlen   <= t.len;
      vif.arsize  <= t.size;
      vif.arburst <= t.burst;
      vif.arvalid <= 1'b1;
      @(vif.cb);
      while (!vif.cb.arready) @(vif.cb);
      vif.arvalid <= 1'b0;
      t_last  = $time;
      t.t_req = $time;
      void'(ar_q.pop_front());
      rd_pend.push_back(t);
    end
  endtask

  // ---------------------------------------------------------------------------
  task b_loop();
    axi_txn t;
    int     idx;
    forever begin
      vif.bready <= !axi_chance(cfg.bready_low_pct);
      @(vif.cb);
      if (vif.cb.bvalid && vif.cb.bready) begin
        idx = -1;
        foreach (wr_pend[i]) if (idx < 0 && wr_pend[i].id == vif.cb.bid) idx = i;
        if (idx < 0) begin
          n_err++;
          $error("[%s] B response with BID=%0h but no outstanding write has that ID", name, vif.cb.bid);
        end else begin
          t = wr_pend[idx];
          wr_pend.delete(idx);
          t.resp    = new[1];
          t.resp[0] = vif.cb.bresp;
          t.rsp_id  = vif.cb.bid;
          t.t_end   = $time;
          t.done    = 1'b1;
          outstanding--;
          n_wr_done++;
        end
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  task r_loop();
    axi_txn t;
    int     idx;
    forever begin
      vif.rready <= !axi_chance(cfg.rready_low_pct);
      @(vif.cb);
      if (vif.cb.rvalid && vif.cb.rready) begin
        idx = -1;
        foreach (rd_pend[i]) if (idx < 0 && rd_pend[i].id == vif.cb.rid) idx = i;
        if (idx < 0) begin
          n_err++;
          $error("[%s] R beat with RID=%0h but no outstanding read has that ID", name, vif.cb.rid);
        end else begin
          t = rd_pend[idx];
          if (t.beat_cnt < t.beats()) begin
            t.data[t.beat_cnt] = vif.cb.rdata;
            t.resp[t.beat_cnt] = vif.cb.rresp;
          end
          t.rsp_id = vif.cb.rid;
          t.beat_cnt++;
          if (vif.cb.rlast || t.beat_cnt >= t.beats()) begin
            rd_pend.delete(idx);
            t.t_end = $time;
            t.done  = 1'b1;
            outstanding--;
            n_rd_done++;
          end
        end
      end
    end
  endtask

endclass
`endif // AXI_MASTER_DRIVER_SV
