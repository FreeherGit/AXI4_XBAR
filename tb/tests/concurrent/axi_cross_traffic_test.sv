`ifndef AXI_CROSS_TRAFFIC_TEST_SV
`define AXI_CROSS_TRAFFIC_TEST_SV

// =============================================================================
// axi_cross_traffic_test  -  both masters busy at the same time
//
//   Part A : M0 and M1 talk to DIFFERENT slaves in the same clock
//            (M0->S0 || M1->S1, then crossed M0->S1 || M1->S0)
//   Part B : M0 and M1 talk to the SAME target with different IDs
//            (S0, S1 and UNMAPPED, slave latency 15)
//   Part C : one master sends to S0 and S1 in the same clock and both
//            slaves answer after 8 clocks -> two responses for ONE master
//            arrive together and must not be mixed up
//
//   Checked for every transaction: response == reference model, ID echoed.
// =============================================================================
class axi_cross_traffic_test extends axi_base_test;

  function new(string name = "axi_cross_traffic_test");
    super.new(name);
  endfunction

  virtual function void configure();
    scenario_setup();
  endfunction

  // M0 -> target tg0 and M1 -> target tg1, n transactions each, all put in
  // the queues in the same clock. M0 uses IDs 1.., M1 uses IDs 9..
  task both_masters(int tg0, int tg1, axi_kind_e k, int n, bit [7:0] len, string what);
    axi_txn q[$];
    axi_txn t;
    wait_clk(1);
    for (int i = 0; i < n; i++) begin
      t = new_txn(k, 1 + i, scratch(tg0) + 32'h0010_0000 + 32'h100 * i, len);
      q.push_back(t);
      send(0, t);
      t = new_txn(k, 9 + i, scratch(tg1) + 32'h0018_0000 + 32'h100 * i, len);
      q.push_back(t);
      send(1, t);
    end
    check_list(what, q);
  endtask

  virtual task main();
    axi_txn q[$];
    axi_txn t;

    title("PART A : M0 and M1 on DIFFERENT slaves in the same clock");
    both_masters(0, 1, AXI_WRITE, 4, 3, "M0->S0 || M1->S1, 4 writes each");
    both_masters(0, 1, AXI_READ,  4, 3, "M0->S0 || M1->S1, 4 reads each");
    both_masters(1, 0, AXI_WRITE, 4, 3, "M0->S1 || M1->S0, 4 writes each");
    both_masters(1, 0, AXI_READ,  4, 3, "M0->S1 || M1->S0, 4 reads each");

    title("PART B : M0 and M1 on the SAME target, different IDs, slave latency 15");
    set_all_latency(15);
    for (int tg = 0; tg < 3; tg++) begin
      both_masters(tg, tg, AXI_WRITE, 3, 1, $sformatf("M0 + M1 -> %s, 3 writes each", tgt_name(tg)));
      both_masters(tg, tg, AXI_READ,  3, 1, $sformatf("M0 + M1 -> %s, 3 reads each", tgt_name(tg)));
    end

    title("PART C : one master sends to S0 and S1 in the same clock, both answer after 8 clocks");
    set_all_latency(8);
    for (int m = 0; m < NUM_M; m++) begin
      for (int k = 0; k < 2; k++) begin
        q.delete();
        wait_clk(1);
        t = new_txn(kind_of(k), 8 * m + 2, scratch(0) + 32'h0020_0000 + 32'h1000 * m, 3);
        q.push_back(t);
        send(m, t);
        t = new_txn(kind_of(k), 8 * m + 3, scratch(1) + 32'h0020_0000 + 32'h1000 * m, 3);
        q.push_back(t);
        send(m, t);
        check_list($sformatf("M%0d %s to S0 and S1 together", m, kind_name(kind_of(k))), q);
      end
    end
    set_all_latency(0);

    prove("both masters work in parallel on different slaves");
    prove("both masters can share one target when they use different IDs");
    prove("one master gets responses from S0 and S1 at the same time without mixing them up");
  endtask

endclass

`endif
