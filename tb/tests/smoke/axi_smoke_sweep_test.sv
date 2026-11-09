`ifndef AXI_SMOKE_SWEEP_TEST_SV
`define AXI_SMOKE_SWEEP_TEST_SV

// =============================================================================
// axi_smoke_sweep_test  -  one word every 1 MB over all of S0 and S1
//
//   Words from the first to the last address of each slave (257 per slave
//   with the default 1 MB step) are written (M0 and M1 take turns), then
//   read back by the other master. Address at the slave port, data and
//   response are compared for every word. (shared code: axi_smoke_base.sv)
//
//   Only wrong words and a summary are printed; +VERBOSE prints every word.
//   +SMOKE_STRIDE=<hex bytes> changes the step, e.g. +SMOKE_STRIDE=10000 (64 KB)
// =============================================================================
class axi_smoke_sweep_test extends axi_smoke_base;

  bit [AXI_AW-1:0] stride = 32'h0010_0000;   // 1 MB

  function new(string name = "axi_smoke_sweep_test");
    super.new(name);
  endfunction

  virtual task main();
    bit [AXI_AW-1:0] addrs[$];
    string           notes[$];
    longint unsigned off;

    void'($value$plusargs("SMOKE_STRIDE=%h", stride));
    stride = stride & ~32'd7;
    if (stride == 0) stride = 32'd8;
    fork watch_slaves(); join_none

    for (int s = 0; s < NUM_S; s++) begin
      title($sformatf("S%0d : one word every 0x%08h bytes, first to last address", s, stride));
      addrs.delete();
      notes.delete();
      for (off = 0; off <= last_off(); off += stride) begin
        addrs.push_back(slave_base(s) + AXI_AW'(off));
        notes.push_back($sformatf("offset %07h", off));
      end
      if (addrs[$] != slave_base(s) + last_off()) begin
        addrs.push_back(slave_base(s) + last_off());
        notes.push_back("last word");
      end
      check_words("SWEEP", s, addrs, notes, verbose);
    end

    prove($sformatf("a word every 0x%08h bytes from the first to the last address of S0 and S1 is written and read back correctly", stride));
  endtask

endclass

`endif
