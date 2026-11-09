`ifndef AXI_MULTI_OUTSTANDING_TEST_SV
`define AXI_MULTI_OUTSTANDING_TEST_SV

// =============================================================================
// axi_multi_outstanding_test  (TC-13)  -  outstanding to BOTH slaves, ID rules
//
//   IDEA : one master may talk to S0 and S1 at the same time. AXI rules:
//            * DIFFERENT IDs may finish in any order -> a slow slave must not
//              block a fast one
//            * the SAME ID must finish in order -> the crossbar holds a
//              second same-ID request back until the first one is finished
//
//   The slaves get a fixed latency so the timing is easy to predict:
//   S0 is slow (40 clocks), S1 is fast (20 or 0 clocks).
//   Times: t_req = request accepted, t_end = answer received.
//   Two transactions "overlap" if both were in flight at the same time.
//
//   STEP 1 : M0 reads S0 (slow) and S1 (fast), DIFFERENT IDs
//            CHECK: they overlap and S1 answers first; data correct
//   STEP 2 : same with writes
//   STEP 3 : M0 reads S0 and S1 with the SAME ID
//            CHECK: the S1 read is accepted only after the S0 read finished
//   STEP 4 : M0 and M1 write the same slave S0, DIFFERENT IDs
//            CHECK: they overlap, and each master reads back its own data
// =============================================================================
class axi_multi_outstanding_test extends axi_base_test;

  function new(string name = "axi_multi_outstanding_test");
    super.new(name);
    timeout_ns = 20_000_000;
  endfunction

  virtual function void configure();
    for (int m = 0; m < NUM_M; m++) env.m_cfg[m].max_outstanding = 8;
  endfunction

  // 1 if a and b were in flight at the same time
  function bit overlap(axi_txn a, axi_txn b);
    return (a.t_req < b.t_end) && (b.t_req < a.t_end);
  endfunction

  function void show(string what, axi_txn t);
    info($sformatf("%-20s ID %0h : accepted @%0t, finished @%0t, resp=%s",
                   what, t.id, t.t_req, t.t_end, axi_resp_str(t.resp[0])));
  endfunction

  virtual task main();
    axi_txn fill0, fill1, wa, wb, ra, rb;

    // ------------------------------------------------------------------ setup
    title("SETUP : write known data into S0 and S1 (no latency)");
    fill0 = new_write(4'h0, 32'h0000_9000, 7);
    fill1 = new_write(4'h1, 32'h1000_9000, 7);
    send_wait(0, fill0);
    send_wait(0, fill1);

    // ------------------------------------------------------------------ STEP 1
    title("STEP 1 : M0 reads S0 (latency 40) and S1 (latency 20), DIFFERENT IDs");
    set_latency(0, 40);
    set_latency(1, 20);
    ra = new_read(4'h2, 32'h0000_9000, 7);
    rb = new_read(4'h3, 32'h1000_9000, 7);
    send(0, ra);
    send(0, rb);
    wait_done(ra);
    wait_done(rb);
    show("read S0 (slow)", ra);
    show("read S1 (fast)", rb);
    check(overlap(ra, rb), "both reads were in flight at the same time");
    check(rb.t_end < ra.t_end, "S1 answered first: different IDs may finish out of order");
    check_data("STEP 1 S0 read data", fill0, ra);
    check_data("STEP 1 S1 read data", fill1, rb);

    // ------------------------------------------------------------------ STEP 2
    title("STEP 2 : M0 writes S0 (latency 40) and S1 (latency 20), DIFFERENT IDs");
    wa = new_write(4'h4, 32'h0000_9100, 3);
    wb = new_write(4'h5, 32'h1000_9100, 3);
    send(0, wa);
    send(0, wb);
    wait_done(wa);
    wait_done(wb);
    show("write S0 (slow)", wa);
    show("write S1 (fast)", wb);
    check(overlap(wa, wb), "both writes were in flight at the same time");
    check(wb.t_end < wa.t_end, "the B from S1 came back first");
    set_all_latency(0);
    ra = new_read(4'h4, 32'h0000_9100, 3);
    rb = new_read(4'h5, 32'h1000_9100, 3);
    send_wait(0, ra);
    send_wait(0, rb);
    check_data("STEP 2 W data landed in S0", wa, ra);
    check_data("STEP 2 W data landed in S1", wb, rb);

    // ------------------------------------------------------------------ STEP 3
    title("STEP 3 : M0 reads S0 (latency 40) and S1 (latency 0) with the SAME ID 6");
    set_latency(0, 40);
    ra = new_read(4'h6, 32'h0000_9000, 3);
    rb = new_read(4'h6, 32'h1000_9000, 3);
    send(0, ra);
    send(0, rb);
    wait_done(ra);
    wait_done(rb);
    show("read S0 (ID 6)", ra);
    show("read S1 (ID 6)", rb);
    check(rb.t_req >= ra.t_end, "the second ID-6 read was held until the first one finished");
    check(ra.t_end < rb.t_end, "ID-6 answers reached M0 in the order they were sent");

    // ------------------------------------------------------------------ STEP 4
    title("STEP 4 : M0 (ID 1) and M1 (ID 9) write S0 at the same time (latency 40)");
    wa = new_write(4'h1, 32'h0000_9300, 3);
    wb = new_write(4'h9, 32'h0000_9400, 3);
    send(0, wa);
    send(1, wb);
    wait_done(wa);
    wait_done(wb);
    show("M0 write S0", wa);
    show("M1 write S0", wb);
    check(overlap(wa, wb), "both masters' writes were in flight at S0 at the same time");
    set_all_latency(0);
    ra = new_read(4'h1, 32'h0000_9300, 3);
    rb = new_read(4'h9, 32'h0000_9400, 3);
    send_wait(0, ra);
    send_wait(1, rb);
    check_data("STEP 4 M0 got its own data back", wa, ra);
    check_data("STEP 4 M1 got its own data back", wb, rb);

    prove("a master can have transactions in flight at S0 and S1 at the same time (reads and writes)");
    prove("different-ID answers may come back out of order, so a slow slave does not block a fast one");
    prove("same-ID requests to different slaves are held back and finish in order");
    prove("two masters can use one slave at the same time with different IDs");
    prove("W data reaches the slave of its AW and answers reach the right master (data checked)");
  endtask

endclass

`endif // AXI_MULTI_OUTSTANDING_TEST_SV
