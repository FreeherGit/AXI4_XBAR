`ifndef AXI_W_ORDER_FILL_TEST_SV
`define AXI_W_ORDER_FILL_TEST_SV

// =============================================================================
// axi_w_order_fill_test - W-order FIFO capacity and write-data ordering
//
// PART A:
//   S0/S1 holds WREADY = 0.
//   One master sends 10 writes to its target.
//
//   Expected:
//     First 8 AW transactions accepted.
//     9th and 10th AW transactions wait.
//     After WREADY returns, all 10 complete.
//
//   M0 -> S0
//   M1 -> S1
//
// PART B:
//   S0 holds WREADY = 0.
//
//   M0:
//     1 write to S0 (blocked)
//     4 writes to UNMAPPED
//
//   M1:
//     5 writes to UNMAPPED
//
//   Expected:
//     M0's earlier write-data sequence must not be bypassed.
//     M1's writes remain pending while the earlier sequence is blocked.
//     All DECERR responses and IDs are checked after release.
//
// PART C:
//   S0 holds WREADY = 0.
//
//   M0:
//     1 blocking write to S0
//     4 writes to S1
//
//   M1:
//     5 writes to S1
//
//   Expected:
//     M0's S1 write data precedes M1's S1 write data,
//     following the accepted AW order at S1.
//     After releasing S0 WREADY, read back every S1 address
//     and compare it with its original write data.
//
// =============================================================================

