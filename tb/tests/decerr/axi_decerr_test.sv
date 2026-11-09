`ifndef AXI_DECERR_TEST_SV
`define AXI_DECERR_TEST_SV

// =============================================================================
// axi_decerr_test  (TC-04)  -  DECERR for unmapped addresses
//
//   IDEA : an address that belongs to no slave must still get an answer,
//          otherwise the master would wait forever. The crossbar answers it
//          itself with DECERR.
//
//   STEP 1 : both masters write and read unmapped addresses with bursts of
//            1, 16 and 256 beats.
//            CHECK: every response is DECERR, the ID is correct, and a read
//                   returns exactly len+1 beats.
//   STEP 2 : M0 sends 4 unmapped transactions without waiting, while M1
//            writes and reads S0 normally.
//            CHECK: M1's data is correct and all 4 of M0's get DECERR.
// =============================================================================
class axi_decerr_test extends axi_base_test;

  function new(string name = "axi_decerr_test");
    super.new(name);
  endfunction

  virtual task main();
    bit [7:0]        lens[$]      = '{8'd0, 8'd15, 8'd255};                          // 1, 16, 256 beats
    bit [AXI_AW-1:0] bad_addrs[$] = '{32'h2000_0000, 32'h8000_0000, 32'hF000_0000}; // no slave here
    axi_txn          wr, rd, t;
    axi_txn          q[$];
    string           what;

    // ------------------------------------------------------------------ STEP 1
    title("STEP 1 : unmapped write + read, 1 / 16 / 256 beats, both masters");
    for (int m = 0; m < NUM_M; m++) begin
      foreach (lens[i]) begin
        wr = new_write(8 * m + 1, bad_addrs[i], lens[i]);
        rd = new_read (8 * m + 2, bad_addrs[i], lens[i]);
        send_wait(m, wr);
        send_wait(m, rd);
        what = $sformatf("M%0d %08h %0d beats", m, bad_addrs[i], wr.beats());
        check(all_beats_are(wr, RESP_DECERR), {what, " : write answered DECERR"});
        check(all_beats_are(rd, RESP_DECERR), {what, " : every read beat answered DECERR"});
        check_val({what, " : BID"}, wr.rsp_id, wr.id);
        check_val({what, " : RID"}, rd.rsp_id, rd.id);
        check_num({what, " : R beats received"}, rd.beat_cnt, rd.beats());
      end
    end

    // ------------------------------------------------------------------ STEP 2
    title("STEP 2 : 4 DECERR transactions in flight on M0, M1 uses S0 normally");
    for (int i = 0; i < 4; i++) begin
      t = new_txn(kind_of(i % 2), i, 32'h3000_0000 + 32'h100 * i, 7);   // write, read, write, read
      q.push_back(t);
      send(0, t);                            // do NOT wait: keep them in flight
    end
    wr = new_write(4'h9, 32'h0000_6000, 7);
    rd = new_read (4'hA, 32'h0000_6000, 7);
    send_wait(1, wr);
    send_wait(1, rd);
    check_data("M1->S0 while M0 has DECERR traffic", wr, rd);

    wait_list(q);
    foreach (q[i]) begin
      what = $sformatf("M0 outstanding unmapped %s %0d", kind_name(q[i].kind), i);
      check(all_beats_are(q[i], RESP_DECERR), {what, " : DECERR"});
      check_val({what, " : response ID"}, q[i].rsp_id, q[i].id);
    end

    prove("unmapped writes get BRESP=DECERR (1, 16 and 256 beats)");
    prove("unmapped reads get len+1 beats, all RRESP=DECERR, with the right RID");
    prove("DECERR traffic on one master does not disturb the other master");
  endtask

endclass

`endif // AXI_DECERR_TEST_SV
