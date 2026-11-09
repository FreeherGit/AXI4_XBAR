`ifndef AXI_OUTSTANDING_TEST_SV
`define AXI_OUTSTANDING_TEST_SV

// =============================================================================
// axi_outstanding_test  (TC-06)  -  multiple outstanding transactions
//
//   IDEA : a master does not have to wait for one answer before it sends the
//          next request ("outstanding" transactions). The crossbar must keep
//          track of all of them and route every answer back correctly.
//
//   SETUP: slaves answer slowly (up to 12 clocks), masters may have 8 in flight.
//   M0 -> S0 and M1 -> S1 run the same flow at the same time:
//     STEP 1 : 8 writes sent back-to-back, each with its own ID
//              CHECK: every BID = AWID, all OKAY, at least 4 were in flight
//     STEP 2 : 8 reads with the SAME ID sent back-to-back
//              CHECK: they finish in the order they were sent and each one
//                     returns the data of its own write
//
//   "In flight" is measured from the transaction times:
//     t_req = clock when the request (AW / AR) was accepted
//     t_end = clock when the answer (B / last R) came back
// =============================================================================
class axi_outstanding_test extends axi_base_test;

  function new(string name = "axi_outstanding_test");
    super.new(name);
  endfunction

  virtual function void configure();
    for (int m = 0; m < NUM_M; m++) env.m_cfg[m].max_outstanding = 8;
    for (int s = 0; s < NUM_S; s++) begin
      env.s_cfg[s].b_latency_max = 12;
      env.s_cfg[s].r_latency_max = 12;
      env.s_cfg[s].slave_depth   = 8;
    end
  endfunction

  // largest number of transactions in q that were in flight at the same time
  function int max_in_flight(axi_txn q[$]);
    int best = 0;
    int n;
    foreach (q[i]) begin
      n = 0;                       // how many were busy when q[i] was accepted
      foreach (q[j])
        if (q[j].t_req <= q[i].t_req && q[i].t_req < q[j].t_end) n++;
      if (n > best) best = n;
    end
    return best;
  endfunction

  task master_flow(int m);
    bit [AXI_AW-1:0] base;
    axi_txn          wr[$], rd[$];
    axi_txn          t;
    bit              in_order;

    base = slave_base(m) + 32'h0002_0000;     // M0 uses S0, M1 uses S1

    // ---------------------------------------------------------------- STEP 1
    for (int i = 0; i < 8; i++) begin
      t = new_write(8 * m + i, base + 32'h100 * i, 3);
      wr.push_back(t);
      send(m, t);                   // do NOT wait for the answer
    end
    wait_list(wr);
    foreach (wr[i]) begin
      check_val ($sformatf("M%0d write %0d : BID", m, i), wr[i].rsp_id, wr[i].id);
      check_resp($sformatf("M%0d write %0d : BRESP", m, i), wr[i].resp[0], RESP_OKAY);
    end
    check_min($sformatf("M%0d writes in flight at the same time", m), max_in_flight(wr), 4);

    // ---------------------------------------------------------------- STEP 2
    for (int i = 0; i < 8; i++) begin
      t = new_read(8 * m + 5, base + 32'h100 * i, 3);   // same ID for all 8
      rd.push_back(t);
      send(m, t);
    end
    wait_list(rd);

    in_order = 1;
    for (int i = 1; i < 8; i++)
      if (rd[i].t_end <= rd[i-1].t_end) in_order = 0;
    check(in_order, $sformatf("M%0d: 8 same-ID reads finished in the order they were sent", m));
    foreach (rd[i])
      check_data($sformatf("M%0d same-ID read %0d returns its own write", m, i), wr[i], rd[i]);
    check_min($sformatf("M%0d reads in flight at the same time", m), max_in_flight(rd), 2);
  endtask

  virtual task main();
    title("M0 -> S0 and M1 -> S1 in parallel, up to 8 outstanding each");
    fork
      master_flow(0);
      master_flow(1);
    join
    prove("each master can have several writes and several reads outstanding at once");
    prove("every response goes back with the right ID (BID = AWID, RID = ARID)");
    prove("reads with the same ID come back in the order they were sent");
  endtask

endclass

`endif // AXI_OUTSTANDING_TEST_SV