class axi_w_order_fill_test extends axi_base_test;

  function new(string name = "axi_w_order_fill_test");
    super.new(name);
  endfunction


  virtual function void configure();

    scenario_setup();

  endfunction


  // ===========================================================================
  // MAIN TEST
  // ===========================================================================

  virtual task main();

    axi_txn q0[$], q1[$];

    axi_txn t;
    axi_txn blocker;
    axi_txn rd;

    axi_txn m0_s1_writes[$];
    axi_txn m1_s1_writes[$];

    time release_time;

    int accepted_before_release;
    int accepted_after_release;

    int m1_done_before_release;


    // =======================================================================
    // PART A:
    // Fill the W-order FIFO.
    //
    // Expected depth = 8.
    // First 8 AWs accepted, remaining 2 wait.
    // =======================================================================

    title("PART A : WREADY = 0, 10 writes, FIFO depth 8");

    for (int p = 0; p < 2; p++) begin

      q0.delete();

      // p=0 -> S0, p=1 -> S1
      set_ready_low("W", p, 100);

      wait_clk(1);

      for (int i = 0; i < 10; i++) begin

        t = new_write(
            8 * p + (i % 8),
            scratch(p) + 32'h0090_0000 + 32'h100 * i,
            1
        );

        q0.push_back(t);

        send(p, t);

      end

      // Keep WREADY LOW long enough for the FIFO to fill.
      wait_clk(40);


      // -------------------------------------------------------------------
      // Check how many AW requests were accepted before WREADY is released.
      //
      // Assumption:
      // t_req records the actual AWVALID && AWREADY acceptance time.
      // -------------------------------------------------------------------

      release_time = $time;

      accepted_before_release = 0;

      foreach (q0[i]) begin

        if ((q0[i].t_req != 0) &&
            (q0[i].t_req <= release_time)) begin

          accepted_before_release++;

        end

      end


      check_num(
          $sformatf(
              "M%0d : AWs accepted while WREADY LOW",
              p
          ),
          accepted_before_release,
          8
      );

      check_num(
          $sformatf(
              "M%0d : AW requests waiting while FIFO full",
              p
          ),
          10 - accepted_before_release,
          2
      );


      // -------------------------------------------------------------------
      // Release WREADY.
      // The queued transactions should now proceed.
      // -------------------------------------------------------------------

      set_ready_low("W", p, 0);

      check_list(
          $sformatf(
              "M%0d : 10 writes to S%0d after WREADY release",
              p,
              p
          ),
          q0
      );


      // -------------------------------------------------------------------
      // After release, all 10 AW requests must have been accepted.
      // -------------------------------------------------------------------

      accepted_after_release = 0;

      foreach (q0[i]) begin

        if (q0[i].t_req != 0)
          accepted_after_release++;

        check_val(
            $sformatf(
                "M%0d write %0d : BID",
                p,
                i
            ),
            q0[i].rsp_id,
            q0[i].id
        );

      end

      check_num(
          $sformatf(
              "M%0d : total AW requests accepted after release",
              p
          ),
          accepted_after_release,
          10
      );

    end


    // =======================================================================
    // PART B:
    // DECERR-target write-order stress.
    //
    // M0 has an earlier write blocked at S0.
    // M0 then queues 4 writes to UNMAPPED.
    // M1 queues 5 writes to UNMAPPED.
    //
    // The M1 writes must not complete ahead of M0's older
    // write-data sequence.
    // =======================================================================

    title("PART B : DECERR target - M1 W data waits behind M0's sequence");

    q0.delete();
    q1.delete();

    set_ready_low("W", 0, 100);

    wait_clk(1);


    // M0's first write is blocked at S0.
    t = new_write(
        4'h1,
        scratch(0) + 32'h0098_0000,
        1
    );

    q0.push_back(t);

    send(0, t);


    // M0 queues 4 writes to UNMAPPED.
    for (int i = 0; i < 4; i++) begin

      t = new_write(
          2 + i,
          scratch(2) + 32'h100 * i,
          1
      );

      q0.push_back(t);

      send(0, t);

    end


    // Give M0's AW requests time to enter the crossbar.
    wait_clk(10);


    // M1 queues 5 writes to the same UNMAPPED target.
    for (int i = 0; i < 5; i++) begin

      t = new_write(
          9 + i,
          scratch(2) + 32'h1000 + 32'h100 * i,
          1
      );

      q1.push_back(t);

      send(1, t);

    end


    // Keep the earlier M0 write blocked.
    wait_clk(30);


    // The blocking M0 write must not have completed.
    check_num(
        "PART B : M0 S0 blocking write still pending",
        q0[0].done,
        0
    );


    // M1's DECERR writes should remain pending behind the older
    // M0 write-data sequence in this intended ordering scenario.
    m1_done_before_release = 0;

    foreach (q1[i]) begin

      if (q1[i].done)
        m1_done_before_release++;

    end

    check_num(
        "PART B : M1 DECERR writes completed before release",
        m1_done_before_release,
        0
    );


    // Release S0 W channel.
    set_ready_low("W", 0, 0);


    // Check all M0 writes.
    check_list(
        "M0 : 1 S0 write + 4 UNMAPPED writes",
        q0
    );


    // Check all M1 writes.
    check_list(
        "M1 : 5 UNMAPPED writes after M0's older sequence",
        q1
    );


    // Explicit BID checks.
    foreach (q0[i]) begin

      check_val(
          $sformatf("PART B : M0 transaction %0d BID", i),
          q0[i].rsp_id,
          q0[i].id
      );

    end

    foreach (q1[i]) begin

      check_val(
          $sformatf("PART B : M1 transaction %0d BID", i),
          q1[i].rsp_id,
          q1[i].id
      );

    end


    // =======================================================================
    // PART C:
    // Observable W-data ordering check using a real mapped Slave.
    //
    // M0's first write to S0 is blocked.
    //
    // M0 queues 4 writes to S1.
    // M1 queues 5 writes to S1 afterwards.
    //
    // Since AXI4 W has no WID, the data must follow the AW order.
    //
    // After releasing S0, read back all 9 S1 locations.
    // This detects incorrect association between write address and data.
    // =======================================================================

    title("PART C : Cross-master W-data ordering at mapped S1");

    q0.delete();
    q1.delete();

    m0_s1_writes.delete();
    m1_s1_writes.delete();


    // Hold S0 WREADY LOW.
    set_ready_low("W", 0, 100);

    wait_clk(1);


    // -------------------------------------------------------------------
    // M0's first transaction targets S0 and becomes blocked.
    // This is the head of M0's write-data sequence.
    // -------------------------------------------------------------------

    blocker = new_write(
        4'h1,
        scratch(0) + 32'h009C_0000,
        1
    );

    q0.push_back(blocker);

    send(0, blocker);


    // -------------------------------------------------------------------
    // M0 queues 4 writes to S1.
    // Their AW requests precede M1's S1 requests.
    // -------------------------------------------------------------------

    for (int i = 0; i < 4; i++) begin

      t = new_write(
          2 + i,
          scratch(1) + 32'h00A0_0000 + 32'h100 * i,
          1
      );

      q0.push_back(t);

      m0_s1_writes.push_back(t);

      send(0, t);

    end


    // Give M0's S1 AW requests time to enter the crossbar.
    wait_clk(10);


    // -------------------------------------------------------------------
    // M1 queues 5 writes to the same S1.
    // These must follow M0's earlier S1 writes in the target W order.
    // -------------------------------------------------------------------

    for (int i = 0; i < 5; i++) begin

      t = new_write(
          9 + i,
          scratch(1) + 32'h00A8_0000 + 32'h100 * i,
          1
      );

      q1.push_back(t);

      m1_s1_writes.push_back(t);

      send(1, t);

    end


    // Keep S0 WREADY LOW while the transactions queue.
    wait_clk(20);


    // M0's first write must still be blocked.
    check_num(
        "PART C : M0 S0 blocking write still pending",
        blocker.done,
        0
    );


    // M0's later S1 writes must not complete before the earlier
    // M0 S0 write-data transaction has drained.
    foreach (m0_s1_writes[i]) begin

      check_num(
          $sformatf(
              "PART C : M0 S1 write %0d still pending",
              i
          ),
          m0_s1_writes[i].done,
          0
      );

    end


    // M1's later S1 writes must not bypass M0's earlier
    // write-data sequence at the shared target.
    foreach (m1_s1_writes[i]) begin

      check_num(
          $sformatf(
              "PART C : M1 S1 write %0d still pending",
              i
          ),
          m1_s1_writes[i].done,
          0
      );

    end


    // -------------------------------------------------------------------
    // Release S0 WREADY.
    // The write-data streams can now drain in the required order.
    // -------------------------------------------------------------------

    set_ready_low("W", 0, 0);


    check_list(
        "PART C : M0 S0 blocker + 4 S1 writes",
        q0
    );

    check_list(
        "PART C : M1 5 S1 writes after M0's S1 writes",
        q1
    );


    // -------------------------------------------------------------------
    // Read back M0's 4 S1 writes.
    // -------------------------------------------------------------------

    for (int i = 0; i < m0_s1_writes.size(); i++) begin

      rd = new_read(
          m0_s1_writes[i].id,
          m0_s1_writes[i].addr,
          1
      );

      send_wait(0, rd);

      check_data(
          $sformatf(
              "PART C : M0 S1 write %0d data read-back",
              i
          ),
          m0_s1_writes[i],
          rd
      );

    end


    // -------------------------------------------------------------------
    // Read back M1's 5 S1 writes.
    // -------------------------------------------------------------------

    for (int i = 0; i < m1_s1_writes.size(); i++) begin

      rd = new_read(
          m1_s1_writes[i].id,
          m1_s1_writes[i].addr,
          1
      );

      send_wait(1, rd);

      check_data(
          $sformatf(
              "PART C : M1 S1 write %0d data read-back",
              i
          ),
          m1_s1_writes[i],
          rd
      );

    end


    // =======================================================================
    // FINAL VERIFICATION OBJECTIVES
    // =======================================================================

    prove(
        "W-order FIFO accepts exactly 8 AWs while WREADY is LOW"
    );

    prove(
        "the 9th and 10th AW requests wait until FIFO space becomes available"
    );

    prove(
        "after WREADY returns, all 10 write transactions complete"
    );

    prove(
        "DECERR-target writes return their correct responses and IDs"
    );

    prove(
        "older M0 write-data transactions are not bypassed by M1"
    );

    prove(
        "M0 and M1 write data reaches the correct S1 addresses"
    );

    prove(
        "W data remains associated with its corresponding AW transaction"
    );

  endtask

endclass

`endif // AXI_W_ORDER_FILL_TEST_SV
