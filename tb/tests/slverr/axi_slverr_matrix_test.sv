`ifndef AXI_SLVERR_MATRIX_TEST_SV
`define AXI_SLVERR_MATRIX_TEST_SV

// =============================================================================
// axi_slverr_matrix_test  -  SLVERR from S0 and S1 to M0 and M1
//
//   Same SLVERR windows as axi_slverr_test. Every master writes + reads
//   inside the window of every slave: a 2-beat INCR (8 B) and a 4-beat
//   WRAP (4 B). Checked: response == reference model (SLVERR), IDs echoed.
// =============================================================================
class axi_slverr_matrix_test extends axi_base_test;

  function new(string name = "axi_slverr_matrix_test");
    super.new(name);
  endfunction

  virtual function void configure();
    scenario_setup();
    env.s_cfg[0].err_en = 1;  env.s_cfg[0].err_lo = 32'h0000_8000;  env.s_cfg[0].err_hi = 32'h0000_8FFF;
    env.s_cfg[1].err_en = 1;  env.s_cfg[1].err_lo = 32'h1000_8000;  env.s_cfg[1].err_hi = 32'h1000_8FFF;
  endfunction

  virtual task main();
    bit [AXI_AW-1:0] win;
    for (int m = 0; m < NUM_M; m++)
      for (int s = 0; s < NUM_S; s++) begin
        title($sformatf("M%0d -> S%0d inside the SLVERR window", m, s));
        win = env.s_cfg[s].err_lo;
        write_read(m, 8 * m + 6, win + 32'h40 * m,          1, 3, BURST_INCR, "(inside window)");
        write_read(m, 8 * m + 7, win + 32'h80 + 32'h40 * m, 3, 2, BURST_WRAP, "(WRAP inside window)");
      end
    prove("a SLVERR from S0 or S1 reaches the master that caused it, with its own ID, on writes and on every read beat");
  endtask

endclass

`endif
