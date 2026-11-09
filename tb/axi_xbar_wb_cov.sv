// =============================================================================
// axi_xbar_wb_cov.sv  -  WHITE-BOX coverage of the crossbar RTL internals
//
//   The class-based coverage (axi_coverage.sv) only sees the pins. This
//   module looks INSIDE the DUT (tb_top.dut) and counts the conditions that
//   decide what the crossbar does. Every one of them is a branch / condition
//   in the RTL, so a hole here points at RTL code that no test has run.
//
//   Request side (AW controller u_aw_ctrl and AR controller u_ar_ctrl,
//   for every target S0 / S1 / DEC(ERR) and every master M0 / M1):
//     arb_winner    both masters qualified for the same target in the same
//                   clock; bin = who won (round-robin must give both)
//     grant_lock    grant held because the target was not ready (lock)
//     blk_elsewhere request blocked: same ID still outstanding at ANOTHER
//                   target (single-slave-per-ID ordering rule)
//     blk_taken     request blocked: same ID at this target owned by the
//                   OTHER master
//     blk_full      request blocked: 8 (MAXOUT) of this ID already
//                   outstanding at this target
//     blk_drain     request blocked: the other master waits for the same
//                   (target, ID), so the owner stops issuing (anti-starve)
//     acc_same_id   request accepted while the same ID was already
//                   outstanding at that target (pipelined same ID)
//     acc_shared    request accepted while the OTHER master had a different
//                   ID outstanding at the same target (target shared)
//     blk_wq_full   AW blocked: master W-order FIFO full   (AW only)
//     blk_tq_full   AW blocked: target W-order FIFO full   (AW only)
//   Response side:
//     rsp_collide   two targets have a B (or R) for the same master at once
//     rsp_stall     B / R to a master held because the master was not ready
//     rsp_unknown_id  a slave returned a B / R whose ID nobody waits for
//                   (crossbar sinks it; needs an error-injection test)
//     r_interleave  a master got R beats of a burst from one target in the
//                   middle of an unfinished burst from the other target
//   Misc:
//     fifo_full     each internal FIFO reached full
//     w_wait        W valid with no accepted AW yet (W early / same clock),
//                   W waiting for the other master's earlier W at the target
//     misc          DECERR responder with 2+ write responses queued,
//                   reset while traffic was in flight, reset while idle
//
//   Instantiate once inside tb_top (after the DUT):
//       axi_xbar_wb_cov u_wb_cov (.aclk(aclk), .arst_n(arst_n));
//   A short summary (bins hit, coverage %) is printed by a final block after
//   the TEST PASSED/FAILED banner. +COV_DETAIL prints the full table.
//   Compile with +define+AXI_NO_COV to drop the covergroup (the counters
//   and the table still work).
//
//   The hierarchical paths below match rtl/axi4_xbar.sv (v2). If the RTL
//   signal names change, xelab reports the missing name here.
// =============================================================================
`ifndef AXI_XBAR_WB_COV_SV
`define AXI_XBAR_WB_COV_SV
`timescale 1ns / 1ps

module axi_xbar_wb_cov (input logic aclk, input logic arst_n);

  localparam int NT     = 3;      // S0, S1, DECERR target
  localparam int NID    = 16;     // 4-bit IDs
  localparam int MAXOUT = 8;      // xbar_req_ctrl MAXOUT default

  // event kinds
  localparam int K_ARB        = 0;
  localparam int K_LOCK       = 1;
  localparam int K_BLK_ELSE   = 2;
  localparam int K_BLK_TAKEN  = 3;
  localparam int K_BLK_FULL   = 4;
  localparam int K_BLK_DRAIN  = 5;
  localparam int K_ACC_SAMEID = 6;
  localparam int K_ACC_SHARED = 7;
  localparam int K_BLK_WQ     = 8;
  localparam int K_BLK_TQ     = 9;
  localparam int K_RSP_COLL   = 10;
  localparam int K_RSP_STALL  = 11;
  localparam int K_RSP_UNK    = 12;
  localparam int K_R_ILV      = 13;
  localparam int K_FIFO_FULL  = 14;
  localparam int K_W_WAIT     = 15;
  localparam int K_MISC       = 16;
  localparam int NK           = 17;
  localparam int NB           = 12;

  int          ev_kind, ev_code;
  int unsigned h [NK][NB];

  // snapshot of both request controllers  [0] = AW, [1] = AR
  logic [1:0]              c_mvalid [2];
  logic [1:0][1:0]         c_mtgt   [2];
  logic [1:0][3:0]         c_mid    [2];
  logic [1:0]              c_mok    [2];
  logic [NT-1:0]           c_tok    [2];
  logic [NT-1:0]           c_trdy   [2];
  logic [NT-1:0]           c_lock   [2];
  logic [NT-1:0]           c_lockm  [2];
  logic [NT-1:0][1:0]      c_req    [2];
  logic [NT-1:0][1:0]      c_gnt    [2];
  logic [NT-1:0][NID-1:0]  c_busy   [2];
  logic [NT-1:0][NID-1:0]  c_own    [2];
  int                      c_cnt    [2][NT][NID];

  bit r_open [2][NT];     // master m has an unfinished R burst from target t
  bit busy_q;             // traffic in flight at the last clock edge

  // ---------------------------------------------------------------------------
  // covergroup: one sample per event, only the coverpoint of that kind counts
  // bins for the 12-value codes: code = channel*6 + target*2 + master
  // ---------------------------------------------------------------------------
`define XB_CTM_BINS \
    bins aw_s0_m0  = {0};  bins aw_s0_m1  = {1};  bins aw_s1_m0  = {2};  bins aw_s1_m1  = {3}; \
    bins aw_dec_m0 = {4};  bins aw_dec_m1 = {5};  bins ar_s0_m0  = {6};  bins ar_s0_m1  = {7}; \
    bins ar_s1_m0  = {8};  bins ar_s1_m1  = {9};  bins ar_dec_m0 = {10}; bins ar_dec_m1 = {11};

