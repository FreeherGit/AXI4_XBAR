`ifndef AXI_SLVERR_TEST_SV
`define AXI_SLVERR_TEST_SV

// =============================================================================
// axi_slverr_test (TC-11) - SLVERR propagation and burst coverage
//
// IDEA:
//   DECERR comes from the crossbar.
//   SLVERR comes from a SLAVE.
//
//   The crossbar must pass the slave's SLVERR response back to the
//   requesting master without changing the response or transaction ID.
//
// SETUP:
//   Each slave generates SLVERR in its own 4 KB address window.
//
//   S0: 0x0000_8000 .. 0x0000_8FFF
//   S1: 0x1000_8000 .. 0x1000_8FFF
//
// STEP 1:
//   Both masters write and read (4 beats) inside and just outside
//   the SLVERR windows.
//
//   CHECK:
//     Inside  -> BRESP and every RRESP = SLVERR
//     Outside -> BRESP and every RRESP = OKAY
//     Outside -> Read-back data is correct
//     BID = AWID, RID = ARID
//
// STEP 2:
//   Both masters perform an 8-beat read inside their respective
//   SLVERR windows.
//
//   CHECK:
//     All 8 RRESP beats = SLVERR
//     Exactly 8 read beats received
//     RID = ARID
//
// STEP 3:
//   Both masters access both slaves using:
//
//     A. 2-beat INCR bursts (8 bytes per beat)
//     B. 4-beat WRAP bursts (4 bytes per beat)
//
//   All accesses are inside the SLVERR windows.
//
//   CHECK:
//     SLVERR is correctly propagated for different burst types.
//     Response and ID checking is performed by write_read().
//
// =============================================================================

