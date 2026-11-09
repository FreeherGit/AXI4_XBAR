`ifndef AXI_RANDOM_MIX_TEST_SV
`define AXI_RANDOM_MIX_TEST_SV

// =============================================================================
// axi_random_mix_test  -  random traffic, both masters share ALL IDs
//
//   60 random transactions per master (up to 64 beats, sparse strobes),
//   30 % backpressure everywhere, slave latency 0-10, SLVERR windows as in
//   axi_stress_test. Unlike the other tests BOTH masters use IDs 0-F.
//   Checked: every transaction got the response the reference model expects
//   and its own ID back (plus the scoreboard checks).
// =============================================================================
class axi_random_mix_test extends axi_base_test;

  function new(string name = "axi_random_mix_test");
    super.new(name);
    timeout_ns = 20_000_000;
  endfunction

  virtual function void configure();
    scenario_setup();
    for (int m = 0; m < NUM_M; m++) begin
      env.m_cfg[m].set_backpressure(30);
      env.m_cfg[m].max_outstanding = 8;
    end
    for (int s = 0; s < NUM_S; s++) begin
      env.s_cfg[s].set_backpressure(30);
      env.s_cfg[s].b_latency_max = 10;
      env.s_cfg[s].r_latency_max = 10;
    end
    env.s_cfg[0].err_en = 1;  env.s_cfg[0].err_lo = 32'h0000_E000;  env.s_cfg[0].err_hi = 32'h0000_EFFF;
    env.s_cfg[1].err_en = 1;  env.s_cfg[1].err_lo = 32'h1000_E000;  env.s_cfg[1].err_hi = 32'h1000_EFFF;
  endfunction

  virtual task main();
    axi_rand_gen g0, g1;
    axi_txn      all[$];

    title("Random mix: sparse strobes, 30 % backpressure, latency 0-10, shared IDs");
    g0 = new("mix_m0");  g0.num_txns = 60;  g0.max_len = 63;  g0.sparse_strb = 1;
    g1 = new("mix_m1");  g1.num_txns = 60;  g1.max_len = 63;  g1.sparse_strb = 1;
    quiet(g0);
    quiet(g1);
    fork
      g0.start(env.m_agt[0]);
      g1.start(env.m_agt[1]);
    join

    foreach (g0.sent[i]) all.push_back(g0.sent[i]);
    foreach (g1.sent[i]) all.push_back(g1.sent[i]);
    check_list("120 random transactions", all);

    prove("under backpressure, latency, sparse strobes and shared IDs, all random traffic is routed, stored and answered correctly");
  endtask

endclass

`endif
