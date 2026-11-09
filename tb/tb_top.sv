// =============================================================================
// tb_top.sv  -  testbench top for the AXI4 2x2 crossbar
//   * clock (100 MHz) and reset interface
//   * 2 master-port and 2 slave-port AXI interfaces
//   * DUT (axi4_xbar) connected through the packed-array ports
//   * creates the test chosen with +TESTNAME=<name> and runs it
//   Plusargs:  +TESTNAME=axi_smoke_test   +DUMP (write dump.vcd)
//
//   This file `includes the whole testbench, so the compile command only
//   needs:   axi4_xbar.sv  tb_top.sv   (+incdir to this folder)
// =============================================================================
`timescale 1ns / 1ps

`include "axi_params_pkg.sv"
`include "axi_if.sv"
`include "axi_rst_if.sv"
`include "axi_tb_pkg.sv"
`include "axi_test_pkg.sv"
`include "axi_xbar_wb_cov.sv"
module tb_top;

  import axi_params_pkg::*;
  import axi_tb_pkg::*;
  import axi_test_pkg::*;

  // ---------------------------------------------------------------- clock / reset
  logic aclk = 1'b0;
  always #5 aclk = ~aclk;

  axi_rst_if rst_if (aclk);
  wire arst_n = rst_if.arst_n;

  // ---------------------------------------------------------------- interfaces
  axi_if m_if [NUM_M] (.aclk(aclk), .arst_n(arst_n));
  axi_if s_if [NUM_S] (.aclk(aclk), .arst_n(arst_n));

  // ---------------------------------------------------------------- DUT-side vectors
  logic [NUM_M-1:0][AXI_IDW-1:0] m_awid,   m_arid,   m_bid,   m_rid;
  logic [NUM_M-1:0][AXI_AW-1:0]  m_awaddr, m_araddr;
  logic [NUM_M-1:0][7:0]         m_awlen,  m_arlen;
  logic [NUM_M-1:0][AXI_SW-1:0]  m_wstrb;
  logic [NUM_M-1:0][2:0]         m_awsize, m_arsize;
  logic [NUM_M-1:0][1:0]         m_awburst, m_arburst, m_bresp, m_rresp;
  logic [NUM_M-1:0][AXI_DW-1:0]  m_wdata,  m_rdata;
  logic [NUM_M-1:0]              m_awvalid, m_awready, m_wlast, m_wvalid, m_wready;
  logic [NUM_M-1:0]              m_bvalid,  m_bready,  m_arvalid, m_arready;
  logic [NUM_M-1:0]              m_rlast,   m_rvalid,  m_rready;

  logic [NUM_S-1:0][AXI_IDW-1:0] s_awid,   s_arid,   s_bid,   s_rid;
  logic [NUM_S-1:0][AXI_AW-1:0]  s_awaddr, s_araddr;
  logic [NUM_S-1:0][7:0]         s_awlen,  s_arlen;
  logic [NUM_S-1:0][AXI_SW-1:0]  s_wstrb;
  logic [NUM_S-1:0][2:0]         s_awsize, s_arsize;
  logic [NUM_S-1:0][1:0]         s_awburst, s_arburst, s_bresp, s_rresp;
  logic [NUM_S-1:0][AXI_DW-1:0]  s_wdata,  s_rdata;
  logic [NUM_S-1:0]              s_awvalid, s_awready, s_wlast, s_wvalid, s_wready;
  logic [NUM_S-1:0]              s_bvalid,  s_bready,  s_arvalid, s_arready;
  logic [NUM_S-1:0]              s_rlast,   s_rvalid,  s_rready;

  // ---------------------------------------------------------------- DUT
  axi4_xbar #(
    .NUM_MASTERS (NUM_M),
    .NUM_SLAVES  (NUM_S),
    .DATA_WIDTH  (AXI_DW),
    .ADDR_WIDTH  (AXI_AW),
    .ID_WIDTH    (AXI_IDW)
  ) dut (.*);
  axi_xbar_wb_cov u_wb_cov (.aclk(aclk), .arst_n(arst_n));
  // ---------------------------------------------------------------- master ports
  // TB master drives requests -> DUT ;  DUT drives readies/responses -> TB
  for (genvar i = 0; i < NUM_M; i++) begin : g_mport
    assign m_awid[i]    = m_if[i].awid;
    assign m_awaddr[i]  = m_if[i].awaddr;
    assign m_awlen[i]   = m_if[i].awlen;
    assign m_awsize[i]  = m_if[i].awsize;
    assign m_awburst[i] = m_if[i].awburst;
    assign m_awvalid[i] = m_if[i].awvalid;
    assign m_if[i].awready = m_awready[i];

    assign m_wdata[i]   = m_if[i].wdata;
    assign m_wstrb[i]   = m_if[i].wstrb;
    assign m_wlast[i]   = m_if[i].wlast;
    assign m_wvalid[i]  = m_if[i].wvalid;
    assign m_if[i].wready  = m_wready[i];

    assign m_if[i].bid     = m_bid[i];
    assign m_if[i].bresp   = m_bresp[i];
    assign m_if[i].bvalid  = m_bvalid[i];
    assign m_bready[i]  = m_if[i].bready;

    assign m_arid[i]    = m_if[i].arid;
    assign m_araddr[i]  = m_if[i].araddr;
    assign m_arlen[i]   = m_if[i].arlen;
    assign m_arsize[i]  = m_if[i].arsize;
    assign m_arburst[i] = m_if[i].arburst;
    assign m_arvalid[i] = m_if[i].arvalid;
    assign m_if[i].arready = m_arready[i];

    assign m_if[i].rid     = m_rid[i];
    assign m_if[i].rdata   = m_rdata[i];
    assign m_if[i].rresp   = m_rresp[i];
    assign m_if[i].rlast   = m_rlast[i];
    assign m_if[i].rvalid  = m_rvalid[i];
    assign m_rready[i]  = m_if[i].rready;
  end

  // ---------------------------------------------------------------- slave ports
  // DUT drives requests -> TB slave ;  TB slave drives readies/responses -> DUT
  for (genvar i = 0; i < NUM_S; i++) begin : g_sport
    assign s_if[i].awid    = s_awid[i];
    assign s_if[i].awaddr  = s_awaddr[i];
    assign s_if[i].awlen   = s_awlen[i];
    assign s_if[i].awsize  = s_awsize[i];
    assign s_if[i].awburst = s_awburst[i];
    assign s_if[i].awvalid = s_awvalid[i];
    assign s_awready[i] = s_if[i].awready;

    assign s_if[i].wdata   = s_wdata[i];
    assign s_if[i].wstrb   = s_wstrb[i];
    assign s_if[i].wlast   = s_wlast[i];
    assign s_if[i].wvalid  = s_wvalid[i];
    assign s_wready[i]  = s_if[i].wready;

    assign s_bid[i]     = s_if[i].bid;
    assign s_bresp[i]   = s_if[i].bresp;
    assign s_bvalid[i]  = s_if[i].bvalid;
    assign s_if[i].bready  = s_bready[i];

    assign s_if[i].arid    = s_arid[i];
    assign s_if[i].araddr  = s_araddr[i];
    assign s_if[i].arlen   = s_arlen[i];
    assign s_if[i].arsize  = s_arsize[i];
    assign s_if[i].arburst = s_arburst[i];
    assign s_if[i].arvalid = s_arvalid[i];
    assign s_arready[i] = s_if[i].arready;

    assign s_rid[i]     = s_if[i].rid;
    assign s_rdata[i]   = s_if[i].rdata;
    assign s_rresp[i]   = s_if[i].rresp;
    assign s_rlast[i]   = s_if[i].rlast;
    assign s_rvalid[i]  = s_if[i].rvalid;
    assign s_if[i].rready  = s_rready[i];
  end

  // ---------------------------------------------------------------- names for SVA messages
  initial begin
    m_if[0].if_name = "M0";
    m_if[1].if_name = "M1";
    s_if[0].if_name = "S0";
    s_if[1].if_name = "S1";
  end

  // ---------------------------------------------------------------- waves
  initial begin
    if ($test$plusargs("DUMP")) begin
      $dumpfile("dump.vcd");
      $dumpvars(0, tb_top);
    end
  end

  // ---------------------------------------------------------------- run the test
  initial begin
    axi_base_test test;
    string        tname;
    if (!$value$plusargs("TESTNAME=%s", tname)) tname = "axi_smoke_test";
    test = axi_create_test(tname);
    if (test == null) $fatal(1, "[TB] Unknown test '%s' (add it to axi_create_test)", tname);
    test.set_vifs(m_if[0], m_if[1], s_if[0], s_if[1], rst_if);
    test.run();
    $finish;
  end

endmodule
