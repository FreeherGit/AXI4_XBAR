`ifndef AXI_ARBITRATION_TEST_SV
`define AXI_ARBITRATION_TEST_SV

// =============================================================================
// axi_arbitration_test  (TC-07)  -  arbitration / round robin
//
//   IDEA : when both masters want the SAME slave, the crossbar (arbiter)
//          decides who goes first. It must be fair (round robin): nobody
//          waits forever, and on a tie the master served last loses.
//
//   The "grant time" of a request is t_req = the clock when the crossbar
//   accepted its AW / AR.
//
//   STEP 1 : M0 and M1 each send 8 writes to S0 at the same time
//   STEP 2 : M0 and M1 each send 8 reads from S1 at the same time
//            CHECK: all 16 finish, and each master got a grant BEFORE the
//                   other master's last grant (both were served, mixed)
//   STEP 3 : round-robin tie: first one master is served alone, then both
//            request S1 in the same clock
//            CHECK: the OTHER master wins the tie
// =============================================================================
class axi_arbitration_test extends axi_base_test;

  function new(string name = "axi_arbitration_test");
    super.new(name);
  endfunction

  // both masters send 8 requests (k = WRITE or READ) to slave s at the same time
  task share_slave(axi_kind_e k, int s);
    axi_txn q0[$], q1[$];   // M0's and M1's requests
    axi_txn t;
    string  order;
    int     i, j;

    for (int n = 0; n < 8; n++) begin
      t = new_txn(k, n,     slave_base(s) + 32'hA000 + 32'h40 * n, 3);   // M0: IDs 0-7
      q0.push_back(t);
      send(0, t);
      t = new_txn(k, 8 + n, slave_base(s) + 32'hB000 + 32'h40 * n, 3);   // M1: IDs 8-F
      q1.push_back(t);
      send(1, t);
    end
    wait_list(q0);
    wait_list(q1);

    // grant order: merge the two lists by grant time (0 = M0, 1 = M1)
    order = "";
    i = 0;
    j = 0;
    while (i < 8 || j < 8) begin
      if (j == 8 || (i < 8 && q0[i].t_req < q1[j].t_req)) begin
        order = {order, "0"};
        i++;
      end else begin
        order = {order, "1"};
        j++;
      end
    end
    info($sformatf("%s grant order at S%0d (0 = M0, 1 = M1): %s", kind_name(k), s, order));

    check(q1[0].t_req < q0[7].t_req && q0[0].t_req < q1[7].t_req,
          $sformatf("%ss to S%0d: both masters were granted while the other still had requests (no starvation)",
                    kind_name(k), s));
  endtask

  virtual task main();
    axi_txn solo, a, b;

    // ------------------------------------------------------------------ STEP 1
    title("STEP 1 : M0 and M1 both send 8 writes to S0 at the same time");
    share_slave(AXI_WRITE, 0);

    // ------------------------------------------------------------------ STEP 2
    title("STEP 2 : M0 and M1 both send 8 reads to S1 at the same time");
    share_slave(AXI_READ, 1);

    // ------------------------------------------------------------------ STEP 3
    title("STEP 3 : round-robin tie at S1");
    for (int last = 0; last < 2; last++) begin
      // 1) master 'last' writes S1 alone -> it is now the most recent winner
      solo = new_write(8 * last, 32'h1000_E000 + 32'h100 * last);
      send_wait(last, solo);
      wait_clk(3);
      // 2) both masters request S1 in the same clock
      a = new_write(4'h1, 32'h1000_C000 + 32'h100 * last, 1);
      b = new_write(4'h9, 32'h1000_D000 + 32'h100 * last, 1);
      send(0, a);
      send(1, b);
      wait_done(a);
      wait_done(b);
      info($sformatf("M%0d was served alone first; tie grant times: M0 %0t, M1 %0t", last, a.t_req, b.t_req));
      if (last == 0) check(b.t_req < a.t_req, "M0 was served last, so M1 wins the tie");
      else           check(a.t_req < b.t_req, "M1 was served last, so M0 wins the tie");
      wait_clk(3);
    end

    prove("when both masters use the same slave, both are served (no deadlock, no starvation)");
    prove("grants are mixed between the masters, for writes (S0) and reads (S1)");
    prove("on a same-clock tie the master served last loses (round robin, not fixed priority)");
  endtask

endclass

`endif // AXI_ARBITRATION_TEST_SV
