`ifndef AXI_RESET_BASE_SV
`define AXI_RESET_BASE_SV

// =============================================================================
// axi_reset_base  -  shared code of the reset tests (not a test on its own)
//
//   valids_low(s) : 1 if every VALID the crossbar drives is 0
//                   (master side BVALID / RVALID, slave side AWVALID / WVALID / ARVALID)
//                   s returns the sampled values as text
// =============================================================================
class axi_reset_base extends axi_base_test;

  function new(string name);
    super.new(name);
  endfunction

  function bit valids_low(output string s);
    bit low = 1'b1;
    s = "";
    for (int m = 0; m < NUM_M; m++) begin
      s = {s, $sformatf("M%0d bvalid=%b rvalid=%b | ", m, env.m_vif[m].bvalid, env.m_vif[m].rvalid)};
      if (env.m_vif[m].bvalid !== 1'b0) low = 1'b0;
      if (env.m_vif[m].rvalid !== 1'b0) low = 1'b0;
    end
    for (int p = 0; p < NUM_S; p++) begin
      s = {s, $sformatf("S%0d awvalid=%b wvalid=%b arvalid=%b | ", p,
                        env.s_vif[p].awvalid, env.s_vif[p].wvalid, env.s_vif[p].arvalid)};
      if (env.s_vif[p].awvalid !== 1'b0) low = 1'b0;
      if (env.s_vif[p].wvalid  !== 1'b0) low = 1'b0;
      if (env.s_vif[p].arvalid !== 1'b0) low = 1'b0;
    end
    return low;
  endfunction

  // 1 if all crossbar VALIDs stay 0 for n clocks
  task valids_low_for(int n, output bit ok, output string s);
    ok = 1'b1;
    repeat (n) begin
      wait_clk(1);
      if (!valids_low(s)) ok = 1'b0;
    end
  endtask

endclass

`endif
