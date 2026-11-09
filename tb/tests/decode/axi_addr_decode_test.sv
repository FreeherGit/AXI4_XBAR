`ifndef AXI_ADDR_DECODE_TEST_SV
`define AXI_ADDR_DECODE_TEST_SV

// =============================================================================
// axi_addr_decode_test  (TC-03)  -  address decoding
//
//   IDEA : the crossbar looks at the address and picks the slave.
//            0x0000_0000 .. 0x0FFF_FFFF -> S0
//            0x1000_0000 .. 0x1FFF_FFFF -> S1
//            anything else              -> no slave, answer DECERR
//
//   HOW  : for both masters, write + read one word at the first and last
//          word of S0, the first and last word of S1, and two unmapped
//          addresses. Count how many writes each slave received.
//
//   CHECK: mapped address   -> exactly 1 write at the right slave, 0 at the
//                              other one, and the data reads back correctly
//          unmapped address -> no slave saw it, BRESP and RRESP are DECERR
// =============================================================================
class axi_addr_decode_test extends axi_base_test;

  function new(string name = "axi_addr_decode_test");
    super.new(name);
  endfunction

  // expected target from the spec: 0 = S0, 1 = S1, 2 = unmapped
  function int expected_slave(bit [AXI_AW-1:0] a);
    if (a <= 32'h0FFF_FFFF) return 0;
    if (a <= 32'h1FFF_FFFF) return 1;
    return 2;
  endfunction

  virtual task main();
    bit [AXI_AW-1:0] addrs[$] = '{32'h0000_0000, 32'h0FFF_FFF8,    // first / last word of S0
                                  32'h1000_0000, 32'h1FFF_FFF8,    // first / last word of S1
                                  32'h2000_0000, 32'hFFFF_FFF8};   // unmapped
    axi_txn wr, rd;
    int     exp_s;
    int     s0_before, s1_before;   // write counters of the slave monitors
    int     s0_got, s1_got;         // how many new writes each slave saw
    string  what;

    for (int m = 0; m < NUM_M; m++) begin
      title($sformatf("MASTER M%0d : one write + one read per address", m));
      foreach (addrs[k]) begin
        exp_s     = expected_slave(addrs[k]);
        s0_before = env.s_agt[0].mon.n_wr;
        s1_before = env.s_agt[1].mon.n_wr;

        wr = new_write(8 * m + 1, addrs[k]);
        rd = new_read (8 * m + 2, addrs[k]);
        send_wait(m, wr);
        send_wait(m, rd);
        wait_clk(2);

        s0_got = env.s_agt[0].mon.n_wr - s0_before;
        s1_got = env.s_agt[1].mon.n_wr - s1_before;
        what   = $sformatf("M%0d addr %08h (expected %s)", m, addrs[k], tgt_name(exp_s));
        info($sformatf("%s : S0 got %0d write, S1 got %0d write | BRESP=%s RRESP=%s",
                       what, s0_got, s1_got, axi_resp_str(wr.resp[0]), axi_resp_str(rd.resp[0])));

        if (exp_s == 0) begin
          check_num({what, " : writes seen at S0"}, s0_got, 1);
          check_num({what, " : writes seen at S1"}, s1_got, 0);
          check_data({what, " : read back"}, wr, rd);
        end
        else if (exp_s == 1) begin
          check_num({what, " : writes seen at S0"}, s0_got, 0);
          check_num({what, " : writes seen at S1"}, s1_got, 1);
          check_data({what, " : read back"}, wr, rd);
        end
        else begin
          check_num({what, " : writes seen at S0"}, s0_got, 0);
          check_num({what, " : writes seen at S1"}, s1_got, 0);
          check_resp({what, " : BRESP"}, wr.resp[0], RESP_DECERR);
          check_resp({what, " : RRESP"}, rd.resp[0], RESP_DECERR);
        end
      end
    end

    prove("S0 addresses (first and last word) go only to S0");
    prove("S1 addresses (first and last word) go only to S1");
    prove("unmapped addresses reach no slave and get DECERR");
    prove("M0 and M1 decode addresses the same way");
  endtask

endclass

`endif // AXI_ADDR_DECODE_TEST_SV
