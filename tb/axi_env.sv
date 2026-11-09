`ifndef AXI_ENV_SV
`define AXI_ENV_SV

// =============================================================================
// axi_env.sv  (included inside axi_tb_pkg)
//   Environment: 2 master agents, 2 slave agents, reference model,
//   scoreboard, coverage. Two-step construction so a test can change the
//   agent configs between new() and build():
//       env = new();               // creates the cfg objects only
//       env.m_cfg[0].max_outstanding = 8;   // (test configure())
//       env.build();               // creates components with those cfgs
//       env.run();                 // starts all threads
//
//   report(): scoreboard summary + a SHORT coverage summary.
//             +COV_DETAIL prints the full table of every coverage bin.
// =============================================================================

class axi_env;

  virtual axi_if      m_vif[NUM_M];
  virtual axi_if      s_vif[NUM_S];
  virtual axi_rst_if  rst_vif;

  axi_agent_cfg       m_cfg[NUM_M];
  axi_agent_cfg       s_cfg[NUM_S];

  axi_master_agent    m_agt[NUM_M];
  axi_slave_agent     s_agt[NUM_S];
  axi_ref_model       rm;
  axi_scoreboard      sb;
  axi_coverage        cov;

  function new();
    for (int i = 0; i < NUM_M; i++) m_cfg[i] = new($sformatf("M%0d", i), 1'b1, i);
    for (int i = 0; i < NUM_S; i++) s_cfg[i] = new($sformatf("S%0d", i), 1'b0, i);
  endfunction

  function void build();
    rm = new();
    for (int s = 0; s < NUM_S; s++) rm.s_cfg[s] = s_cfg[s];
    sb  = new(rm);
    cov = new(rm);
    for (int m = 0; m < NUM_M; m++) begin
      m_agt[m] = new($sformatf("M%0d", m), m_cfg[m], m_vif[m]);
      m_agt[m].mon.connect(sb.m_mbx[m]);
      m_agt[m].mon.connect(cov.mbx);
      cov.m_vif[m] = m_vif[m];
    end
    for (int s = 0; s < NUM_S; s++) begin
      s_agt[s] = new($sformatf("S%0d", s), s_cfg[s], s_vif[s]);
      s_agt[s].mon.connect(sb.s_mbx[s]);
      cov.s_vif[s] = s_vif[s];
    end
  endfunction

  task run();
    foreach (m_agt[i]) m_agt[i].run();
    foreach (s_agt[i]) s_agt[i].run();
    sb.run();
    cov.run();
    fork
      reset_watch();
    join_none
  endtask

  // Tell the scoreboard about every reset assertion. Writes that were cut by
  // the reset may have partly reached a slave memory: tell the ref model.
  task reset_watch();
    axi_monitor mon;
    forever begin
      wait (rst_vif.arst_n === 1'b0);
      foreach (m_agt[i]) begin
        mon = m_agt[i].mon;
        foreach (mon.wr_pend[j]) rm.write_unknown(mon.wr_pend[j], $time);
      end
      sb.on_reset();
      wait (rst_vif.arst_n === 1'b1);
    end
  endtask

  function bit idle();
    foreach (m_agt[i]) if (!m_agt[i].idle()) return 0;
    foreach (s_agt[i]) if (!s_agt[i].idle()) return 0;
    if (sb.pending()) return 0;
    return 1;
  endfunction

  // Wait until all traffic has finished (checked every clock)
  task wait_idle(int unsigned settle_cycles = 5);
    int unsigned quiet = 0;
    while (quiet < settle_cycles) begin
      @(m_vif[0].cb);
      quiet = idle() ? quiet + 1 : 0;
    end
  endtask

  // Debug print: what is still in flight (printed automatically on timeout)
  function void print_state();
    $display("---- TB state at %0t ----", $time);
    foreach (m_agt[i])
      $display("  M%0d drv: mbx=%0d outstanding=%0d aw_q=%0d w_q=%0d ar_q=%0d wr_pend=%0d rd_pend=%0d | mon: w_need=%0d wr_pend=%0d rd_pend=%0d",
               i, m_agt[i].seq_mbx.num(), m_agt[i].drv.outstanding, m_agt[i].drv.aw_q.size(),
               m_agt[i].drv.w_q.size(), m_agt[i].drv.ar_q.size(), m_agt[i].drv.wr_pend.size(),
               m_agt[i].drv.rd_pend.size(), m_agt[i].mon.w_need.size(), m_agt[i].mon.wr_pend.size(),
               m_agt[i].mon.rd_pend.size());
    foreach (s_agt[i])
      $display("  S%0d drv: aw_q=%0d b_q=%0d ar_q=%0d b_busy=%0d r_busy=%0d | mon: w_need=%0d wr_pend=%0d rd_pend=%0d",
               i, s_agt[i].drv.aw_q.size(), s_agt[i].drv.b_q.size(), s_agt[i].drv.ar_q.size(),
               s_agt[i].drv.b_busy, s_agt[i].drv.r_busy, s_agt[i].mon.w_need.size(),
               s_agt[i].mon.wr_pend.size(), s_agt[i].mon.rd_pend.size());
    foreach (sb.m_wait[p])
      $display("  SB S%0d: master-side waiting=%0d slave-side waiting=%0d", p,
               sb.m_wait[p].q.size(), sb.s_wait[p].q.size());
  endfunction

  // Short coverage summary (the covergroups themselves are not changed)
  function void cov_summary();
    cov.scan_bins(1'b0);
    $display(" FUNCTIONAL COVERAGE of this test (black-box, from the pins)");
    if (cov.txn_pct() >= 0.0) begin
      $display("   transaction : %6.2f %%", cov.txn_pct());
      $display("   cycle       : %6.2f %%", cov.cyc_pct());
      $display("   per-port    : %6.2f %%", cov.port_pct());
    end
    $display("   bins hit    : %0d of %0d   (full table: +COV_DETAIL, all tests merged: make cov_merge)",
             cov.pl_hit, cov.pl_tot);
    $display("------------------------------------------------------------------");
  endfunction

  function int unsigned report();
    sb.final_check();
    sb.report();
    if ($test$plusargs("COV_DETAIL")) cov.report();
    else                              cov_summary();
    return sb.n_err;
  endfunction

endclass
`endif // AXI_ENV_SV
