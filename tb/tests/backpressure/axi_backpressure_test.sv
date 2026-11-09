`ifndef AXI_BACKPRESSURE_TEST_SV
`define AXI_BACKPRESSURE_TEST_SV

// =============================================================================
// axi_backpressure_test  (TC-09)  -  READY backpressure on every channel
//
//   IDEA : "backpressure" = the receiver holds READY low, so the sender must
//          keep VALID and the data stable and wait. The crossbar must never
//          lose, repeat or corrupt a transfer because of it.
//
//   SETUP (configure): every READY is low 50% of the time, on the slave side
//          (AWREADY, WREADY, ARREADY) and on the master side (BREADY, RREADY).
//          Slaves also answer late and leave gaps between R beats.
//
//   STEP 1 : directed write + read-back on all 4 paths (M0/M1 -> S0/S1)
//   STEP 2 : 60 random transactions per master, both masters at once
//            CHECK: the scoreboard found no new error
// =============================================================================
class axi_backpressure_test extends axi_base_test;

  function new(string name = "axi_backpressure_test");
    super.new(name);
    timeout_ns = 20_000_000;
  endfunction

  virtual function void configure();
    for (int m = 0; m < NUM_M; m++) begin
      env.m_cfg[m].set_backpressure(50);     // BREADY / RREADY low 50%
      env.m_cfg[m].max_outstanding = 6;
    end
    for (int s = 0; s < NUM_S; s++) begin
      env.s_cfg[s].set_backpressure(50);     // AWREADY / WREADY / ARREADY low 50%
      env.s_cfg[s].b_latency_max = 6;
      env.s_cfg[s].r_latency_max = 6;
    end
  endfunction

  virtual task main();
    axi_rand_gen g0, g1;
    int unsigned err_before;

    // ------------------------------------------------------------------ STEP 1
    title("STEP 1 : write + read-back (16 beats) on every path, with backpressure");
    for (int m = 0; m < NUM_M; m++)
      for (int s = 0; s < NUM_S; s++)
        write_read(m, 8 * m + 1, slave_base(s) + 32'h0003_0000 + 32'h1000 * m, 15,
                   3, BURST_INCR, "(50% backpressure)");

    // ------------------------------------------------------------------ STEP 2
    title("STEP 2 : random traffic from both masters (60 each)");
    err_before = env.sb.n_err;
    g0 = new("bp_m0");  g0.num_txns = 60;  g0.max_len = 31;
    g1 = new("bp_m1");  g1.num_txns = 60;  g1.max_len = 31;
    quiet(g0);
    quiet(g1);
    fork
      g0.start(env.m_agt[0]);
      g1.start(env.m_agt[1]);
    join
    check_num("scoreboard errors during the random traffic", env.sb.n_err - err_before, 0);

    prove("READY low on any channel only delays a transfer, it is never lost or duplicated");
    prove("data and responses stay correct under heavy backpressure on all 4 paths");
  endtask

endclass

`endif // AXI_BACKPRESSURE_TEST_SV
