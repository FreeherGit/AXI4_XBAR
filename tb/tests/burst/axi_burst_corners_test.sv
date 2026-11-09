`ifndef AXI_BURST_CORNERS_TEST_SV
`define AXI_BURST_CORNERS_TEST_SV

// =============================================================================
// axi_burst_corners_test  -  burst corner cases on every path
//
//   For M0->S0, M0->S1, M1->S0, M1->S1, write + read-back of:
//     INCR 256 x 8 B (2 KB)
//     WRAP 2 / 4 / 8 / 16 beats of 8 B, starting in the middle of the block
//     FIXED 1 beat, FIXED 16 x 4 B (last beat wins)
//     INCR 32 x 8 B that ends exactly on a 4 KB page edge
// =============================================================================
class axi_burst_corners_test extends axi_base_test;

  function new(string name = "axi_burst_corners_test");
    super.new(name);
  endfunction

  virtual function void configure();
    scenario_setup();
  endfunction

  virtual task main();
    bit [AXI_AW-1:0] pg;
    int              id;
    for (int m = 0; m < NUM_M; m++)
      for (int tg = 0; tg < NUM_S; tg++) begin
        title($sformatf("M%0d -> S%0d : burst corners", m, tg));
        pg = scratch(tg) + 32'h0050_0000 + 32'h0001_0000 * (2 * m + tg);
        id = 8 * m;
        write_read(m, id + 0, pg + 32'h0000,         255, 3, BURST_INCR,  "(INCR 256 x 8B)");
        write_read(m, id + 1, pg + 32'h1000 + 32'h08,  1, 3, BURST_WRAP,  "(WRAP 2, mid-block)");
        write_read(m, id + 2, pg + 32'h2000 + 32'h10,  3, 3, BURST_WRAP,  "(WRAP 4, mid-block)");
        write_read(m, id + 3, pg + 32'h3000 + 32'h20,  7, 3, BURST_WRAP,  "(WRAP 8, mid-block)");
        write_read(m, id + 4, pg + 32'h4000 + 32'h40, 15, 3, BURST_WRAP,  "(WRAP 16, mid-block)");
        write_read(m, id + 5, pg + 32'h5008,           0, 3, BURST_FIXED, "(FIXED 1 beat)");
        write_read(m, id + 6, pg + 32'h6004,          15, 2, BURST_FIXED, "(FIXED 16 x 4B, last beat wins)");
        write_read(m, id + 7, pg + 32'h7F00,          31, 3, BURST_INCR,  "(INCR 32 x 8B ends on 4 KB edge)");
      end
    prove("the longest INCR, every WRAP length with 8-byte beats, FIXED 1/16 and an INCR ending on a 4 KB edge work on every path");
  endtask

endclass

`endif
