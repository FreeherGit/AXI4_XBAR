`ifndef AXI_STRESS_TEST_SV
`define AXI_STRESS_TEST_SV

// =============================================================================
// axi_stress_test  (TC-12)  -  long random run
//
//   Both masters, every target (also unmapped), every burst type, up to 256
//   beats, sparse strobes (M0), 8 outstanding, 25 % backpressure, slave
//   latency, SLVERR windows. The scoreboard and reference model check every
//   transaction.
//   +STRESS_N=<n> transactions per master (default 150)
// =============================================================================
class axi_stress_test extends axi_base_test;

  function new(string name = "axi_stress_test");
    super.new(name);
    timeout_ns = 100_000_000;
  endfunction

  virtual function void configure();
    for (int m = 0; m < NUM_M; m++) begin
      env.m_cfg[m].set_backpressure(25);
      env.m_cfg[m].max_outstanding = 8;
    end
    for (int s = 0; s < NUM_S; s++) begin
      env.s_cfg[s].set_backpressure(25);
      env.s_cfg[s].b_latency_max = 5;
      env.s_cfg[s].r_latency_max = 5;
    end
    env.s_cfg[0].err_en = 1;  env.s_cfg[0].err_lo = 32'h0000_E000;  env.s_cfg[0].err_hi = 32'h0000_EFFF;
    env.s_cfg[1].err_en = 1;  env.s_cfg[1].err_lo = 32'h1000_E000;  env.s_cfg[1].err_hi = 32'h1000_EFFF;
  endfunction

  virtual task main();
    axi_rand_gen g0, g1;
    int          n = 150;
    void'($value$plusargs("STRESS_N=%d", n));

    title($sformatf("Random stress: %0d transactions per master", n));
    g0 = new("stress_m0");  g0.num_txns = n;  g0.sparse_strb = 1;
    g1 = new("stress_m1");  g1.num_txns = n;
    quiet(g0);
    quiet(g1);
    fork
      g0.start(env.m_agt[0]);
      g1.start(env.m_agt[1]);
    join

    check_num("M0 transactions completed", env.m_agt[0].drv.n_wr_done + env.m_agt[0].drv.n_rd_done, n);
    check_num("M1 transactions completed", env.m_agt[1].drv.n_wr_done + env.m_agt[1].drv.n_rd_done, n);

    prove("a long random mix of all features runs without deadlock");
    prove("every random transaction was routed, answered and checked correctly (see scoreboard summary)");
  endtask

endclass

`endif
