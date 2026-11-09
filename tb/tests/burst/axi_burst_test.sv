`ifndef AXI_BURST_TEST_SV
`define AXI_BURST_TEST_SV

// =============================================================================
// axi_burst_test  (TC-05)  -  INCR / FIXED / WRAP bursts
//
//   IDEA : the crossbar must pass every kind of burst through unchanged.
//
//   HOW  : one helper task, wr_rd(), does: write a burst -> read it back with
//          the same settings -> compare byte by byte (check_data).
//          main() just calls wr_rd() once per burst case:
//            INCR  : 1 / 4 / 16 / 256 beats, narrow beats (1/2/4 bytes),
//                    unaligned start address
//            FIXED : every beat goes to the SAME address (last beat wins)
//            WRAP  : start in the middle of the block, the address wraps
//            INCR with random write strobes (only strobed bytes change)
//          Each case uses a new 4 KB page, and the master and slave
//          alternate from case to case.
// =============================================================================
class axi_burst_test extends axi_base_test;

  int n_case = 0;   // case counter: gives each case its own page and ID

  function new(string name = "axi_burst_test");
    super.new(name);
    timeout_ns = 20_000_000;
  endfunction

  // one burst case: write, read back, compare
  //   burst  : BURST_INCR / BURST_FIXED / BURST_WRAP
  //   len    : beats - 1
  //   size   : bytes per beat = 2**size
  //   offset : start offset inside the 4 KB page
  //   sparse : 1 = random write strobes
  task wr_rd(string what, bit [1:0] burst, bit [7:0] len, bit [2:0] size,
             bit [11:0] offset, bit sparse = 1'b0);
    int              m, s;
    bit [AXI_AW-1:0] addr;
    axi_txn          wr, rd;
    string           tag;

    m    = n_case % 2;             // M0, M1, M0, M1 ...
    s    = (n_case / 2) % 2;       // S0, S0, S1, S1 ...
    addr = slave_base(s) + 32'h0010_0000 + 32'h1000 * n_case + offset;
    tag  = $sformatf("case %0d %s (M%0d->S%0d)", n_case, what, m, s);

    wr = new_write(n_case % 16, addr, len, size, burst);
    if (sparse) begin
      wr.sparse_strb = 1'b1;       // clear some strobe bits at random
      wr.fill_strb();
    end
    rd = new_read((n_case + 1) % 16, addr, len, size, burst);

    send_wait(m, wr);
    send_wait(m, rd);
    check_data(tag, wr, rd);
    n_case++;
  endtask

  virtual task main();
    title("INCR : different lengths, 8-byte beats");
    wr_rd("INCR 1 beat",     BURST_INCR, 8'd0,   3'd3, 12'h040);
    wr_rd("INCR 4 beats",    BURST_INCR, 8'd3,   3'd3, 12'h040);
    wr_rd("INCR 16 beats",   BURST_INCR, 8'd15,  3'd3, 12'h040);
    wr_rd("INCR 256 beats",  BURST_INCR, 8'd255, 3'd3, 12'h000);   // 2 KB, maximum length

    title("INCR : narrow beats (1, 2, 4 bytes)");
    wr_rd("INCR 8 x 1 byte",   BURST_INCR, 8'd7,   3'd0, 12'h040);
    wr_rd("INCR 8 x 2 bytes",  BURST_INCR, 8'd7,   3'd1, 12'h040);
    wr_rd("INCR 8 x 4 bytes",  BURST_INCR, 8'd7,   3'd2, 12'h040);
    wr_rd("INCR 256 x 1 byte", BURST_INCR, 8'd255, 3'd0, 12'h100);

    title("INCR : unaligned start (first beat is partial)");
    wr_rd("INCR unaligned 0x43", BURST_INCR, 8'd7, 3'd3, 12'h043);

    title("FIXED : all beats write the same address, last beat wins");
    wr_rd("FIXED 4 beats",            BURST_FIXED, 8'd3,  3'd3, 12'h080);
    wr_rd("FIXED 16 beats x 4 bytes", BURST_FIXED, 8'd15, 3'd2, 12'h084);

    title("WRAP : start in the middle of the wrap block");
    // e.g. WRAP 4 x 8 bytes = 32-byte block 0x200..0x21F, start 0x210:
    //      beat addresses 0x210, 0x218, 0x200, 0x208 (wraps back to 0x200)
    wr_rd("WRAP 2 beats",     BURST_WRAP, 8'd1,  3'd3, 12'h208);
    wr_rd("WRAP 4 beats",     BURST_WRAP, 8'd3,  3'd3, 12'h210);
    wr_rd("WRAP 8 beats",     BURST_WRAP, 8'd7,  3'd3, 12'h220);
    wr_rd("WRAP 16 beats",    BURST_WRAP, 8'd15, 3'd3, 12'h240);
    wr_rd("WRAP 4 x 4 bytes", BURST_WRAP, 8'd3,  3'd2, 12'h208);

    title("INCR with random write strobes");
    wr_rd("INCR sparse strobes #1", BURST_INCR, 8'd7, 3'd3, 12'h300, 1'b1);
    wr_rd("INCR sparse strobes #2", BURST_INCR, 8'd7, 3'd3, 12'h300, 1'b1);

    prove($sformatf("%0d burst cases written and read back byte-for-byte", n_case));
    prove("INCR bursts of 1, 4, 16 and 256 beats, narrow (1/2/4-byte) beats and an unaligned start");
    prove("FIXED bursts: all beats go to one address, the last beat is what is stored");
    prove("WRAP bursts of 2/4/8/16 beats wrap at the block boundary");
    prove("write strobes pass through unchanged (only strobed bytes are written)");
  endtask

endclass

`endif // AXI_BURST_TEST_SV
