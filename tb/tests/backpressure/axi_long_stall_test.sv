`ifndef AXI_LONG_STALL_TEST_SV
`define AXI_LONG_STALL_TEST_SV

// =============================================================================
// axi_long_stall_test  -  one READY held low for 14 clocks
//
//   One channel of one port at a time:
//     AWREADY / WREADY / ARREADY of S0 and of S1 (both masters send to it)
//     BREADY / RREADY of M0 and of M1 (that master sends to S0 and S1)
//   READY is held low for 14 clocks while the traffic waits, then released.
//   Checked: every transaction finishes with the right response and ID
//   (the protocol checker also checks VALID and payload stayed stable).
// =============================================================================
class axi_long_stall_test extends axi_base_test;

  function new(string name = "axi_long_stall_test");
    super.new(name);
  endfunction

  virtual function void configure();
    scenario_setup();
  endfunction

  virtual task main();
    string     slave_ch[3]  = '{"AW", "W", "AR"};
    string     master_ch[2] = '{"B", "R"};
    axi_txn    q[$];
    axi_txn    t;
    axi_kind_e k;

    title("READY at a SLAVE port held low for 14 clocks");
    for (int s = 0; s < NUM_S; s++)
      for (int c = 0; c < 3; c++) begin
        if (slave_ch[c] == "AR") k = AXI_READ;
        else                     k = AXI_WRITE;
        q.delete();
        set_ready_low(slave_ch[c], s, 100);
        wait_clk(1);
        for (int m = 0; m < NUM_M; m++)
          for (int i = 0; i < 2; i++) begin
            t = new_txn(k, 8 * m + 1 + i, scratch(s) + 32'h0080_0000 + 32'h1000 * m + 32'h100 * i, 3);
            q.push_back(t);
            send(m, t);
          end
        wait_clk(14);
        set_ready_low(slave_ch[c], s, 0);
        check_list($sformatf("S%0d %sREADY low 14 clocks, 4 %ss waiting", s, slave_ch[c], kind_name(k)), q);
      end

    title("READY at a MASTER port held low for 14 clocks");
    for (int m = 0; m < NUM_M; m++)
      for (int c = 0; c < 2; c++) begin
        if (master_ch[c] == "R") k = AXI_READ;
        else                     k = AXI_WRITE;
        q.delete();
        set_ready_low(master_ch[c], m, 100);
        wait_clk(1);
        for (int tg = 0; tg < NUM_S; tg++) begin
          t = new_txn(k, 8 * m + 1 + tg, scratch(tg) + 32'h0088_0000 + 32'h1000 * m, 3);
          q.push_back(t);
          send(m, t);
        end
        wait_clk(14);
        set_ready_low(master_ch[c], m, 0);
        check_list($sformatf("M%0d %sREADY low 14 clocks, %ss to S0 and S1 waiting", m, master_ch[c], kind_name(k)), q);
      end

    prove("a READY held low for 14 clocks on any channel of any port only delays the traffic; nothing is lost or misrouted");
  endtask

endclass

`endif
