`ifndef AXI_CHANNEL_INDEP_TEST_SV
`define AXI_CHANNEL_INDEP_TEST_SV

// =============================================================================
// axi_channel_indep_test (TC-10) - AXI channel independence
//
// IDEA:
//   AXI has 5 independent channels: AW, W, B, AR, R.
//   Blocking one channel must not unnecessarily stop unrelated traffic.
//
//   Every step:
//     1. Block one READY signal.
//     2. Start a transaction requiring that channel.
//     3. Run another transaction that does not require the blocked channel.
//     4. Check that the first transaction is still pending.
//     5. Check that the other transaction completed successfully.
//     6. Unblock the channel and check that the first transaction completes.
//
// STEP A : M0 BREADY  = 0
//           M0 write stuck, M0 read from S0 still works.
//
// STEP B : S1 ARREADY = 0
//           M1 read stuck, M1 write to S1 still works.
//
// STEP C : S0 WREADY  = 0
//           M0 write stuck, M1 read from S0 still works.
//
// STEP D : M1 RREADY  = 0
//           M1 read stuck, M0 write to S0 still works.
//
// STEP E : S0 AWREADY = 0
//           M0 write stuck, M1 read from S0 still works.
//
// =============================================================================

class axi_channel_indep_test extends axi_base_test;

  function new(string name = "axi_channel_indep_test");
    super.new(name);
  endfunction


  // ===========================================================================
  // STEP 3 CHECK:
  // Stuck transaction must remain pending.
  // Other transaction must complete with OKAY.
  // ===========================================================================

  task check_blocked(
      string what,
      axi_txn stuck,
      axi_txn other
  );

    wait_clk(20);

    check_num(
        {what, " : stuck transaction finished (must still wait)"},
        stuck.done,
        0
    );

    check_num(
        {what, " : other traffic finished"},
        other.done,
        1
    );

    check_resp(
        {what, " : other traffic response"},
        other.resp[0],
        RESP_OKAY
    );

  endtask


  // ===========================================================================
  // STEP 4 CHECK:
  // After unblocking, the previously stuck transaction must complete.
  // ===========================================================================

  task check_released(
      string what,
      axi_txn stuck
  );

    wait_done(stuck);

    check_resp(
        {what, " : stuck transaction after unblocking"},
        stuck.resp[0],
        RESP_OKAY
    );

  endtask


  // ===========================================================================
  // MAIN TEST
  // ===========================================================================

  virtual task main();

    axi_txn stuck, other;


    // =======================================================================
    // STEP A:
    // M0 BREADY = 0
    // Write response blocked, but read traffic must continue.
    // =======================================================================

    title("STEP A : M0 BREADY held LOW (B channel blocked)");

    set_ready_low("B", 0, 100);

    stuck = new_write(
        4'h1,
        32'h0000_7100,
        3
    );

    send(0, stuck);

    other = new_read(
        4'h2,
        32'h0000_7000,
        3
    );

    send_wait(0, other);

    check_blocked(
        "A (B blocked)",
        stuck,
        other
    );

    // Release B channel
    set_ready_low("B", 0, 0);

    check_released(
        "A (B blocked)",
        stuck
    );


    // =======================================================================
    // STEP B:
    // S1 ARREADY = 0
    // Read address blocked, but write traffic must continue.
    // =======================================================================

    title("STEP B : S1 ARREADY held LOW (AR channel blocked)");

    set_ready_low("AR", 1, 100);

    stuck = new_read(
        4'h9,
        32'h1000_7000,
        3
    );

    send(1, stuck);

    other = new_write(
        4'hA,
        32'h1000_7100,
        3
    );

    send_wait(1, other);

    check_blocked(
        "B (AR blocked)",
        stuck,
        other
    );

    // Release AR channel
    set_ready_low("AR", 1, 0);

    check_released(
        "B (AR blocked)",
        stuck
    );


    // =======================================================================
    // STEP C:
    // S0 WREADY = 0
    // Write data blocked, but another master must still read S0.
    // =======================================================================

    title("STEP C : S0 WREADY held LOW (W channel blocked)");

    set_ready_low("W", 0, 100);

    stuck = new_write(
        4'h4,
        32'h0000_7300,
        3
    );

    send(0, stuck);

    // Allow AW request to proceed before testing W blocking.
    wait_clk(10);

    other = new_read(
        4'hC,
        32'h0000_7000,
        3
    );

    send_wait(1, other);

    check_blocked(
        "C (W blocked)",
        stuck,
        other
    );

    // Release W channel
    set_ready_low("W", 0, 0);

    check_released(
        "C (W blocked)",
        stuck
    );


    // =======================================================================
    // STEP D:
    // M1 RREADY = 0
    // Read response blocked, but M0 write must continue.
    // =======================================================================

    title("STEP D : M1 RREADY held LOW (R channel blocked)");

    set_ready_low("R", 1, 100);

    stuck = new_read(
        4'hF,
        32'h1000_7100,
        3
    );

    send(1, stuck);

    other = new_write(
        4'h5,
        32'h0000_7500,
        3
    );

    send_wait(0, other);

    check_blocked(
        "D (R blocked)",
        stuck,
        other
    );

    // Release R channel
    set_ready_low("R", 1, 0);

    check_released(
        "D (R blocked)",
        stuck
    );


    // =======================================================================
    // STEP E:
    // S0 AWREADY = 0
    // Write address blocked, but another master must still read S0.
    // =======================================================================

    title("STEP E : S0 AWREADY held LOW (AW channel blocked)");

    set_ready_low("AW", 0, 100);

    stuck = new_write(
        4'h7,
        32'h0000_7600,
        3
    );

    send(0, stuck);

    // Give the write address request time to become stalled.
    wait_clk(10);

    other = new_read(
        4'h8,
        32'h0000_7000,
        3
    );

    send_wait(1, other);

    check_blocked(
        "E (AW blocked)",
        stuck,
        other
    );

    // Release AW channel
    set_ready_low("AW", 0, 0);

    check_released(
        "E (AW blocked)",
        stuck
    );


    // =======================================================================
    // FINAL VERIFICATION OBJECTIVES
    // =======================================================================

    prove(
        "a blocked B channel does not stop read transactions"
    );

    prove(
        "a blocked AR channel does not stop write transactions"
    );

    prove(
        "a blocked W channel on S0 does not stop another master reading S0"
    );

    prove(
        "a blocked R channel on M1 does not stop M0 write traffic"
    );

    prove(
        "a blocked AW channel on S0 does not stop another master reading S0"
    );

    prove(
        "blocked transactions are not lost and finish after READY returns"
    );

    prove(
        "all five AXI channels have been independently exercised"
    );

  endtask

endclass

`endif // AXI_CHANNEL_INDEP_TEST_SV
