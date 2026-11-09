// =============================================================================
// axi_if.sv
//   One AXI4 port (AW, W, B, AR, R). The same interface type is used for the
//   master ports and the slave ports of the crossbar:
//     * master port : TB master driver drives AW/W/AR/BREADY/RREADY,
//                     DUT drives the rest (connected in tb_top)
//     * slave port  : DUT drives AW/W/AR/BREADY/RREADY,
//                     TB slave driver drives the rest
//   Drivers write the signals with non-blocking assignments right after a
//   clock edge; everybody samples through the input-only clocking block "cb"
//   (#1step input skew), so there are no TB/DUT races.
//
//   Protocol checks:
//     The checks are written as plain procedural code (always block), NOT as
//     SVA. Vivado xsim 2025.x crashes (SIGSEGV in xelab) on properties with
//     untyped formal ports, so this form is used to work on every simulator
//     (xsim, Questa, VCS) with the same behaviour:
//       1. VALID must stay high with a stable payload until READY  (AW/W/B/AR/R)
//       2. every VALID must be low while reset is asserted
//       3. VALID/READY must never be X/Z out of reset
//   Define AXI_NO_SVA to switch the checks off.
// =============================================================================
`ifndef AXI_IF_SV
`define AXI_IF_SV
`timescale 1ns / 1ps

interface axi_if (input logic aclk, input logic arst_n);
  import axi_params_pkg::*;

  // ---------------- write address channel
  logic [AXI_IDW-1:0] awid;
  logic [AXI_AW-1:0]  awaddr;
  logic [7:0]         awlen;
  logic [2:0]         awsize;
  logic [1:0]         awburst;
  logic               awvalid;
  logic               awready;
  // ---------------- write data channel
  logic [AXI_DW-1:0]  wdata;
  logic [AXI_SW-1:0]  wstrb;
  logic               wlast;
  logic               wvalid;
  logic               wready;
  // ---------------- write response channel
  logic [AXI_IDW-1:0] bid;
  logic [1:0]         bresp;
  logic               bvalid;
  logic               bready;
  // ---------------- read address channel
  logic [AXI_IDW-1:0] arid;
  logic [AXI_AW-1:0]  araddr;
  logic [7:0]         arlen;
  logic [2:0]         arsize;
  logic [1:0]         arburst;
  logic               arvalid;
  logic               arready;
  // ---------------- read data channel
  logic [AXI_IDW-1:0] rid;
  logic [AXI_DW-1:0]  rdata;
  logic [1:0]         rresp;
  logic               rlast;
  logic               rvalid;
  logic               rready;

  // Name used in check messages (set from tb_top: "M0", "S1", ...)
  string if_name = "axi_if";

  // ---------------------------------------------------------------------------
  // Sampling clocking block (inputs only, used by drivers AND monitors)
  // ---------------------------------------------------------------------------
  clocking cb @(posedge aclk);
    default input #1step;
    input awid, awaddr, awlen, awsize, awburst, awvalid, awready;
    input wdata, wstrb, wlast, wvalid, wready;
    input bid, bresp, bvalid, bready;
    input arid, araddr, arlen, arsize, arburst, arvalid, arready;
    input rid, rdata, rresp, rlast, rvalid, rready;
  endclocking

  // ---------------------------------------------------------------------------
  // Protocol checks (procedural, xsim-safe)
  // ---------------------------------------------------------------------------
`ifndef AXI_NO_SVA
  localparam int AW_PW = AXI_IDW + AXI_AW + 8 + 3 + 2;   // AW / AR payload width
  localparam int W_PW  = AXI_DW + AXI_SW + 1;            // W payload width
  localparam int B_PW  = AXI_IDW + 2;                    // B payload width
  localparam int R_PW  = AXI_IDW + AXI_DW + 2 + 1;       // R payload width

  // current payloads
  logic [AW_PW-1:0] aw_pl, ar_pl;
  logic [W_PW-1:0]  w_pl;
  logic [B_PW-1:0]  b_pl;
  logic [R_PW-1:0]  r_pl;

  assign aw_pl = {awid, awaddr, awlen, awsize, awburst};
  assign w_pl  = {wdata, wstrb, wlast};
  assign b_pl  = {bid, bresp};
  assign ar_pl = {arid, araddr, arlen, arsize, arburst};
  assign r_pl  = {rid, rdata, rresp, rlast};

  // values seen at the previous clock edge
  logic             p_awvalid, p_awready, p_wvalid, p_wready, p_bvalid, p_bready;
  logic             p_arvalid, p_arready, p_rvalid, p_rready;
  logic [AW_PW-1:0] p_aw, p_ar;
  logic [W_PW-1:0]  p_w;
  logic [B_PW-1:0]  p_b;
  logic [R_PW-1:0]  p_r;

  // 1 from the second clock edge after reset release (previous values valid)
  logic chk_armed = 1'b0;

  // Signals are read in the active region of the clock edge, i.e. BEFORE the
  // non-blocking updates of this edge: the same values an SVA would sample.
  always @(posedge aclk) begin
    if (arst_n !== 1'b1) begin
      // ---- check 2 : no VALID during reset
      if (awvalid === 1'b1 || wvalid === 1'b1 || bvalid === 1'b1 ||
          arvalid === 1'b1 || rvalid === 1'b1)
        $error("[CHK %s] @%0t a VALID is high during reset (AW=%b W=%b B=%b AR=%b R=%b)",
               if_name, $time, awvalid, wvalid, bvalid, arvalid, rvalid);
      chk_armed <= 1'b0;
    end else begin
      // ---- check 1 : VALID held with stable payload until READY
      if (chk_armed) begin
        if (p_awvalid === 1'b1 && p_awready !== 1'b1 && (awvalid !== 1'b1 || aw_pl !== p_aw))
          $error("[CHK %s] @%0t AW valid dropped or payload changed before AWREADY (was %h now valid=%b %h)",
                 if_name, $time, p_aw, awvalid, aw_pl);
        if (p_wvalid === 1'b1 && p_wready !== 1'b1 && (wvalid !== 1'b1 || w_pl !== p_w))
          $error("[CHK %s] @%0t W valid dropped or payload changed before WREADY (was %h now valid=%b %h)",
                 if_name, $time, p_w, wvalid, w_pl);
        if (p_bvalid === 1'b1 && p_bready !== 1'b1 && (bvalid !== 1'b1 || b_pl !== p_b))
          $error("[CHK %s] @%0t B valid dropped or payload changed before BREADY (was %h now valid=%b %h)",
                 if_name, $time, p_b, bvalid, b_pl);
        if (p_arvalid === 1'b1 && p_arready !== 1'b1 && (arvalid !== 1'b1 || ar_pl !== p_ar))
          $error("[CHK %s] @%0t AR valid dropped or payload changed before ARREADY (was %h now valid=%b %h)",
                 if_name, $time, p_ar, arvalid, ar_pl);
        if (p_rvalid === 1'b1 && p_rready !== 1'b1 && (rvalid !== 1'b1 || r_pl !== p_r))
          $error("[CHK %s] @%0t R valid dropped or payload changed before RREADY (was %h now valid=%b %h)",
                 if_name, $time, p_r, rvalid, r_pl);
      end
      // ---- check 3 : no X/Z on handshake signals out of reset
      if ($isunknown({awvalid, awready, wvalid, wready, bvalid, bready,
                      arvalid, arready, rvalid, rready}))
        $error("[CHK %s] @%0t X/Z on a VALID/READY signal (aw %b%b w %b%b b %b%b ar %b%b r %b%b)",
               if_name, $time, awvalid, awready, wvalid, wready, bvalid, bready,
               arvalid, arready, rvalid, rready);
      chk_armed <= 1'b1;
    end

    // remember this edge for the next one
    p_awvalid <= awvalid;  p_awready <= awready;  p_aw <= aw_pl;
    p_wvalid  <= wvalid;   p_wready  <= wready;   p_w  <= w_pl;
    p_bvalid  <= bvalid;   p_bready  <= bready;   p_b  <= b_pl;
    p_arvalid <= arvalid;  p_arready <= arready;  p_ar <= ar_pl;
    p_rvalid  <= rvalid;   p_rready  <= rready;   p_r  <= r_pl;
  end
`endif

endinterface

`endif
