`ifndef AXI_BASE_TEST_SV
`define AXI_BASE_TEST_SV

// =============================================================================
// axi_base_test.sv   (included inside axi_test_pkg - do not compile alone)
//
// Every test "extends axi_base_test" and fills in two things:
//
//     configure()  -> optional: change knobs (latency, backpressure, ...)
//     main()       -> the traffic of the test and its checks
//
// run() does the rest for you: build the environment, reset the DUT,
// call main(), wait until all traffic is finished, print the result.
//
// -----------------------------------------------------------------------------
// HELPERS YOU CAN USE IN main()
// -----------------------------------------------------------------------------
//  Make a transaction (it is NOT sent yet):
//     wr = new_write(id, addr, len, size, burst);    len = beats - 1
//     rd = new_read (id, addr, len, size, burst);    size: 0=1B 1=2B 2=4B 3=8B
//     (len, size and burst are optional: default 1 beat, 8 bytes, INCR)
//
//  Send it from master m (0 or 1):
//     send(m, t);          put it in the queue, do not wait
//     send_wait(m, t);     put it in the queue and wait until it is finished
//     wait_done(t);        wait until t is finished
//     wait_list(q);        wait until every transaction in queue q is finished
//     wait_clk(n);         wait n clock cycles
//
//  One-line "write, read back, check everything":
//     write_read(m, id, addr, len, size, burst, "note");
//
//  Checks (each prints ONE line: PASS or FAIL + what was compared):
//     check(ok, "text")                        any condition
//     check_val ("text", got, expected)        hex values      got 0x5 == expected 0x5
//     check_num ("text", got, expected)        decimal numbers got 8 == expected 8
//     check_min ("text", got, minimum)         got 12 >= needed 4
//     check_resp("text", got, expected)        OKAY / SLVERR / DECERR
//     check_data("text", wr, rd)               read data == written data
//     check_pair("text", wr, rd)               responses + IDs + data of a write/read pair
//     check_list("text", q)                    every response in q == reference model
//
//  Printing:
//     title("text")    a banner for a new part of the test
//     info("text")     one information line
//     prove("text")    add a line to the "WHAT THIS TEST PROVED" list at the end
//
//  Plusargs:
//     +VERBOSE         print extra detail lines (info_v)
//     +SB_VERBOSE      print one scoreboard line per transaction
//     +COV_DETAIL      print the full coverage bin tables at the end
//
//  Vivado xsim note: send_wait / wait_done / wait_list wait on a LOCAL copy
//  of the transaction handle (xsim cannot wait on a field of a task argument).
// =============================================================================

