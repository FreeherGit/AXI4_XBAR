// =============================================================================
// axi_params_pkg.sv
//   Global parameters and AXI constants shared by the interface and all
//   testbench classes. Kept in its own package (no classes) so the interface
//   can import it without a circular dependency on axi_tb_pkg.
// =============================================================================
`ifndef AXI_PARAMS_PKG_SV
`define AXI_PARAMS_PKG_SV

package axi_params_pkg;

  // ---- crossbar configuration (must match the DUT) -------------------------
  parameter int AXI_DW  = 64;            // DATA_WIDTH
  parameter int AXI_AW  = 32;            // ADDR_WIDTH
  parameter int AXI_IDW = 4;             // ID_WIDTH
  parameter int AXI_SW  = AXI_DW / 8;    // WSTRB width (bytes per beat)
  parameter int NUM_M   = 2;             // masters
  parameter int NUM_S   = 2;             // slaves

  // ---- address map (from the spec) -----------------------------------------
  parameter logic [AXI_AW-1:0] S0_BASE  = 32'h0000_0000;
  parameter logic [AXI_AW-1:0] S0_LIMIT = 32'h0FFF_FFFF;
  parameter logic [AXI_AW-1:0] S1_BASE  = 32'h1000_0000;
  parameter logic [AXI_AW-1:0] S1_LIMIT = 32'h1FFF_FFFF;

  // ---- AXI encodings --------------------------------------------------------
  parameter logic [1:0] RESP_OKAY   = 2'b00;
  parameter logic [1:0] RESP_EXOKAY = 2'b01;
  parameter logic [1:0] RESP_SLVERR = 2'b10;
  parameter logic [1:0] RESP_DECERR = 2'b11;

  parameter logic [1:0] BURST_FIXED = 2'b00;
  parameter logic [1:0] BURST_INCR  = 2'b01;
  parameter logic [1:0] BURST_WRAP  = 2'b10;

endpackage

`endif
