`ifndef AXI_ADDR_EDGES_TEST_SV
`define AXI_ADDR_EDGES_TEST_SV

// =============================================================================
// axi_addr_edges_test  -  first and last address of every region
//
//   The decoder must switch exactly at 0x1000_0000 and 0x2000_0000.
//   Both masters write + read back each of these 8 bursts:
//     S0 first 8 bytes, S0 last 8 bytes, S0 4 beats ending at 0x0FFF_FFFF
//     S1 first 8 bytes, S1 last 8 bytes, S1 4 beats ending at 0x1FFF_FFFF
//     0x2000_0000 (first unmapped) and 0xFFFF_FFF8 (last address) -> DECERR
// =============================================================================
class axi_addr_edges_test extends axi_base_test;

  function new(string name = "axi_addr_edges_test");
    super.new(name);
  endfunction

  virtual function void configure();
    scenario_setup();
  endfunction

  virtual task main();
    bit [AXI_AW-1:0] addr[8] = '{32'h0000_0000, 32'h0FFF_FFF8, 32'h0FFF_FFE0, 32'h1000_0000,
                                 32'h1FFF_FFF8, 32'h1FFF_FFE0, 32'h2000_0000, 32'hFFFF_FFF8};
    bit [7:0]        len [8] = '{0, 0, 3, 0, 0, 3, 0, 0};
    string           note[8] = '{"(S0 first 8 bytes)", "(S0 last 8 bytes)", "(S0 4 beats to 4 KB edge)",
                                 "(S1 first 8 bytes)", "(S1 last 8 bytes)", "(S1 4 beats to 4 KB edge)",
                                 "(first unmapped -> DECERR)", "(last address -> DECERR)"};
    for (int m = 0; m < NUM_M; m++) begin
      title($sformatf("M%0d : first and last addresses of S0, S1 and the unmapped area", m));
      for (int i = 0; i < 8; i++)
        write_read(m, 8 * m + i, addr[i], len[i], 3, BURST_INCR, note[i]);
    end
    prove("the first and last bytes of S0 and S1 go to the right slave, for both masters");
    prove("0x2000_0000 and 0xFFFF_FFF8 get DECERR, for both masters");
  endtask

endclass

`endif
