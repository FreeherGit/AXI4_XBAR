`ifndef AXI_RESET_TEST_SV
`define AXI_RESET_TEST_SV

// =============================================================================
// axi_reset_test  (TC-02 part 2)  -  reset in the middle of traffic
//
//   1. Both masters send 40 random transactions (S0 and S1 only).
//   2. When the crossbar is busy, reset is asserted BETWEEN clock edges
//      (asynchronous). While reset is low every crossbar VALID must be 0.
//   3. After reset release the crossbar must be idle (no old VALID left),
//      and every path M0->S0, M0->S1, M1->S0, M1->S1 must work again.
// =============================================================================
class axi_reset_test extends axi_reset_base;

  function new(string name = "axi_reset_test");
    super.new(name);
  endfunction

  // waits until the crossbar is busy, then pulses the reset (6 clocks)
  task reset_during_traffic();
    axi_txn tt;
    bit     ok;
    string  s;
    int     busy_cycles = 0;

    while (busy_cycles < 150) begin
      wait_clk(1);
      if (env.s_vif[0].cb.awvalid || env.s_vif[0].cb.wvalid || env.s_vif[1].cb.wvalid ||
          env.s_vif[0].cb.arvalid || env.m_vif[0].cb.rvalid || env.m_vif[1].cb.rvalid)
        busy_cycles++;
    end
    void'(valids_low(s));
    info($sformatf("just before reset : %s", s));

    #3;                                            // between clock edges -> asynchronous
    info("asserting arst_n = 0 (in the middle of a clock cycle)");
    env.rst_vif.assert_reset();
    // transactions still waiting in the master queues are dropped too
    foreach (env.m_agt[i])
      while (env.m_agt[i].seq_mbx.try_get(tt)) begin
        tt.aborted = 1'b1;
        tt.done    = 1'b1;
      end

    wait_clk(1);
    ok = valids_low(s);
    info($sformatf("1 clock into reset : %s", s));
    check(ok, "while arst_n = 0 every crossbar VALID is 0 (traffic in flight dropped)");
    wait_clk(5);
    ok = ok && valids_low(s);
    check(ok, "VALIDs stay 0 for the whole reset pulse");
    env.rst_vif.release_reset();
    info("arst_n released");
  endtask

  virtual task main();
    axi_rand_gen g0, g1;
    bit          ok;
    string       s;

    title("Reset in the middle of random traffic");
    g0 = new("rand_m0");  g0.num_txns = 40;  g0.max_len = 31;  g0.no_unmapped = 1;
    g1 = new("rand_m1");  g1.num_txns = 40;  g1.max_len = 31;  g1.no_unmapped = 1;
    quiet(g0);
    quiet(g1);
    fork
      g0.start(env.m_agt[0]);
      g1.start(env.m_agt[1]);
      reset_during_traffic();
    join
    info($sformatf("transactions cut by the reset: M0 %0d, M1 %0d (expected, they were in flight)",
                   g0.sent.size() - count_done(g0.sent), g1.sent.size() - count_done(g1.sent)));

    wait_clk(5);
    valids_low_for(5, ok, s);
    check(ok, "after reset release the crossbar is idle again (no VALID left from the old traffic)");

    title("Every path after the reset");
    all_paths_rw(32'h0004_0000);

    prove("an asynchronous reset in the middle of traffic clears every VALID immediately");
    prove("the crossbar recovers and every master->slave path works after the reset");
  endtask

endclass

`endif
