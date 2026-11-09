`ifndef AXI_RESET_POR_TEST_SV
`define AXI_RESET_POR_TEST_SV

// =============================================================================
// axi_reset_por_test  (TC-02 part 1)  -  state right after power-on reset
//
//   For 5 clocks after the first reset, every VALID the crossbar drives
//   (BVALID, RVALID at the masters, AWVALID, WVALID, ARVALID at the slaves)
//   must be 0.
// =============================================================================
class axi_reset_por_test extends axi_reset_base;

  function new(string name = "axi_reset_por_test");
    super.new(name);
  endfunction

  virtual task main();
    bit    ok;
    string s;
    title("State right after power-on reset");
    valids_low_for(5, ok, s);
    info($sformatf("sampled: %s", s));
    check(ok, "after reset every crossbar VALID (BVALID RVALID AWVALID WVALID ARVALID) is 0 for 5 clocks");
    prove("all VALID outputs of the crossbar are 0 after reset (known idle state)");
  endtask

endclass

`endif
