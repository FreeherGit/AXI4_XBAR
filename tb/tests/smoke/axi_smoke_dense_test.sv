`ifndef AXI_SMOKE_DENSE_TEST_SV
`define AXI_SMOKE_DENSE_TEST_SV

// =============================================================================
// axi_smoke_dense_test  -  every byte of the lowest and highest 4 KB
//
//   For S0 and S1:
//     M0 writes every byte of the FIRST 4 KB of the slave
//     M1 writes every byte of the LAST  4 KB of the slave
//   with 256-beat x 8-byte INCR bursts (2 KB each, all strobes on),
//   then reads every burst back and compares byte by byte.
//
//   +SMOKE_DENSE=<bytes>  changes the 4 KB (rounded down to 2 KB steps)
// =============================================================================
class axi_smoke_dense_test extends axi_base_test;

  int unsigned dense_bytes = 4096;

  function new(string name = "axi_smoke_dense_test");
    super.new(name);
    timeout_ns = 50_000_000;
  endfunction

  // master m writes every byte of [start, start + bytes) and reads it back
  task dense_block(int m, int s, bit [AXI_AW-1:0] start, int unsigned bytes);
    axi_txn          wr, rd;
    bit [AXI_IDW-1:0] wid, rid;
    bit [AXI_AW-1:0] a;
    if (m == 0) begin wid = 4'h1;  rid = 4'h2; end
    else        begin wid = 4'h9;  rid = 4'hA; end

    for (int unsigned off = 0; off < bytes; off += 2048) begin
      a  = start + off;
      wr = new_write(wid, a, 255);              // 256 beats x 8 bytes = 2 KB
      foreach (wr.strb[i]) wr.strb[i] = '1;     // write all 8 bytes of every beat
      send_wait(m, wr);
      rd = new_read(rid, a, 255);
      send_wait(m, rd);
      check_data($sformatf("M%0d->S%0d bytes %08h..%08h", m, s, a, a + 2047), wr, rd);
    end
  endtask

  virtual task main();
    bit [AXI_AW-1:0] top;
    void'($value$plusargs("SMOKE_DENSE=%d", dense_bytes));
    dense_bytes = (dense_bytes / 2048) * 2048;
    if (dense_bytes == 0) dense_bytes = 2048;

    for (int s = 0; s < NUM_S; s++) begin
      if (s == 0) top = S0_LIMIT;
      else        top = S1_LIMIT;
      title($sformatf("S%0d : first %0d bytes by M0, last %0d bytes by M1", s, dense_bytes, dense_bytes));
      dense_block(0, s, slave_base(s),        dense_bytes);
      dense_block(1, s, top + 1 - dense_bytes, dense_bytes);
    end

    prove($sformatf("every byte of the first and last %0d bytes of S0 and S1 can be written and read back", dense_bytes));
  endtask

endclass

`endif
