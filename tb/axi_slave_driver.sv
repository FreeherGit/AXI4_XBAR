`ifndef AXI_SLAVE_DRIVER_SV
`define AXI_SLAVE_DRIVER_SV

// =============================================================================
// axi_slave_driver.sv  (included inside axi_tb_pkg)
//   Reactive AXI4 slave (memory model) on a crossbar SLAVE port.
//   * byte-addressed sparse memory, unwritten bytes read as 0
//   * FIXED / INCR / WRAP, narrow transfers and WSTRB honoured
//   * accepts several AW / AR (cfg.slave_depth), answers them in order
//   * random READY backpressure, B/R latency, idle cycles between R beats
//   * optional SLVERR window (cfg.err_en / err_lo / err_hi)
//   * BID / RID echo AWID / ARID
//   * error injection (axi_bad_id_test): stray_b_q / stray_r_q
//       every ID pushed there is sent as ONE B (or ONE single-beat R) with
//       that ID, at a moment when no real B (or R) is waiting. No master
//       asked for it, so the crossbar must swallow it.
//   Memory is cleared on reset (the reference model is cleared too).
// =============================================================================

class axi_slave_driver;

  string            name;
  virtual axi_if    vif;
  axi_agent_cfg     cfg;

  bit [7:0]         mem [bit [AXI_AW-1:0]];

  axi_txn           aw_q[$];     // AW accepted, collecting W beats
  axi_txn           b_q[$];      // W done, waiting to send B
  axi_txn           ar_q[$];     // AR accepted, waiting to send R
  int unsigned      b_busy, r_busy;   // 1 while a B / R burst is being driven
  int unsigned      n_wr, n_rd;

  // error injection: responses with an ID nobody asked for
  bit [AXI_IDW-1:0] stray_b_q[$];   // one B per entry, sent when no real B is waiting
  bit [AXI_IDW-1:0] stray_r_q[$];   // one single-beat R per entry, sent when no real R is waiting
  int unsigned      n_stray_b, n_stray_r;

  function new(string name, axi_agent_cfg cfg, virtual axi_if vif);
    this.name = name;
    this.cfg  = cfg;
    this.vif  = vif;
  endfunction

  // ---------------------------------------------------------------------------
  function void drive_idle();
    vif.awready <= 1'b0;
    vif.wready  <= 1'b0;
    vif.bid     <= '0;   vif.bresp <= '0;  vif.bvalid <= 1'b0;
    vif.arready <= 1'b0;
    vif.rid     <= '0;   vif.rdata <= '0;  vif.rresp  <= '0;
    vif.rlast   <= 1'b0; vif.rvalid <= 1'b0;
  endfunction

  function void flush();
    aw_q.delete(); b_q.delete(); ar_q.delete();
    stray_b_q.delete(); stray_r_q.delete();
    b_busy = 0; r_busy = 0;
    mem.delete();
  endfunction

  function bit idle();
    return (aw_q.size() == 0) && (b_q.size() == 0) && (ar_q.size() == 0) &&
           (b_busy == 0) && (r_busy == 0) &&
           (stray_b_q.size() == 0) && (stray_r_q.size() == 0);
  endfunction

  // Backdoor access (tests may preload / peek memory)
  function void poke_byte(bit [AXI_AW-1:0] a, bit [7:0] v);  mem[a] = v;  endfunction
  function bit [7:0] peek_byte(bit [AXI_AW-1:0] a);
    return mem.exists(a) ? mem[a] : 8'h00;
  endfunction

  function bit [AXI_DW-1:0] read_word(bit [AXI_AW-1:0] baddr);
    bit [AXI_DW-1:0] w;
    for (int b = 0; b < AXI_SW; b++) w[8*b +: 8] = peek_byte(axi_lane_addr(baddr, b));
    return w;
  endfunction

  // ---------------------------------------------------------------------------
  task run();
    drive_idle();
    forever begin
      wait (vif.arst_n === 1'b1);
      fork
        begin
          fork
            aw_loop();
            w_loop();
            b_loop();
            ar_loop();
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

  // ---------------------------------------------------------------------------
  task aw_loop();
    axi_txn t;
    forever begin
      vif.awready <= ((aw_q.size() + b_q.size() + b_busy) < cfg.slave_depth) &&
                     !axi_chance(cfg.awready_low_pct);
      @(vif.cb);
      if (vif.cb.awvalid && vif.cb.awready) begin
        t        = new();
        t.kind   = AXI_WRITE;
        t.id     = vif.cb.awid;
        t.addr   = vif.cb.awaddr;
        t.len    = vif.cb.awlen;
        t.size   = vif.cb.awsize;
        t.burst  = vif.cb.awburst;
        t.port   = cfg.port_idx;
        t.data   = new[t.beats()];
        t.strb   = new[t.beats()];
        t.beat_cnt = 0;
        aw_q.push_back(t);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  task w_loop();
    axi_txn          t;
    bit [AXI_AW-1:0] baddr;
    bit              err;
    forever begin
      vif.wready <= (aw_q.size() > 0) && !axi_chance(cfg.wready_low_pct);
      @(vif.cb);
      if (vif.cb.wvalid && vif.cb.wready) begin
        if (aw_q.size() == 0) begin
          $error("[%s] W beat accepted with no AW (TB bug)", name);
        end else begin
          t     = aw_q[0];
          err   = cfg.is_err_addr(t.addr);
          baddr = axi_beat_addr(t.addr, t.size, t.len, t.burst, t.beat_cnt);
          if (!err) begin
            for (int b = 0; b < AXI_SW; b++)
              if (vif.cb.wstrb[b]) mem[axi_lane_addr(baddr, b)] = vif.cb.wdata[8*b +: 8];
          end
          if (t.beat_cnt < t.beats()) begin
            t.data[t.beat_cnt] = vif.cb.wdata;
            t.strb[t.beat_cnt] = vif.cb.wstrb;
          end
          t.beat_cnt++;
          if (vif.cb.wlast) begin
            void'(aw_q.pop_front());
            t.resp    = new[1];
            t.resp[0] = err ? RESP_SLVERR : RESP_OKAY;
            t.req_delay = $urandom_range(cfg.b_latency_max, cfg.b_latency_min);
            b_q.push_back(t);
            n_wr++;
          end
        end
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  task b_loop();
    axi_txn           t;
    bit [AXI_IDW-1:0] sid;
    forever begin
      if (b_q.size() == 0 && stray_b_q.size() > 0) begin
        // ---- error injection: B with an ID nobody is waiting for
        sid        = stray_b_q.pop_front();
        b_busy     = 1;
        vif.bid    <= sid;
        vif.bresp  <= RESP_OKAY;
        vif.bvalid <= 1'b1;
        @(vif.cb);
        while (!vif.cb.bready) @(vif.cb);
        vif.bvalid <= 1'b0;
        b_busy = 0;
        n_stray_b++;
      end else if (b_q.size() == 0) begin
        vif.bvalid <= 1'b0;
        @(vif.cb);
      end else begin
        t      = b_q.pop_front();
        b_busy = 1;
        repeat (t.req_delay) @(vif.cb);
        vif.bid    <= t.id;
        vif.bresp  <= t.resp[0];
        vif.bvalid <= 1'b1;
        @(vif.cb);
        while (!vif.cb.bready) @(vif.cb);
        vif.bvalid <= 1'b0;
        b_busy = 0;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  task ar_loop();
    axi_txn t;
    forever begin
      vif.arready <= ((ar_q.size() + r_busy) < cfg.slave_depth) &&
                     !axi_chance(cfg.arready_low_pct);
      @(vif.cb);
      if (vif.cb.arvalid && vif.cb.arready) begin
        t       = new();
        t.kind  = AXI_READ;
        t.id    = vif.cb.arid;
        t.addr  = vif.cb.araddr;
        t.len   = vif.cb.arlen;
        t.size  = vif.cb.arsize;
        t.burst = vif.cb.arburst;
        t.port  = cfg.port_idx;
        ar_q.push_back(t);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  task r_loop();
    axi_txn           t;
    bit [AXI_AW-1:0]  baddr;
    bit               err;
    int unsigned      gap_pct;
    bit [AXI_IDW-1:0] sid;
    forever begin
      if (ar_q.size() == 0 && stray_r_q.size() > 0) begin
        // ---- error injection: single-beat R with an ID nobody is waiting for
        sid        = stray_r_q.pop_front();
        r_busy     = 1;
        vif.rid    <= sid;
        vif.rdata  <= '0;
        vif.rresp  <= RESP_OKAY;
        vif.rlast  <= 1'b1;
        vif.rvalid <= 1'b1;
        @(vif.cb);
        while (!vif.cb.rready) @(vif.cb);
        vif.rvalid <= 1'b0;
        vif.rlast  <= 1'b0;
        r_busy = 0;
        n_stray_r++;
      end else if (ar_q.size() == 0) begin
        vif.rvalid <= 1'b0;
        vif.rlast  <= 1'b0;
        @(vif.cb);
      end else begin
        t       = ar_q.pop_front();
        r_busy  = 1;
        err     = cfg.is_err_addr(t.addr);
        gap_pct = (cfg.r_gap_pct > 90) ? 90 : cfg.r_gap_pct;
        repeat ($urandom_range(cfg.r_latency_max, cfg.r_latency_min)) @(vif.cb);
        for (int i = 0; i < t.beats(); i++) begin
          while (axi_chance(gap_pct)) begin
            vif.rvalid <= 1'b0;
            @(vif.cb);
          end
          baddr = axi_beat_addr(t.addr, t.size, t.len, t.burst, i);
          vif.rid    <= t.id;
          vif.rdata  <= err ? '0 : read_word(baddr);
          vif.rresp  <= err ? RESP_SLVERR : RESP_OKAY;
          vif.rlast  <= (i == t.beats() - 1);
          vif.rvalid <= 1'b1;
          @(vif.cb);
          while (!vif.cb.rready) @(vif.cb);
        end
        vif.rvalid <= 1'b0;
        vif.rlast  <= 1'b0;
        r_busy = 0;
        n_rd++;
      end
    end
  endtask

endclass
`endif // AXI_SLAVE_DRIVER_SV
