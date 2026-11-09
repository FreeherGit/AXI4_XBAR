`ifndef AXI_BAD_ID_TEST_SV
`define AXI_BAD_ID_TEST_SV

// =============================================================================
// axi_bad_id_test  (TC-14)  -  response with an unknown ID (error injection)
//
//   IDEA : a broken slave sends a B or R with an ID that no master is waiting
//          for ("stray" response). The crossbar must:
//            1. accept it (READY high), so the slave does not hang
//            2. NOT pass it to any master
//            3. keep working normally afterwards
//
//   Uses the stray knobs of the slave driver (stray_b_q / stray_r_q) and of
//   the slave monitor (stray_ok_b / stray_ok_r = "this stray is expected").
//
//   STEP 1 : each slave sends one stray B (ID 5) and one stray R (ID F)
//            CHECK: the slave saw the handshake, no master saw a VALID
//   STEP 2 : write + read-back on all 4 paths
//            CHECK: data correct, scoreboard found no error
// =============================================================================
class axi_bad_id_test extends axi_base_test;

  function new(string name = "axi_bad_id_test");
    super.new(name);
  endfunction

  // count the clocks (out of n) where M0 or M1 sees BVALID or RVALID
  task count_master_valids(int unsigned n, output int unsigned seen);
    seen = 0;
    repeat (n) begin
      wait_clk(1);
      for (int m = 0; m < NUM_M; m++)
        if (env.m_vif[m].cb.bvalid || env.m_vif[m].cb.rvalid) seen++;
    end
  endtask

  // slave s sends ONE stray response: is_r = 0 -> B, is_r = 1 -> R
  task send_stray(int s, bit is_r, bit [AXI_IDW-1:0] sid);
    int unsigned n_before, n_after, seen;   // stray handshake counter before / after
    string       ch;

    if (is_r) begin
      ch       = "R";
      n_before = env.s_agt[s].drv.n_stray_r;
      env.s_agt[s].mon.stray_ok_r++;               // the monitor should expect it
      env.s_agt[s].drv.stray_r_q.push_back(sid);   // the driver sends it
    end else begin
      ch       = "B";
      n_before = env.s_agt[s].drv.n_stray_b;
      env.s_agt[s].mon.stray_ok_b++;
      env.s_agt[s].drv.stray_b_q.push_back(sid);
    end

    count_master_valids(20, seen);

    if (is_r) n_after = env.s_agt[s].drv.n_stray_r;
    else      n_after = env.s_agt[s].drv.n_stray_b;

    check_num($sformatf("S%0d stray %s ID %0h : accepted by the crossbar (handshakes)", s, ch, sid),
              n_after - n_before, 1);
    check_num($sformatf("S%0d stray %s ID %0h : clocks it was seen at a master", s, ch, sid),
              seen, 0);
  endtask

  virtual task main();
    int unsigned err_before;

    err_before = env.sb.n_err;

    // ------------------------------------------------------------------ STEP 1
    title("STEP 1 : stray B and stray R from each slave (crossbar idle)");
    for (int s = 0; s < NUM_S; s++) begin
      env.wait_idle();
      send_stray(s, 1'b0, 4'h5);
      env.wait_idle();
      send_stray(s, 1'b1, 4'hF);
    end

    // ------------------------------------------------------------------ STEP 2
    title("STEP 2 : every path still works after the stray responses");
    for (int m = 0; m < NUM_M; m++)
      for (int s = 0; s < NUM_S; s++)
        write_read(m, 8 * m + 1, slave_base(s) + 32'h0E20_0000 + 32'h1000 * m, 7,
                   3, BURST_INCR, "(after the strays)");

    env.wait_idle();
    for (int s = 0; s < NUM_S; s++) begin
      check_num($sformatf("S%0d stray B expected but not seen", s), env.s_agt[s].mon.stray_ok_b, 0);
      check_num($sformatf("S%0d stray R expected but not seen", s), env.s_agt[s].mon.stray_ok_r, 0);
    end
    check_num("scoreboard errors during this test", env.sb.n_err - err_before, 0);

    prove("a B or R with an unknown ID is accepted by the crossbar (the slave never hangs)");
    prove("such a stray response is never passed to M0 or M1");
    prove("all master->slave paths work normally after stray responses");
  endtask

endclass

`endif // AXI_BAD_ID_TEST_SV
