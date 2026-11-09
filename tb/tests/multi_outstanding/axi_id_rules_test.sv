`ifndef AXI_ID_RULES_TEST_SV
`define AXI_ID_RULES_TEST_SV

// =============================================================================
// axi_id_rules_test  -  the three ID ordering rules of the crossbar
//
//   For writes and reads, and for every target (S0, S1, UNMAPPED):
//     elsewhere : a master has ID i open at target u, then sends ID i to
//                 another target -> must wait for the first one
//     taken     : the OTHER master has ID 6 open at a target, this master
//                 asks for ID 6 at the same target -> must wait
//     drain     : the owner keeps sending ID 7 to a target while the other
//                 master waits for the same (target, ID) -> the owner must
//                 stop so the other master is not starved
//   The first transaction is kept open by holding BREADY / RREADY low for
//   20 clocks. Checked: response == reference model, ID echoed, for all.
//   (Both masters use the same IDs here on purpose.)
// =============================================================================
class axi_id_rules_test extends axi_base_test;

  function new(string name = "axi_id_rules_test");
    super.new(name);
  endfunction

  virtual function void configure();
    scenario_setup();
  endfunction

  // master m holds BREADY (write) or RREADY (read) low for n clocks
  task hold_rsp(int m, axi_kind_e k, int unsigned n);
    if (k == AXI_WRITE) set_ready_low("B", m, 100);
    else                set_ready_low("R", m, 100);
    wait_clk(n);
    set_ready_low("B", m, 0);
    set_ready_low("R", m, 0);
  endtask

  // rule 1: same ID first at target u, then at target tg
  task elsewhere(int m, axi_kind_e k, int u, int tg);
    axi_txn           q[$];
    axi_txn           t;
    bit [AXI_IDW-1:0] i;
    i = 8 * m + 4;
    fork hold_rsp(m, k, 20); join_none
    wait_clk(1);
    t = new_txn(k, i, scratch(u)  + 32'h00A0_0000 + 32'h1000 * m, 1);  q.push_back(t);  send(m, t);
    t = new_txn(k, i, scratch(tg) + 32'h00A8_0000 + 32'h1000 * m, 1);  q.push_back(t);  send(m, t);
    check_list($sformatf("elsewhere: M%0d %s ID %0h to %s, then same ID to %s (must wait)",
                         m, kind_name(k), i, tgt_name(u), tgt_name(tg)), q);
  endtask

  // rule 2: master o owns ID 6 at tg, master m asks for ID 6 at tg
  task taken(int m, axi_kind_e k, int tg);
    axi_txn q[$];
    axi_txn t;
    int     o;
    o = 1 - m;
    fork hold_rsp(o, k, 20); join_none
    wait_clk(1);
    t = new_txn(k, 4'h6, scratch(tg) + 32'h00B0_0000 + 32'h1000 * o, 1);  q.push_back(t);  send(o, t);
    wait_clk(2);
    t = new_txn(k, 4'h6, scratch(tg) + 32'h00B8_0000 + 32'h1000 * m, 1);  q.push_back(t);  send(m, t);
    check_list($sformatf("taken: M%0d owns ID 6 at %s, M%0d asks the same (must wait)", o, tgt_name(tg), m), q);
  endtask

  // rule 3: owner ow sends 3 x ID 7 to tg, the other master x waits for the same
  task drain(int ow, axi_kind_e k, int tg);
    axi_txn q[$];
    axi_txn t;
    int     x;
    x = 1 - ow;
    fork hold_rsp(ow, k, 20); join_none
    wait_clk(1);
    for (int n = 0; n < 3; n++) begin
      t = new_txn(k, 4'h7, scratch(tg) + 32'h00C0_0000 + 32'h1000 * ow + 32'h100 * n, 1);
      q.push_back(t);
      send(ow, t);
    end
    wait_clk(1);
    t = new_txn(k, 4'h7, scratch(tg) + 32'h00C8_0000 + 32'h1000 * x, 1);  q.push_back(t);  send(x, t);
    check_list($sformatf("drain: M%0d sends 3 x ID 7 to %s, M%0d waits for the same (owner must stop)",
                         ow, tgt_name(tg), x), q);
  endtask

  virtual task main();
    axi_kind_e k;
    int        u;
    for (int kk = 0; kk < 2; kk++) begin
      k = kind_of(kk);
      for (int tg = 0; tg < 3; tg++) begin
        u = (tg + 1) % 3;
        title($sformatf("%ss, target %s", kind_name(k), tgt_name(tg)));
        for (int m = 0; m < NUM_M; m++) elsewhere(m, k, u, tg);
        for (int m = 0; m < NUM_M; m++) taken(m, k, tg);
        for (int m = 0; m < NUM_M; m++) drain(m, k, tg);
      end
    end
    prove("same-ID requests to another slave wait for the first one to finish");
    prove("a request for an ID the other master owns at that target waits");
    prove("the anti-starvation drain works, and every response still returns to the right master in order");
  endtask

endclass

`endif
