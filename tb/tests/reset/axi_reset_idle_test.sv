`ifndef AXI_RESET_IDLE_TEST_SV
`define AXI_RESET_IDLE_TEST_SV

// =============================================================================
// axi_reset_idle_test  -  reset while the crossbar is completely idle
//
//   Reset is pulsed for 5 clocks with no traffic, then every master writes
//   and reads back S0, S1 and an UNMAPPED address (DECERR expected there).
// =============================================================================
class axi_reset_idle_test extends axi_base_test;

  function new(string name = "axi_reset_idle_test");
    super.new(name);
  endfunction

  virtual function void configure();
    scenario_setup();
  endfunction

  virtual task main();
    title("Reset while idle, then every master to S0, S1 and UNMAPPED");
    env.rst_vif.apply_reset(5);
    wait_clk(3);
    info("reset released, checking every path");
    for (int m = 0; m < NUM_M; m++)
      for (int tg = 0; tg < 3; tg++)
        write_read(m, 8 * m + 1, scratch(tg) + 32'h0040_0000 + 32'h1000 * m, 1, 3, BURST_INCR,
                   "(after idle reset)");
    prove("a reset while idle leaves the crossbar ready: every master reaches S0, S1 and gets DECERR for unmapped");
  endtask

endclass

`endif
