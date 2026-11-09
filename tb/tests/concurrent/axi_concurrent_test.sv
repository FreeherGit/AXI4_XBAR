`ifndef AXI_CONCURRENT_TEST_SV
`define AXI_CONCURRENT_TEST_SV

// =============================================================================
// axi_concurrent_test  (TC-08)  -  parallel traffic on different paths
//
//   IDEA : a crossbar (unlike a shared bus) lets M0 and M1 talk to DIFFERENT
//          slaves at the same time. So two transfers on two paths should
//          take about as long as ONE transfer, not twice as long.
//
//   STEP 1 : time one 64-beat write alone                      -> t_single
//   STEP 2 : M0 -> S0 and M1 -> S1 write 64 beats at once       -> t_pair
//   STEP 3 : crossed: M0 -> S1 and M1 -> S0 at once
//            CHECK: t_pair < 1.5 x t_single  (one after the other would be
//                   about 2 x), and both blocks read back correctly
// =============================================================================
class axi_concurrent_test extends axi_base_test;

  function new(string name = "axi_concurrent_test");
    super.new(name);
  endfunction

  // M0 writes a0 and M1 writes a1 at the same time, then both read back
  task two_paths(string what, bit [AXI_AW-1:0] a0, bit [AXI_AW-1:0] a1, time t_single);
    axi_txn w0, w1, r0, r1;
    time    t0, t_pair;

    w0 = new_write(4'h1, a0, 63);
    w1 = new_write(4'h9, a1, 63);
    t0 = $time;
    fork
      send_wait(0, w0);
      send_wait(1, w1);
    join
    t_pair = $time - t0;
    info($sformatf("%s : two 64-beat writes together took %0t (one alone took %0t)", what, t_pair, t_single));
    check(t_pair < t_single + t_single / 2,
          $sformatf("%s: %0t < 1.5 x %0t, the two paths ran in parallel", what, t_pair, t_single));

    r0 = new_read(4'h2, a0, 63);
    r1 = new_read(4'hA, a1, 63);
    fork
      send_wait(0, r0);
      send_wait(1, r1);
    join
    check_data({what, " : M0 read back"}, w0, r0);
    check_data({what, " : M1 read back"}, w1, r1);
  endtask

  virtual task main();
    axi_txn w;
    time    t0, t_single;

    title("STEP 1 : reference - one 64-beat write alone (M0 -> S0)");
    w  = new_write(4'h0, 32'h0000_3000, 63);
    t0 = $time;
    send_wait(0, w);
    t_single = $time - t0;
    info($sformatf("one 64-beat write took %0t", t_single));

    title("STEP 2 : M0 -> S0  ||  M1 -> S1");
    two_paths("M0->S0 || M1->S1", 32'h0000_4000, 32'h1000_4000, t_single);

    title("STEP 3 : M0 -> S1  ||  M1 -> S0  (crossed)");
    two_paths("M0->S1 || M1->S0", 32'h1000_5000, 32'h0000_5000, t_single);

    prove("M0->S0 and M1->S1 run at the same time (not one after the other)");
    prove("crossed traffic M0->S1 and M1->S0 also runs at the same time");
    prove("parallel traffic keeps its data correct");
  endtask

endclass

`endif // AXI_CONCURRENT_TEST_SV
