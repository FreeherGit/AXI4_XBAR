`ifndef AXI_DECERR_BACKLOG_TEST_SV
`define AXI_DECERR_BACKLOG_TEST_SV

// =============================================================================
// axi_decerr_backlog_test  -  fill the internal DECERR responder
//
//   A master sends 10 unmapped requests while it does NOT take responses
//   (BREADY or RREADY held low for 60 clocks). Expected: the first 8 are
//   accepted (FIFO depth / per-ID limit 8), the rest wait; once READY goes
//   high, all 10 are answered DECERR with the right ID.
//   Done for M0 and M1, writes and reads, same ID and different IDs.
// =============================================================================
class axi_decerr_backlog_test extends axi_base_test;

  function new(string name = "axi_decerr_backlog_test");
    super.new(name);
  endfunction

  virtual function void configure();
    scenario_setup();
  endfunction

  virtual task main();
    axi_txn    q[$];
    axi_txn    t;
    axi_kind_e k;
    string     rdy;     // "B" for writes, "R" for reads
    string     what;

    for (int m = 0; m < NUM_M; m++)
      for (int kk = 0; kk < 2; kk++)
        for (int round = 0; round < 2; round++) begin
          k = kind_of(kk);
          if (k == AXI_WRITE) rdy = "B";
          else                rdy = "R";
          if (round == 0) what = $sformatf("M%0d 10 unmapped %ss, same ID %0h, %sREADY low 60 clocks",
                                           m, kind_name(k), 8 * m + 5, rdy);
          else            what = $sformatf("M%0d 10 unmapped %ss, IDs 0-9, %sREADY low 60 clocks",
                                           m, kind_name(k), rdy);
          title(what);
          q.delete();
          set_ready_low(rdy, m, 100);
          wait_clk(1);
          for (int i = 0; i < 10; i++) begin
            if (round == 0) t = new_txn(k, 8 * m + 5, scratch(2) + 32'h100 * i, 1);
            else            t = new_txn(k, i,         scratch(2) + 32'h100 * i, 1);
            q.push_back(t);
            send(m, t);
          end
          wait_clk(60);
          set_ready_low(rdy, m, 0);
          check_list(what, q);
        end

    prove("the DECERR responder accepts 8 requests, holds the rest, and answers all with DECERR and the right ID");
  endtask

endclass

`endif
