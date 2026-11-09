`ifndef AXI_BASIC_RW_TEST_SV
`define AXI_BASIC_RW_TEST_SV

// =============================================================================
// axi_basic_rw_test  (TC-01)  -  basic read / write on every path
//
//   For M0->S0, M0->S1, M1->S0, M1->S1 (one at a time), 8-beat x 8-byte bursts:
//     1. write A and read B at the same time
//     2. write B, then read B back
//     3. read A back
//   Checked: OKAY responses, read data == written data.
// =============================================================================
class axi_basic_rw_test extends axi_base_test;

  function new(string name = "axi_basic_rw_test");
    super.new(name);
  endfunction

  virtual task main();
    bit [AXI_AW-1:0] a;
    for (int m = 0; m < NUM_M; m++) begin
      for (int s = 0; s < NUM_S; s++) begin
        a = slave_base(s) + 32'h1000 * (m + 1);
        title($sformatf("PATH M%0d -> S%0d : A=%08h  B=%08h", m, s, a, a + 32'h800));
        path_rw(m, s, a, 4 * (2 * m + s));
        wait_clk(5);
      end
    end
    prove("every master can write and read every slave (M0->S0, M0->S1, M1->S0, M1->S1)");
    prove("a write and a read issued at the same time by one master both complete with OKAY");
    prove("data read back is byte-for-byte the data written");
  endtask

endclass

`endif
