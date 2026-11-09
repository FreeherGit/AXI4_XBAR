`ifndef AXI_SIZES_STROBES_TEST_SV
`define AXI_SIZES_STROBES_TEST_SV

// =============================================================================
// axi_sizes_strobes_test  -  every beat size and write strobes on every path
//
//   Part A : 4-beat INCR with 1, 2, 4 and 8-byte beats on M0->S0, M0->S1,
//            M1->S0, M1->S1 (1-byte transfers start on an odd address)
//   Part B : 4-beat 8-byte INCR with strobes
//              beat0 = 5A, beat1 = 00 (nothing written), beat2 = F0, beat3 = FF
//            the read-back compares only the bytes whose strobe was 1
// =============================================================================
class axi_sizes_strobes_test extends axi_base_test;

  function new(string name = "axi_sizes_strobes_test");
    super.new(name);
  endfunction

  virtual function void configure();
    scenario_setup();
  endfunction

  virtual task main();
    axi_txn          wr, rd;
    bit [AXI_AW-1:0] a;

    title("PART A : 4-beat INCR, sizes 1/2/4/8 bytes, every path");
    for (int m = 0; m < NUM_M; m++)
      for (int tg = 0; tg < NUM_S; tg++)
        for (int z = 0; z < 4; z++) begin
          a = scratch(tg) + 32'h0030_0000 + 32'h1000 * (2 * m + tg) + 32'h100 * z;
          if (z == 0) a = a + 3;                     // odd start address for 1-byte beats
          write_read(m, 8 * m + z, a, 3, z, BURST_INCR);
        end

    title("PART B : strobes 5A / 00 / F0 / FF on every path");
    for (int m = 0; m < NUM_M; m++)
      for (int tg = 0; tg < NUM_S; tg++) begin
        a  = scratch(tg) + 32'h0031_0000 + 32'h1000 * (2 * m + tg);
        wr = new_write(8 * m + 5, a, 3);
        wr.strb[0] = 8'h5A;
        wr.strb[1] = 8'h00;
        wr.strb[2] = 8'hF0;                          // beat 3 keeps FF
        rd = new_read(8 * m + 5, a, 3);
        send_wait(m, wr);
        send_wait(m, rd);
        check_pair($sformatf("M%0d->%s strobes 5A/00/F0/FF addr=%08h", m, tgt_name(tg), a), wr, rd);
      end

    prove("1, 2, 4 and 8-byte beats are routed and stored correctly on every path");
    prove("bytes with WSTRB = 0 are left untouched (also a beat with no strobe at all)");
  endtask

endclass

`endif
