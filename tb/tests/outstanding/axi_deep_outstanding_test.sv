`ifndef AXI_DEEP_OUTSTANDING_TEST_SV
`define AXI_DEEP_OUTSTANDING_TEST_SV

// =============================================================================
// axi_deep_outstanding_test  -  10 transactions with the SAME ID in flight
//
//   Slaves answer after 40 clocks. M0 sends 10 x ID 2 to one slave and at the
//   same time M1 sends 10 x ID A to the other slave (writes, then reads).
//   Expected: the crossbar keeps at most 8 per (slave, ID) (MAXOUT = 8), the
//   9th and 10th wait, and every response returns in order with the right ID.
// =============================================================================
class axi_deep_outstanding_test extends axi_base_test;

  function new(string name = "axi_deep_outstanding_test");
    super.new(name);
  endfunction

  virtual function void configure();
    scenario_setup();
  endfunction

  virtual task main();
    axi_txn q[$];
    axi_txn t;
    set_all_latency(40);
    for (int k = 0; k < 2; k++)
      for (int tg = 0; tg < NUM_S; tg++) begin
        title($sformatf("M0: 10 x ID 2 -> %s  ||  M1: 10 x ID A -> %s  (%ss, latency 40)",
                        tgt_name(tg), tgt_name(1 - tg), kind_name(kind_of(k))));
        q.delete();
        wait_clk(1);
        for (int i = 0; i < 10; i++) begin
          t = new_txn(kind_of(k), 4'h2, scratch(tg)     + 32'h0060_0000 + 32'h100 * i, 1);
          q.push_back(t);
          send(0, t);
          t = new_txn(kind_of(k), 4'hA, scratch(1 - tg) + 32'h0068_0000 + 32'h100 * i, 1);
          q.push_back(t);
          send(1, t);
        end
        check_list($sformatf("10 + 10 same-ID %ss", kind_name(kind_of(k))), q);
      end
    set_all_latency(0);
    prove("with 10 same-ID transactions in flight the crossbar keeps at most 8 per (slave, ID), holds the rest, and returns every response with the right ID");
  endtask

endclass

`endif
