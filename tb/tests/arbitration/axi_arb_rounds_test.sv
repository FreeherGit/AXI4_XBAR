`ifndef AXI_ARB_ROUNDS_TEST_SV
`define AXI_ARB_ROUNDS_TEST_SV

// =============================================================================
// axi_arb_rounds_test  -  same-clock requests to every target
//
//   Part A : both masters request the SAME target (S0, S1, UNMAPPED) in the
//            SAME clock, 4 rounds per target, writes and reads
//   Part B : the same to S0 and S1 while the slaves hold AWREADY / ARREADY
//            low 70 % of the time -> the grant must stay locked until the
//            request is accepted
//   Checked for every transaction: response == reference model, ID echoed.
// =============================================================================
class axi_arb_rounds_test extends axi_base_test;

  function new(string name = "axi_arb_rounds_test");
    super.new(name);
  endfunction

  virtual function void configure();
    scenario_setup();
  endfunction

  // M0 (ID id0) and M1 (ID id1) send one 2-beat transaction each to the
  // same target in the same clock
  task same_clock(axi_kind_e k, bit [AXI_IDW-1:0] id0, bit [AXI_AW-1:0] a0,
                  bit [AXI_IDW-1:0] id1, bit [AXI_AW-1:0] a1, string what);
    axi_txn q[$];
    axi_txn t;
    wait_clk(1);
    t = new_txn(k, id0, a0, 1);  q.push_back(t);  send(0, t);
    t = new_txn(k, id1, a1, 1);  q.push_back(t);  send(1, t);
    check_list(what, q);
  endtask

  virtual task main();
    axi_kind_e k;

    title("PART A : M0 + M1 to the same target in the same clock, 4 rounds each");
    for (int kk = 0; kk < 2; kk++)
      for (int tg = 0; tg < 3; tg++)
        for (int r = 0; r < 4; r++) begin
          k = kind_of(kk);
          same_clock(k, 4'h1, scratch(tg) + 32'h0070_0000 + 32'h40 * r,
                        4'h9, scratch(tg) + 32'h0078_0000 + 32'h40 * r,
                     $sformatf("round %0d: M0 + M1 %s -> %s same clock", r, kind_name(k), tgt_name(tg)));
        end

    title("PART B : the same while S0 and S1 hold AWREADY / ARREADY low 70 % of the time");
    for (int s = 0; s < NUM_S; s++) begin
      set_ready_low("AW", s, 70);
      set_ready_low("AR", s, 70);
    end
    for (int kk = 0; kk < 2; kk++)
      for (int tg = 0; tg < NUM_S; tg++)
        for (int r = 0; r < 2; r++) begin
          k = kind_of(kk);
          same_clock(k, 4'h3, scratch(tg) + 32'h007C_0000 + 32'h40 * r,
                        4'hB, scratch(tg) + 32'h007E_0000 + 32'h40 * r,
                     $sformatf("locked round %0d: M0 + M1 %s -> %s", r, kind_name(k), tgt_name(tg)));
        end

    prove("when both masters ask for the same target in the same clock, both are served");
    prove("the grant stays stable while the target is not ready, and every response returns to its own master");
  endtask

endclass

`endif