class axi_base_test;

  string        name;
  axi_env       env;
  int unsigned  timeout_ns   = 5_000_000;   // test is stopped after this time
  int unsigned  reset_cycles = 10;
  bit           verbose;                    // set by +VERBOSE
  bit           timed_out;

  int unsigned  n_pass;                     // number of checks that passed
  int unsigned  n_fail;                     // number of checks that failed
  string        proved[$];                  // lines of the final summary

  function new(string name);
    this.name = name;
    env       = new();
    verbose   = $test$plusargs("VERBOSE");
  endfunction

  function void set_vifs(virtual axi_if m0, virtual axi_if m1,
                         virtual axi_if s0, virtual axi_if s1,
                         virtual axi_rst_if rst);
    env.m_vif[0] = m0;
    env.m_vif[1] = m1;
    env.s_vif[0] = s0;
    env.s_vif[1] = s1;
    env.rst_vif  = rst;
  endfunction

  // ---- the two hooks a test fills in
  virtual function void configure();
  endfunction

  virtual task main();
  endtask

  // ===========================================================================
  // Printing
  // ===========================================================================
  function void title(string s);
    $display("");
    $display("------------------------------------------------------------------");
    $display(" %s", s);
    $display("------------------------------------------------------------------");
  endfunction

  function void info(string s);
    $display("[%0t]      %s", $time, s);
  endfunction

  // only printed with +VERBOSE
  function void info_v(string s);
    if (verbose) info(s);
  endfunction

  function void prove(string s);
    proved.push_back(s);
  endfunction

  // ===========================================================================
  // Checks
  // ===========================================================================
  function void check(bit ok, string what);
    if (ok) begin
      n_pass++;
      $display("[%0t] PASS : %s", $time, what);
    end else begin
      n_fail++;
      $error("[%0t] FAIL : %s", $time, what);
    end
  endfunction

  // compare two values, printed in hex
  function void check_val(string what, bit [63:0] got, bit [63:0] expected);
    string s;
    if (got == expected) s = $sformatf("%s : got 0x%0h == expected 0x%0h", what, got, expected);
    else                 s = $sformatf("%s : got 0x%0h != expected 0x%0h", what, got, expected);
    check(got == expected, s);
  endfunction

  // compare two numbers, printed in decimal
  function void check_num(string what, int got, int expected);
    string s;
    if (got == expected) s = $sformatf("%s : got %0d == expected %0d", what, got, expected);
    else                 s = $sformatf("%s : got %0d != expected %0d", what, got, expected);
    check(got == expected, s);
  endfunction

  // a number must be at least "minimum"
  function void check_min(string what, int got, int minimum);
    string s;
    if (got >= minimum) s = $sformatf("%s : got %0d >= needed %0d", what, got, minimum);
    else                s = $sformatf("%s : got %0d <  needed %0d", what, got, minimum);
    check(got >= minimum, s);
  endfunction

  // compare two AXI response codes, printed as names
  function void check_resp(string what, bit [1:0] got, bit [1:0] expected);
    string s;
    if (got == expected) s = $sformatf("%s : got %s == expected %s", what, axi_resp_str(got), axi_resp_str(expected));
    else                 s = $sformatf("%s : got %s != expected %s", what, axi_resp_str(got), axi_resp_str(expected));
    check(got == expected, s);
  endfunction

  // read data == the data the write put in memory (byte by byte, strobes respected)
  function void check_data(string what, axi_txn wr, axi_txn rd);
    int unsigned errs;
    string       s;
    errs = axi_check_readback(wr, rd, what, RESP_OKAY, 1'b0);   // prints details only on a mismatch
    if (errs == 0) s = $sformatf("%s : %0d beats read back == data written", what, rd.beats());
    else           s = $sformatf("%s : %0d beats read back, %0d differ from data written", what, rd.beats(), errs);
    check(errs == 0, s);
  endfunction

  // ===========================================================================
  // Transactions
  // ===========================================================================
  function axi_txn new_txn(axi_kind_e        kind,
                           bit [AXI_IDW-1:0] id,
                           bit [AXI_AW-1:0]  addr,
                           bit [7:0]         len   = 0,
                           bit [2:0]         size  = 3,
                           bit [1:0]         burst = BURST_INCR);
    return axi_make_txn(kind, id, addr, len, size, burst);
  endfunction

  function axi_txn new_write(bit [AXI_IDW-1:0] id, bit [AXI_AW-1:0] addr,
                             bit [7:0] len = 0, bit [2:0] size = 3, bit [1:0] burst = BURST_INCR);
    return axi_make_txn(AXI_WRITE, id, addr, len, size, burst);
  endfunction

  function axi_txn new_read(bit [AXI_IDW-1:0] id, bit [AXI_AW-1:0] addr,
                            bit [7:0] len = 0, bit [2:0] size = 3, bit [1:0] burst = BURST_INCR);
    return axi_make_txn(AXI_READ, id, addr, len, size, burst);
  endfunction

  task send(int m, axi_txn t);
    env.m_agt[m].seq_mbx.put(t);
  endtask

  task wait_done(axi_txn t);
    axi_txn lt;
    lt = t;
    wait (lt.done);
  endtask

  task send_wait(int m, axi_txn t);
    axi_txn lt;
    lt = t;
    send(m, lt);
    wait (lt.done);
  endtask

  task wait_list(axi_txn q[$]);
    axi_txn lt;
    foreach (q[i]) begin
      lt = q[i];
      wait (lt.done);
    end
  endtask

  task wait_clk(int unsigned n);
    repeat (n) @(env.m_vif[0].cb);
  endtask

  task reset_dut();
    env.rst_vif.apply_reset(reset_cycles);
    wait_clk(2);
  endtask

  // ===========================================================================
  // Small lookup helpers
  // ===========================================================================
  // target of an address: 0 = S0, 1 = S1, 2 = unmapped (DECERR)
  function int target_of(bit [AXI_AW-1:0] a);
    return env.rm.target_of(a);
  endfunction

  function string tgt_name(int tg);
    if (tg == 0) return "S0";
    if (tg == 1) return "S1";
    return "UNMAPPED";
  endfunction

  function string kind_name(axi_kind_e k);
    if (k == AXI_WRITE) return "WRITE";
    return "READ";
  endfunction

  // loop counter 0 / 1 -> WRITE / READ
  function axi_kind_e kind_of(int k);
    if (k == 0) return AXI_WRITE;
    return AXI_READ;
  endfunction

  function bit [AXI_AW-1:0] slave_base(int s);
    if (s == 0) return S0_BASE;
    return S1_BASE;
  endfunction

  // Free address areas used by the "coverage scenario" tests
  //   0 -> S0 0x0D00_0000..   1 -> S1 0x1D00_0000..   2 -> unmapped 0xD000_0000..
  function bit [AXI_AW-1:0] scratch(int tg);
    if (tg == 0) return S0_BASE + 32'h0D00_0000;
    if (tg == 1) return S1_BASE + 32'h0D00_0000;
    return 32'hD000_0000;
  endfunction

  // response the reference model expects for t (OKAY / SLVERR / DECERR)
  function bit [1:0] model_resp(axi_txn t);
    return env.rm.expected_resp(t);
  endfunction

  // 1 if every beat of t has response r
  function bit all_beats_are(axi_txn t, bit [1:0] r);
    if (t.resp.size() == 0) return 1'b0;
    foreach (t.resp[i])
      if (t.resp[i] !== r) return 1'b0;
    return 1'b1;
  endfunction

  // 1 if t finished with the response the model expects on every beat,
  // the ID came back unchanged, and a read got all its beats
  function bit resp_ok(axi_txn t);
    if (t.aborted || !t.done) return 1'b0;
    if (t.rsp_id !== t.id)    return 1'b0;
    if (!all_beats_are(t, model_resp(t))) return 1'b0;
    if (t.kind == AXI_READ && t.beat_cnt != t.beats()) return 1'b0;
    return 1'b1;
  endfunction

  // number of transactions in q that finished normally (not cut by a reset)
  function int count_done(axi_txn q[$]);
    int n = 0;
    foreach (q[i])
      if (q[i].done && !q[i].aborted) n++;
    return n;
  endfunction

  // ===========================================================================
  // Knobs
  // ===========================================================================
  // fixed B and R latency (clock cycles) on slave s
  function void set_latency(int s, int unsigned n);
    env.s_cfg[s].b_latency_min = n;  env.s_cfg[s].b_latency_max = n;
    env.s_cfg[s].r_latency_min = n;  env.s_cfg[s].r_latency_max = n;
  endfunction

  function void set_all_latency(int unsigned n);
    set_latency(0, n);
    set_latency(1, n);
  endfunction

  // hold one READY low for pct % of the clocks
  //   "AW", "W", "AR" : READY driven by slave port  idx (0 = S0, 1 = S1)
  //   "B",  "R"       : READY driven by master port idx (0 = M0, 1 = M1)
  function void set_ready_low(string ch, int idx, int unsigned pct);
    if (ch == "AW") env.s_cfg[idx].awready_low_pct = pct;
    if (ch == "W")  env.s_cfg[idx].wready_low_pct  = pct;
    if (ch == "AR") env.s_cfg[idx].arready_low_pct = pct;
    if (ch == "B")  env.m_cfg[idx].bready_low_pct  = pct;
    if (ch == "R")  env.m_cfg[idx].rready_low_pct  = pct;
  endfunction

  // settings used by the "coverage scenario" tests (call in configure()):
  // no backpressure, no latency, deep queues
  function void scenario_setup();
    for (int m = 0; m < NUM_M; m++) env.m_cfg[m].max_outstanding = 16;
    for (int s = 0; s < NUM_S; s++) env.s_cfg[s].slave_depth     = 16;
  endfunction

  // the random generator prints only its settings and a summary line
  function void quiet(axi_rand_gen g);
    g.verbose   = 1'b0;
    g.print_max = 0;
  endfunction

  // ===========================================================================
  // Bigger helpers
  // ===========================================================================

  // Write + read of the same burst: responses, IDs and data
  function void check_pair(string what, axi_txn wr, axi_txn rd);
    bit [1:0] exp;
    bit       ok;
    string    dstr, s;
    exp = model_resp(wr);
    ok  = resp_ok(wr) && resp_ok(rd);
    if (exp == RESP_OKAY) begin
      if (axi_check_readback(wr, rd, what, RESP_OKAY, 1'b0) != 0) ok = 1'b0;
      dstr = $sformatf("%0d beats read == written", rd.beats());
    end else begin
      dstr = "error response, nothing stored";
    end
    s = $sformatf("%s : BRESP=%s RRESP=%s expected %s | BID=%0h RID=%0h expected %0h | %s",
                  what, axi_resp_str(wr.resp[0]), axi_resp_str(rd.resp[0]), axi_resp_str(exp),
                  wr.rsp_id, rd.rsp_id, wr.id, dstr);
    check(ok, s);
  endfunction

  // Write a burst, read it back, check responses + IDs + data (blocking)
  task write_read(int m, bit [AXI_IDW-1:0] id, bit [AXI_AW-1:0] addr,
                  bit [7:0] len = 0, bit [2:0] size = 3, bit [1:0] burst = BURST_INCR,
                  string note = "");
    axi_txn wr, rd;
    string  what;
    wr = new_write(id, addr, len, size, burst);
    rd = new_read (id, addr, len, size, burst);
    send_wait(m, wr);
    send_wait(m, rd);
    what = $sformatf("M%0d->%s %s %0dx%0dB addr=%08h %s", m, tgt_name(target_of(addr)),
                     axi_burst_str(burst), int'(len) + 1, 1 << size, addr, note);
    check_pair(what, wr, rd);
  endtask

  // Wait for every transaction in q, then check that each one got the
  // response the reference model expects and its own ID back.
  task check_list(string what, axi_txn q[$]);
    int unsigned bad, n_ok, n_slv, n_dec;
    bit [1:0]    exp;
    string       s;
    wait_list(q);
    bad = 0;  n_ok = 0;  n_slv = 0;  n_dec = 0;
    foreach (q[i]) begin
      exp = model_resp(q[i]);
      if (exp == RESP_OKAY)   n_ok++;
      if (exp == RESP_SLVERR) n_slv++;
      if (exp == RESP_DECERR) n_dec++;
      if (!resp_ok(q[i])) begin
        bad++;
        if (q[i].resp.size() > 0)
          $display("        WRONG: %s got %s ID %0h, expected %s ID %0h",
                   q[i].req_str(), axi_resp_str(q[i].resp[0]), q[i].rsp_id, axi_resp_str(exp), q[i].id);
        else
          $display("        WRONG: %s got no response, expected %s", q[i].req_str(), axi_resp_str(exp));
      end
    end
    s = $sformatf("%s : %0d txns, responses == model (OKAY %0d, SLVERR %0d, DECERR %0d), IDs echoed, %0d wrong",
                  what, q.size(), n_ok, n_slv, n_dec, bad);
    check(bad == 0, s);
  endtask

  // Read/write test of one master->slave path (8 beats x 8 bytes):
  //   1. write A and read B at the same time
  //   2. write B, then read B back
  //   3. read A back
  task path_rw(int m, int s, bit [AXI_AW-1:0] addr_a, bit [AXI_IDW-1:0] id_base);
    axi_txn          wr_a, rd_b, wr_b, rd_b2, rd_a;
    bit [AXI_AW-1:0] addr_b;
    string           p;
    p      = $sformatf("M%0d->S%0d", m, s);
    addr_b = addr_a + 32'h800;

    wr_a = new_write(id_base,     addr_a, 7);
    rd_b = new_read (id_base + 1, addr_b, 7);
    fork
      send_wait(m, wr_a);
      send_wait(m, rd_b);
    join
    check_resp($sformatf("%s write A (at the same time as read B) BRESP", p), wr_a.resp[0], RESP_OKAY);
    check_resp($sformatf("%s read B (at the same time as write A) RRESP", p), rd_b.resp[0], RESP_OKAY);

    wr_b  = new_write(id_base + 2, addr_b, 7);
    rd_b2 = new_read (id_base + 3, addr_b, 7);
    send_wait(m, wr_b);
    send_wait(m, rd_b2);
    check_data($sformatf("%s write B then read B", p), wr_b, rd_b2);

    rd_a = new_read(id_base + 4, addr_a, 7);
    send_wait(m, rd_a);
    check_data($sformatf("%s read A back", p), wr_a, rd_a);
  endtask

  // path_rw on all four paths M0->S0, M0->S1, M1->S0, M1->S1
  // (address = slave base + offset + 0x1000 * master)
  task all_paths_rw(bit [AXI_AW-1:0] offset);
    for (int m = 0; m < NUM_M; m++)
      for (int s = 0; s < NUM_S; s++)
        path_rw(m, s, slave_base(s) + offset + 32'h1000 * m, 4 * (2 * m + s));
  endtask

  // ===========================================================================
  // run() : called by tb_top
  // ===========================================================================
  task run();
    int unsigned errs;
    $display("==================================================================");
    $display(" TEST : %s", name);
    $display("==================================================================");
    configure();
    env.build();
    if ($test$plusargs("SB_VERBOSE")) env.sb.verbose = 1'b1;
    env.run();
    reset_dut();

    // main() with a timeout watchdog
    fork
      begin
        fork
          begin
            main();
            env.wait_idle();
          end
          begin
            #(timeout_ns);
            timed_out = 1'b1;
          end
        join_any
        disable fork;
      end
    join

    if (timed_out) env.print_state();
    wait_clk(10);
    $display("");
    errs = env.report() + n_fail;           // scoreboard + coverage summary
    if (timed_out) begin
      $error("[TEST] TIMEOUT after %0d ns - DUT or testbench is stuck", timeout_ns);
      errs++;
    end

    $display(" TEST CHECKS : %0d passed, %0d failed", n_pass, n_fail);
    if (proved.size() > 0) begin
      if (errs == 0) $display(" WHAT THIS TEST PROVED:");
      else           $display(" WHAT THIS TEST WANTED TO PROVE (NOT proved, the test FAILED):");
      foreach (proved[i]) $display("   %0d. %s", i + 1, proved[i]);
    end
    $display("==================================================================");
    if (errs == 0) $display(" TEST %s : PASSED", name);
    else           $display(" TEST %s : FAILED  (%0d errors)", name, errs);
    $display("==================================================================");
  endtask

endclass

`endif // AXI_BASE_TEST_SV