class axi_slverr_test extends axi_base_test;

  function new(string name = "axi_slverr_test");
    super.new(name);
  endfunction


  // ===========================================================================
  // CONFIGURATION
  // ===========================================================================

  virtual function void configure();

    scenario_setup();

    // S0 SLVERR window
    env.s_cfg[0].err_en = 1;
    env.s_cfg[0].err_lo = 32'h0000_8000;
    env.s_cfg[0].err_hi = 32'h0000_8FFF;

    // S1 SLVERR window
    env.s_cfg[1].err_en = 1;
    env.s_cfg[1].err_lo = 32'h1000_8000;
    env.s_cfg[1].err_hi = 32'h1000_8FFF;

  endfunction


  // ===========================================================================
  // MAIN TEST
  // ===========================================================================

  virtual task main();

    bit [AXI_AW-1:0] addrs[$] = '{
        32'h0000_8000,    // Inside S0 SLVERR window
        32'h0000_9000,    // Outside S0 SLVERR window
        32'h1000_8000,    // Inside S1 SLVERR window
        32'h1000_9000     // Outside S1 SLVERR window
    };

    bit [AXI_AW-1:0] win;

    axi_txn wr, rd;

    bit [1:0] exp;

    string what;


    // =======================================================================
    // STEP 1:
    // Both masters write and read inside/outside SLVERR windows
    // =======================================================================

    title("STEP 1 : Both masters access inside/outside SLVERR windows");

    for (int m = 0; m < NUM_M; m++) begin

      title($sformatf(
          "M%0d : inside/outside SLVERR window checking",
          m
      ));

      foreach (addrs[k]) begin

        // Determine expected response from the address.
        if ((addrs[k] & 32'h0000_F000) == 32'h0000_8000)
          exp = RESP_SLVERR;
        else
          exp = RESP_OKAY;

        // Write transaction
        wr = new_write(
            8 * m + 1,
            addrs[k] + 32'h10 * m
        );

        // Read transaction
        rd = new_read(
            8 * m + 2,
            addrs[k] + 32'h10 * m,
            3
        );

        // Execute write and read
        send_wait(m, wr);
        send_wait(m, rd);

        what = $sformatf(
            "M%0d %08h",
            m,
            wr.addr
        );

        // Check write response
        check_resp(
            {what, " : BRESP"},
            wr.resp[0],
            exp
        );

        // Check every read response beat
        check(
            all_beats_are(rd, exp),
            {what, " : all 4 RRESP = ", axi_resp_str(exp)}
        );

        // Check write response ID
        check_val(
            {what, " : BID"},
            wr.rsp_id,
            wr.id
        );

        // Check read response ID
        check_val(
            {what, " : RID"},
            rd.rsp_id,
            rd.id
        );

        // Outside the error window, data must be correct
        if (exp == RESP_OKAY) begin

          check_data(
              {what, " : outside the window, read back"},
              wr,
              rd
          );

        end

      end
    end


    // =======================================================================
    // STEP 2:
    // 8-beat read inside each slave's SLVERR window
    // =======================================================================

    title("STEP 2 : 8-beat read inside each SLVERR window");

    for (int m = 0; m < NUM_M; m++) begin

      rd = new_read(
          8 * m + 4,
          slave_base(m) + 32'h0000_8100,
          7
      );

      send_wait(m, rd);

      // All 8 read response beats must contain SLVERR
      check(
          all_beats_are(rd, RESP_SLVERR),
          $sformatf(
              "M%0d 8-beat read: SLVERR on every R beat",
              m
          )
      );

      // Exactly 8 read beats must be received
      check_num(
          $sformatf(
              "M%0d 8-beat read: R beats received",
              m
          ),
          rd.beat_cnt,
          8
      );

      // Verify read response ID
      check_val(
          $sformatf(
              "M%0d 8-beat read: RID",
              m
          ),
          rd.rsp_id,
          rd.id
      );

    end


    // =======================================================================
    // STEP 3:
    // INCR and WRAP burst testing inside every SLVERR window
    //
    // Every master accesses every slave.
    //
    // Burst A: 2-beat INCR, 8 bytes per beat
    // Burst B: 4-beat WRAP, 4 bytes per beat
    // =======================================================================

    title("STEP 3 : INCR and WRAP bursts inside every SLVERR window");

    for (int m = 0; m < NUM_M; m++) begin

      for (int s = 0; s < NUM_S; s++) begin

        // Get the starting address of this slave's error window
        win = env.s_cfg[s].err_lo;

        title($sformatf(
            "M%0d -> S%0d : SLVERR burst testing",
            m,
            s
        ));


        // -------------------------------------------------------------------
        // STEP 3A:
        // 2-beat INCR burst
        //
        // AxLEN  = 1 -> 2 beats
        // AxSIZE = 3 -> 8 bytes per beat
        // -------------------------------------------------------------------

        write_read(
            m,
            8 * m + 6,
            win + 32'h0040 * m,
            1,
            3,
            BURST_INCR,
            "(2-beat INCR inside SLVERR window)"
        );


        // -------------------------------------------------------------------
        // STEP 3B:
        // 4-beat WRAP burst
        //
        // AxLEN  = 3 -> 4 beats
        // AxSIZE = 2 -> 4 bytes per beat
        // -------------------------------------------------------------------

        write_read(
            m,
            8 * m + 7,
            win + 32'h0080 + 32'h0040 * m,
            3,
            2,
            BURST_WRAP,
            "(4-beat WRAP inside SLVERR window)"
        );

      end
    end


    // =======================================================================
    // FINAL VERIFICATION OBJECTIVES
    // =======================================================================

    prove(
        "a slave's SLVERR goes back unchanged to the master that asked"
    );

    prove(
        "SLVERR is on the B response of a failing write and every R beat of a failing read"
    );

    prove(
        "addresses outside the error window return OKAY with correct read-back data"
    );

    prove(
        "8-beat reads receive SLVERR on all beats with the correct RID"
    );

    prove(
        "SLVERR is correctly propagated for both INCR and WRAP bursts"
    );

    prove(
        "both masters can access both slaves and receive the correct SLVERR responses"
    );

  endtask

endclass

`endif // AXI_SLVERR_TEST_SV
