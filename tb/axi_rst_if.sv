// =============================================================================
// axi_rst_if.sv
//   Owns the shared active-low asynchronous reset arst_n.
//   Tests call these tasks through a virtual interface:
//     apply_reset(n)  : assert, hold n clocks, release away from the edge
//     assert_reset()  : assert immediately (asynchronous, e.g. mid-traffic)
//     release_reset() : release on the next falling clock edge
// =============================================================================
`ifndef AXI_RST_IF_SV
`define AXI_RST_IF_SV
`timescale 1ns / 1ps

interface axi_rst_if (input logic aclk);

  logic arst_n;

  initial arst_n = 1'b0;   // in reset from time 0

  task automatic assert_reset();
    arst_n = 1'b0;
  endtask

  task automatic release_reset();
    @(negedge aclk);
    arst_n = 1'b1;
  endtask

  task automatic apply_reset(int unsigned cycles = 10);
    assert_reset();
    repeat (cycles) @(posedge aclk);
    release_reset();
  endtask

endinterface

`endif