`ifndef AXI_NO_COV
  covergroup cg_wb;
    option.per_instance = 1;
    cp_arb_winner    : coverpoint ev_code iff (ev_kind == K_ARB)        { `XB_CTM_BINS }
    cp_grant_lock    : coverpoint ev_code iff (ev_kind == K_LOCK)       { `XB_CTM_BINS }
    cp_blk_elsewhere : coverpoint ev_code iff (ev_kind == K_BLK_ELSE)   { `XB_CTM_BINS }
    cp_blk_taken     : coverpoint ev_code iff (ev_kind == K_BLK_TAKEN)  { `XB_CTM_BINS }
    cp_blk_full      : coverpoint ev_code iff (ev_kind == K_BLK_FULL)   { `XB_CTM_BINS }
    cp_blk_drain     : coverpoint ev_code iff (ev_kind == K_BLK_DRAIN)  { `XB_CTM_BINS }
    cp_acc_same_id   : coverpoint ev_code iff (ev_kind == K_ACC_SAMEID) { `XB_CTM_BINS }
    cp_acc_shared    : coverpoint ev_code iff (ev_kind == K_ACC_SHARED) { `XB_CTM_BINS }
    cp_blk_wq_full   : coverpoint ev_code iff (ev_kind == K_BLK_WQ)     {
                         bins aw_m0 = {0}; bins aw_m1 = {1}; }
    cp_blk_tq_full   : coverpoint ev_code iff (ev_kind == K_BLK_TQ)     {
                         bins aw_s0 = {0}; bins aw_s1 = {1}; bins aw_dec = {2}; }
    cp_rsp_collide   : coverpoint ev_code iff (ev_kind == K_RSP_COLL)   {
                         bins b_m0 = {0}; bins b_m1 = {1}; bins r_m0 = {2}; bins r_m1 = {3}; }
    cp_rsp_stall     : coverpoint ev_code iff (ev_kind == K_RSP_STALL)  {
                         bins b_m0 = {0}; bins b_m1 = {1}; bins r_m0 = {2}; bins r_m1 = {3}; }
    cp_rsp_unknown_id: coverpoint ev_code iff (ev_kind == K_RSP_UNK)    {
                         bins b_s0 = {0}; bins b_s1 = {1}; bins r_s0 = {2}; bins r_s1 = {3}; }
    cp_r_interleave  : coverpoint ev_code iff (ev_kind == K_R_ILV)      {
                         bins m0 = {0}; bins m1 = {1}; }
    cp_fifo_full     : coverpoint ev_code iff (ev_kind == K_FIFO_FULL)  {
                         bins wq_m0  = {0}; bins wq_m1  = {1}; bins tq_s0  = {2}; bins tq_s1 = {3};
                         bins tq_dec = {4}; bins dec_aw = {5}; bins dec_ar = {6}; }
    cp_w_wait        : coverpoint ev_code iff (ev_kind == K_W_WAIT)     {
                         bins no_aw_m0 = {0}; bins no_aw_m1 = {1}; bins order_m0 = {2}; bins order_m1 = {3}; }
    cp_misc          : coverpoint ev_code iff (ev_kind == K_MISC)       {
                         bins dec_b_backlog = {0}; bins rst_busy = {1}; bins rst_idle = {2}; }
  endgroup

  cg_wb cg_i = new();
`endif

  // ---------------------------------------------------------------------------
  function automatic void hit(int k, int c);
    ev_kind = k;
    ev_code = c;
    if (c >= 0 && c < NB) h[k][c]++;
`ifndef AXI_NO_COV
    cg_i.sample();
`endif
  endfunction

  function automatic int code3(int ch, int t, int m);
    return ch * 6 + t * 2 + m;
  endfunction

  // copy the state of both request controllers
  function automatic void grab();
    c_mvalid[0] = tb_top.dut.u_aw_ctrl.m_valid;   c_mvalid[1] = tb_top.dut.u_ar_ctrl.m_valid;
    c_mtgt[0]   = tb_top.dut.u_aw_ctrl.m_tgt;     c_mtgt[1]   = tb_top.dut.u_ar_ctrl.m_tgt;
    c_mid[0]    = tb_top.dut.u_aw_ctrl.m_id;      c_mid[1]    = tb_top.dut.u_ar_ctrl.m_id;
    c_mok[0]    = tb_top.dut.u_aw_ctrl.m_ok;      c_mok[1]    = tb_top.dut.u_ar_ctrl.m_ok;
    c_tok[0]    = tb_top.dut.u_aw_ctrl.t_ok;      c_tok[1]    = tb_top.dut.u_ar_ctrl.t_ok;
    c_trdy[0]   = tb_top.dut.u_aw_ctrl.t_ready;   c_trdy[1]   = tb_top.dut.u_ar_ctrl.t_ready;
    c_lock[0]   = tb_top.dut.u_aw_ctrl.lock;      c_lock[1]   = tb_top.dut.u_ar_ctrl.lock;
    c_lockm[0]  = tb_top.dut.u_aw_ctrl.lock_m;    c_lockm[1]  = tb_top.dut.u_ar_ctrl.lock_m;
    c_req[0]    = tb_top.dut.u_aw_ctrl.req;       c_req[1]    = tb_top.dut.u_ar_ctrl.req;
    c_gnt[0]    = tb_top.dut.u_aw_ctrl.gnt;       c_gnt[1]    = tb_top.dut.u_ar_ctrl.gnt;
    c_busy[0]   = tb_top.dut.u_aw_ctrl.id_busy;   c_busy[1]   = tb_top.dut.u_ar_ctrl.id_busy;
    c_own[0]    = tb_top.dut.u_aw_ctrl.id_own;    c_own[1]    = tb_top.dut.u_ar_ctrl.id_own;
    for (int t = 0; t < NT; t++)
      for (int i = 0; i < NID; i++) begin
        c_cnt[0][t][i] = int'(tb_top.dut.u_aw_ctrl.cnt[t][i]);
        c_cnt[1][t][i] = int'(tb_top.dut.u_ar_ctrl.cnt[t][i]);
      end
  endfunction

  // ---------------------------------------------------------------------------
  // request-side conditions (mirror of the qualification in xbar_req_ctrl)
  // ---------------------------------------------------------------------------
  function automatic void req_events();
    for (int ch = 0; ch < 2; ch++) begin
      for (int t = 0; t < NT; t++) begin
        if (!c_lock[ch][t] && (&c_req[ch][t]))
          hit(K_ARB, code3(ch, t, int'(c_gnt[ch][t][1])));
        if (c_lock[ch][t])
          hit(K_LOCK, code3(ch, t, int'(c_lockm[ch][t])));

        for (int m = 0; m < 2; m++) begin
          logic [3:0] i;
          bit         els, tkn, ful, drn, oth;
          i = c_mid[ch][m];

          // master m wants target t but is not granted: why?
          if (c_mvalid[ch][m] && (c_mtgt[ch][m] == 2'(t)) && !c_gnt[ch][t][m]) begin
            els = 1'b0;
            for (int u = 0; u < NT; u++)
              if ((u != t) && c_busy[ch][u][i] && (c_own[ch][u][i] == 1'(m))) els = 1'b1;
            tkn = c_busy[ch][t][i] && (c_own[ch][t][i] != 1'(m));
            ful = (c_cnt[ch][t][i] >= MAXOUT);
            drn = c_busy[ch][t][i] && (c_own[ch][t][i] == 1'(m)) && c_mvalid[ch][1-m] &&
                  (c_mtgt[ch][1-m] == 2'(t)) && (c_mid[ch][1-m] == i);
            if (els) hit(K_BLK_ELSE,  code3(ch, t, m));
            if (tkn) hit(K_BLK_TAKEN, code3(ch, t, m));
            if (ful) hit(K_BLK_FULL,  code3(ch, t, m));
            if (drn) hit(K_BLK_DRAIN, code3(ch, t, m));
            if (ch == 0 && !c_mok[0][m]) hit(K_BLK_WQ, m);
            if (ch == 0 && !c_tok[0][t]) hit(K_BLK_TQ, t);
          end

          // master m accepted by target t in this clock
          if (c_gnt[ch][t][m] && c_trdy[ch][t]) begin
            if (c_busy[ch][t][i]) hit(K_ACC_SAMEID, code3(ch, t, m));
            oth = 1'b0;
            for (int j = 0; j < NID; j++)
              if ((j != int'(i)) && c_busy[ch][t][j] && (c_own[ch][t][j] != 1'(m))) oth = 1'b1;
            if (oth) hit(K_ACC_SHARED, code3(ch, t, m));
          end
        end
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // response-side conditions
  // ---------------------------------------------------------------------------
  function automatic void rsp_events();
    for (int m = 0; m < 2; m++) begin
      if ($countones(tb_top.dut.b_cand[m]) >= 2) hit(K_RSP_COLL, 0 + m);
      if ($countones(tb_top.dut.r_cand[m]) >= 2) hit(K_RSP_COLL, 2 + m);
      if (tb_top.dut.m_bvalid[m] && !tb_top.dut.m_bready[m]) hit(K_RSP_STALL, 0 + m);
      if (tb_top.dut.m_rvalid[m] && !tb_top.dut.m_rready[m]) hit(K_RSP_STALL, 2 + m);
    end
    for (int t = 0; t < 2; t++) begin
      if (tb_top.dut.t_bvalid[t] && !tb_top.dut.b_route[t]) hit(K_RSP_UNK, 0 + t);
      if (tb_top.dut.t_rvalid[t] && !tb_top.dut.r_route[t]) hit(K_RSP_UNK, 2 + t);
    end
    // read interleaving between targets, seen at the master R port
    for (int m = 0; m < 2; m++) begin
      if (tb_top.dut.m_rvalid[m] && tb_top.dut.m_rready[m]) begin
        int s;
        bit ilv;
        s   = int'(tb_top.dut.r_sel[m]);
        ilv = 1'b0;
        for (int u = 0; u < NT; u++)
          if ((u != s) && r_open[m][u]) ilv = 1'b1;
        if (ilv) hit(K_R_ILV, m);
        if (s < NT) r_open[m][s] = !tb_top.dut.m_rlast[m];
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // FIFOs, W path, DECERR responder
  // ---------------------------------------------------------------------------
  function automatic void misc_events();
    if (tb_top.dut.wq_full[0])   hit(K_FIFO_FULL, 0);
    if (tb_top.dut.wq_full[1])   hit(K_FIFO_FULL, 1);
    if (tb_top.dut.tq_full[0])   hit(K_FIFO_FULL, 2);
    if (tb_top.dut.tq_full[1])   hit(K_FIFO_FULL, 3);
    if (tb_top.dut.tq_full[2])   hit(K_FIFO_FULL, 4);
    if (tb_top.dut.err_id_full)  hit(K_FIFO_FULL, 5);
    if (tb_top.dut.err_ar_full)  hit(K_FIFO_FULL, 6);

    for (int m = 0; m < 2; m++) begin
      if (tb_top.dut.m_wvalid[m]) begin
        if (tb_top.dut.wq_empty[m]) hit(K_W_WAIT, 0 + m);
        else if (!tb_top.dut.m_wready[m]) begin
          int t;
          t = int'(tb_top.dut.wq_head[m]);
          if (t < NT)
            if (tb_top.dut.tq_empty[t] || (tb_top.dut.tq_head[t] != 1'(m))) hit(K_W_WAIT, 2 + m);
        end
      end
    end

    if (tb_top.dut.err_wdone >= 4'd2) hit(K_MISC, 0);
  endfunction

  // ---------------------------------------------------------------------------
  always @(posedge aclk) begin
    if (arst_n === 1'b1) begin
      grab();
      req_events();
      rsp_events();
      misc_events();
      busy_q = (|tb_top.dut.u_aw_ctrl.id_busy) || (|tb_top.dut.u_ar_ctrl.id_busy) ||
               (|tb_top.dut.m_awvalid) || (|tb_top.dut.m_arvalid) || (|tb_top.dut.m_wvalid);
    end else begin
      busy_q = 1'b0;
      for (int m = 0; m < 2; m++)
        for (int t = 0; t < NT; t++) r_open[m][t] = 1'b0;
    end
  end

  // reset assertion (the first reset at time 0 is not counted)
  always @(negedge arst_n) begin
    if ($time > 0) begin
      if (busy_q) hit(K_MISC, 1);
      else        hit(K_MISC, 2);
    end
  end

  // ---------------------------------------------------------------------------
  // names for the printed table
  // ---------------------------------------------------------------------------
  function automatic int nbins(int k);
    if (k <= K_ACC_SHARED) return 12;
    case (k)
      K_BLK_WQ:    return 2;
      K_BLK_TQ:    return 3;
      K_R_ILV:     return 2;
      K_FIFO_FULL: return 7;
      K_MISC:      return 3;
      default:     return 4;
    endcase
  endfunction

  function automatic string kind_name(int k);
    case (k)
      K_ARB:        return "arb_winner";
      K_LOCK:       return "grant_lock";
      K_BLK_ELSE:   return "blk_elsewhere";
      K_BLK_TAKEN:  return "blk_taken";
      K_BLK_FULL:   return "blk_full";
      K_BLK_DRAIN:  return "blk_drain";
      K_ACC_SAMEID: return "acc_same_id";
      K_ACC_SHARED: return "acc_shared";
      K_BLK_WQ:     return "blk_wq_full";
      K_BLK_TQ:     return "blk_tq_full";
      K_RSP_COLL:   return "rsp_collide";
      K_RSP_STALL:  return "rsp_stall";
      K_RSP_UNK:    return "rsp_unknown_id";
      K_R_ILV:      return "r_interleave";
      K_FIFO_FULL:  return "fifo_full";
      K_W_WAIT:     return "w_wait";
      default:      return "misc";
    endcase
  endfunction

  function automatic string tname(int t);
    case (t)
      0:       return "s0";
      1:       return "s1";
      default: return "dec";
    endcase
  endfunction

  function automatic string chname(int ch);
    if (ch == 0) return "aw";
    return "ar";
  endfunction

  function automatic string bin_name(int k, int c);
    if (k <= K_ACC_SHARED)
      return $sformatf("%s_%s_m%0d", chname(c / 6), tname((c % 6) / 2), c % 2);
    case (k)
      K_BLK_WQ:    return $sformatf("aw_m%0d", c);
      K_BLK_TQ:    return $sformatf("aw_%s", tname(c));
      K_RSP_COLL,
      K_RSP_STALL: case (c)
                     0: return "b_m0";  1: return "b_m1";  2: return "r_m0";  default: return "r_m1";
                   endcase
      K_RSP_UNK:   case (c)
                     0: return "b_s0";  1: return "b_s1";  2: return "r_s0";  default: return "r_s1";
                   endcase
      K_R_ILV:     return $sformatf("m%0d", c);
      K_FIFO_FULL: case (c)
                     0: return "wq_m0";  1: return "wq_m1";  2: return "tq_s0";  3: return "tq_s1";
                     4: return "tq_dec"; 5: return "dec_aw"; default: return "dec_ar";
                   endcase
      K_W_WAIT:    case (c)
                     0: return "no_aw_m0";  1: return "no_aw_m1";  2: return "order_m0";  default: return "order_m1";
                   endcase
      default:     case (c)
                     0: return "dec_b_backlog";  1: return "rst_busy";  default: return "rst_idle";
                   endcase
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // end of simulation: short summary, full table only with +COV_DETAIL
  // ---------------------------------------------------------------------------
  final begin
    int unsigned hit_n, tot_n;
    string       line, miss;
    bit          detail;
    detail = $test$plusargs("COV_DETAIL");
    hit_n  = 0;
    tot_n  = 0;
    miss   = "";
    if (detail) begin
      $display("");
      $display("==================================================================");
      $display(" WHITE-BOX COVERAGE  (conditions inside the crossbar RTL)");
      $display("   one hit = one clock (or one handshake) in which the condition was true");
      $display("   bin name = channel_target_master, e.g. aw_s1_m0 = AW channel, target S1, master M0");
      $display("   arb_winner: master = the one that WON when both asked in the same clock");
      $display("------------------------------------------------------------------");
    end
    for (int k = 0; k < NK; k++) begin
      line = "";
      for (int c = 0; c < nbins(k); c++) begin
        line = {line, $sformatf(" %s=%0d", bin_name(k, c), h[k][c])};
        tot_n++;
        if (h[k][c] > 0) hit_n++;
        else             miss = {miss, $sformatf(" %s.%s", kind_name(k), bin_name(k, c))};
      end
      if (detail) $display("   %-15s:%s", kind_name(k), line);
    end
    if (detail) begin
      $display("------------------------------------------------------------------");
      $display("   bins hit    : %0d of %0d", hit_n, tot_n);
`ifndef AXI_NO_COV
      $display("   coverage    : %6.2f %%", cg_i.get_inst_coverage());
`endif
      if (miss == "") $display("   bins MISSED : none");
      else            $display("   bins MISSED :%s", miss);
      $display("==================================================================");
    end else begin
`ifndef AXI_NO_COV
      $display(" WHITE-BOX COVERAGE of this test (inside the RTL): %0d of %0d bins hit, %0.2f %%   (+COV_DETAIL for the table)",
               hit_n, tot_n, cg_i.get_inst_coverage());
`else
      $display(" WHITE-BOX COVERAGE of this test (inside the RTL): %0d of %0d bins hit   (+COV_DETAIL for the table)",
               hit_n, tot_n);
`endif
    end
  end

`undef XB_CTM_BINS

endmodule

`endif // AXI_XBAR_WB_COV_SV
