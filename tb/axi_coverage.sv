`ifndef AXI_COVERAGE_SV
`define AXI_COVERAGE_SV

// =============================================================================
// axi_coverage.sv  (included inside axi_tb_pkg)          -- v2, upgraded model
//
//   Functional coverage seen from the PINS (black-box). The conditions INSIDE
//   the RTL (arbitration, ID blocking, FIFO full, ...) are covered by the
//   module tb/axi_xbar_wb_cov.sv (white-box).
//
//   cg_txn   : sampled once per completed MASTER-side transaction
//     old : master, R/W, target, burst, length, size, response, outstanding,
//           master x target x kind, burst x kind
//     new : every ID value (0..15)
//           burst type x legal length  (FIXED 1 / 2-16, INCR 1 / 2-16 / 17-255
//                                       / 256, WRAP 2 / 4 / 8 / 16)
//           aligned / unaligned start address
//           INCR burst that ends exactly on a 4 KB page edge
//           address edges of the map (bottom / top of S0, S1, unmapped)
//           write strobes: all full / partial / beat with no strobe at all
//           response x master x target (only the LEGAL combinations)
//           kind x burst x size cross, master x outstanding cross
//           ID corners: master x (ID 0 / ID F / other) x target x kind
//
//   cg_cycle : sampled every clock from the pins (old, kept as it was)
//     arbitration contention, concurrent traffic, backpressure anywhere
//
//   cg_port  : sampled every clock, once per event that clock  (new)
//     READY low at each SLAVE port, per channel  (AW W AR at S0 / S1)
//     READY low at each MASTER port, per channel (B R at M0 / M1)
//     crossbar not ready to a master (AW W AR at M0 / M1)
//     a stall of 8 or more clocks in a row, per channel
//     channel overlap: AW + AR of one master in the same clock,
//                      W + R at one slave in the same clock
//
//   Every bin also has a plain hit COUNTER. At the end of the test the full
//   table is printed (bin=hits) with the list of bins never hit (holes).
//   The counters work on every simulator, even with +define+AXI_NO_COV.
//
//   Names used by axi_cov_closure.sv are unchanged:
//     txn_pct() cyc_pct() scan_bins() pl_hit pl_tot pl_miss
//     h_outst h_awc h_arc h_conc h_bp
//
//   Vivado xsim note: names are built with if/case in small functions,
//   never with a ternary that mixes a string literal and $sformatf.
// =============================================================================

class axi_coverage;

  mailbox #(axi_txn)  mbx;
  axi_ref_model       rm;
  virtual axi_if      m_vif[NUM_M];
  virtual axi_if      s_vif[NUM_S];

  // ---- txn sample variables (old)
  int  cv_master, cv_tgt, cv_burst, cv_len, cv_size, cv_resp, cv_outst;
  bit  cv_kind;
  // ---- txn sample variables (new)
  int  cv_id, cv_bl, cv_align, cv_4k, cv_edge, cv_strb, cv_rr;
  int  cv_idc;                     // ID corner: 0 = ID 0, 1 = ID F (max), 2 = any other ID

  // ---- cycle sample variables (old)
  bit  cv_awc, cv_arc;
  int  cv_awc_tgt, cv_arc_tgt;
  bit  cv_cross;
  bit  cv_bp_aw, cv_bp_w, cv_bp_ar, cv_bp_b, cv_bp_r;

  // ---- port event variables (new)
  int  pv_kind, pv_code;

  // ---- bin hit counters (old)
  int unsigned h_master[2];
  int unsigned h_kind[2];
  int unsigned h_tgt[3];
  int unsigned h_burst[3];
  int unsigned h_len[5];
  int unsigned h_size[4];
  int unsigned h_resp[3];
  int unsigned h_outst[4];
  int unsigned h_route[2][3][2];
  int unsigned h_xburst[3][2];
  int unsigned h_awc[3];
  int unsigned h_arc[3];
  int unsigned h_conc;
  int unsigned h_bp[5];
  int unsigned n_txn_sampled;

  // ---- bin hit counters (new)
  int unsigned h_id[16];
  int unsigned h_bl[10];
  int unsigned h_align[2];
  int unsigned h_4k[2];
  int unsigned h_edge[6];
  int unsigned h_strb[3];
  int unsigned h_rr[10];
  int unsigned h_kbs[2][3][4];       // [kind][burst][size]
  int unsigned h_om[2][4];           // [master][outstanding bin]
  int unsigned h_idc[2][3][3][2];    // [master][ID corner][target][kind]
  int unsigned h_port[5][6];         // [port event kind][code]

  // ---- stall streak counters (clocks in a row with VALID=1 READY=0)
  int unsigned run_s[NUM_S][3];      // slave port : AW W AR
  int unsigned run_m[NUM_M][2];      // master port: B R

  // ---- scratch used while scanning the bins
  string       pl_cp, pl_line, pl_miss;
  int unsigned pl_hit, pl_tot;

`ifndef AXI_NO_COV
  covergroup cg_txn;
    option.per_instance = 1;
    // ---------------- old coverpoints
    cp_master: coverpoint cv_master { bins m0 = {0}; bins m1 = {1}; }
    cp_kind  : coverpoint cv_kind   { bins write = {0}; bins read = {1}; }
    cp_tgt   : coverpoint cv_tgt    { bins s0 = {0}; bins s1 = {1}; bins unmapped = {2}; }
    cp_burst : coverpoint cv_burst  { bins fixed = {0}; bins incr = {1}; bins wrap = {2}; }
    cp_len   : coverpoint cv_len    { bins single = {0}; bins b2_8 = {[1:7]}; bins b9_16 = {[8:15]};
                                      bins b17_255 = {[16:254]}; bins b256 = {255}; }
    cp_size  : coverpoint cv_size   { bins sz1 = {0}; bins sz2 = {1}; bins sz4 = {2}; bins sz8 = {3}; }
    cp_resp  : coverpoint cv_resp   { bins okay = {0}; bins slverr = {2}; bins decerr = {3}; }
    cp_outst : coverpoint cv_outst  { bins none = {0}; bins one = {1}; bins two_three = {[2:3]};
                                      bins four_plus = {[4:$]}; }
    x_route  : cross cp_master, cp_tgt, cp_kind;
    x_burst  : cross cp_burst, cp_kind;
    // ---------------- new coverpoints
    cp_id        : coverpoint cv_id { bins id[] = {[0:15]}; }
    cp_id_corner : coverpoint cv_idc { bins id_0 = {0}; bins id_f = {1}; bins id_other = {2}; }
    cp_burst_len : coverpoint cv_bl iff (cv_bl >= 0) {
                     bins fixed_1     = {0};  bins fixed_2_16  = {1};
                     bins incr_1      = {2};  bins incr_2_16   = {3};
                     bins incr_17_255 = {4};  bins incr_256    = {5};
                     bins wrap_2      = {6};  bins wrap_4      = {7};
                     bins wrap_8      = {8};  bins wrap_16     = {9}; }
    cp_align     : coverpoint cv_align { bins aligned = {0}; bins unaligned = {1}; }
    cp_4k_edge   : coverpoint cv_4k iff (cv_4k >= 0) { bins ends_on_4k_edge = {0}; bins inside_page = {1}; }
    cp_addr_edge : coverpoint cv_edge iff (cv_edge >= 0) {
                     bins s0_bottom       = {0};  bins s0_top       = {1};
                     bins s1_bottom       = {2};  bins s1_top       = {3};
                     bins unmapped_bottom = {4};  bins unmapped_top = {5}; }
    cp_wstrb     : coverpoint cv_strb iff (cv_strb >= 0) {
                     bins all_full = {0}; bins partial = {1}; bins has_empty_beat = {2}; }
    cp_resp_route: coverpoint cv_rr iff (cv_rr >= 0) {
                     bins m0_s0_okay = {0}; bins m0_s0_slverr = {1};
                     bins m0_s1_okay = {2}; bins m0_s1_slverr = {3}; bins m0_unmapped_decerr = {4};
                     bins m1_s0_okay = {5}; bins m1_s0_slverr = {6};
                     bins m1_s1_okay = {7}; bins m1_s1_slverr = {8}; bins m1_unmapped_decerr = {9}; }
    x_kind_burst_size : cross cp_kind, cp_burst, cp_size;
    x_master_outst    : cross cp_master, cp_outst;
    // every master uses the smallest and the largest ID to every target, read and write
    x_id_corner       : cross cp_master, cp_id_corner, cp_tgt, cp_kind;
  endgroup

  covergroup cg_cycle;
    option.per_instance = 1;
    cp_aw_contend: coverpoint cv_awc_tgt iff (cv_awc) { bins s0 = {0}; bins s1 = {1}; bins unmapped = {2}; }
    cp_ar_contend: coverpoint cv_arc_tgt iff (cv_arc) { bins s0 = {0}; bins s1 = {1}; bins unmapped = {2}; }
    cp_concurrent: coverpoint cv_cross { bins yes = {1}; }
    cp_bp_aw     : coverpoint cv_bp_aw { bins yes = {1}; }
    cp_bp_w      : coverpoint cv_bp_w  { bins yes = {1}; }
    cp_bp_ar     : coverpoint cv_bp_ar { bins yes = {1}; }
    cp_bp_b      : coverpoint cv_bp_b  { bins yes = {1}; }
    cp_bp_r      : coverpoint cv_bp_r  { bins yes = {1}; }
  endgroup

  // one sample() call per event; only the coverpoint whose iff is true counts
  covergroup cg_port;
    option.per_instance = 1;
    cp_bp_at_slave   : coverpoint pv_code iff (pv_kind == 0) {
                         bins aw_s0 = {0}; bins aw_s1 = {1}; bins w_s0 = {2};
                         bins w_s1  = {3}; bins ar_s0 = {4}; bins ar_s1 = {5}; }
    cp_bp_at_master  : coverpoint pv_code iff (pv_kind == 1) {
                         bins b_m0 = {0}; bins b_m1 = {1}; bins r_m0 = {2}; bins r_m1 = {3}; }
    cp_xbar_not_ready: coverpoint pv_code iff (pv_kind == 2) {
                         bins aw_m0 = {0}; bins aw_m1 = {1}; bins w_m0 = {2};
                         bins w_m1  = {3}; bins ar_m0 = {4}; bins ar_m1 = {5}; }
    cp_long_stall    : coverpoint pv_code iff (pv_kind == 3) {
                         bins aw = {0}; bins w = {1}; bins ar = {2}; bins b = {3}; bins r = {4}; }
    cp_chan_overlap  : coverpoint pv_code iff (pv_kind == 4) {
                         bins aw_ar_m0 = {0}; bins aw_ar_m1 = {1}; bins w_r_s0 = {2}; bins w_r_s1 = {3}; }
  endgroup
`endif

  function new(axi_ref_model rm);
    this.rm  = rm;
    mbx      = new();
`ifndef AXI_NO_COV
    cg_txn   = new();
    cg_cycle = new();
    cg_port  = new();
`endif
  endfunction

  task run();
    fork
      txn_loop();
      cycle_loop();
    join_none
  endtask

  // ---------------------------------------------------------------------------
  // bin index helpers (same ranges as the coverpoints)
  // ---------------------------------------------------------------------------
  function int len_bin(int l);
    if (l == 0)   return 0;
    if (l <= 7)   return 1;
    if (l <= 15)  return 2;
    if (l <= 254) return 3;
    return 4;
  endfunction

  function int resp_bin(int r);
    if (r == 0) return 0;
    if (r == 2) return 1;
    if (r == 3) return 2;
    return -1;
  endfunction

  function int outst_bin(int o);
    if (o == 0) return 0;
    if (o == 1) return 1;
    if (o <= 3) return 2;
    return 3;
  endfunction

  // burst type x legal length; -1 = illegal combination (never expected)
  function int bl_bin(int b, int l);
    if (b == 0) begin
      if (l == 0) return 0;
      if (l <= 15) return 1;
      return -1;
    end
    if (b == 1) begin
      if (l == 0)   return 2;
      if (l <= 15)  return 3;
      if (l <= 254) return 4;
      return 5;
    end
    if (b == 2) begin
      case (l)
        1:       return 6;
        3:       return 7;
        7:       return 8;
        15:      return 9;
        default: return -1;
      endcase
    end
    return -1;
  endfunction

  // INCR only: 0 = last byte of the burst is the last byte of a 4 KB page
  function int page_bin(axi_txn t);
    bit [AXI_AW-1:0] la, nb, nxt;
    if (t.burst != BURST_INCR) return -1;
    nb  = 32'd1 << t.size;
    la  = axi_beat_addr(t.addr, t.size, t.len, t.burst, t.len);
    nxt = (la / nb) * nb + nb;
    if (nxt[11:0] == 12'h000) return 0;
    return 1;
  endfunction

  // first / last 4 KB of every address region (address decoder edges)
  function int edge_bin(bit [AXI_AW-1:0] a);
    if (a >= S0_BASE && a < S0_BASE + 32'h1000)         return 0;
    if (a <= S0_LIMIT && a > S0_LIMIT - 32'h1000)       return 1;
    if (a >= S1_BASE && a < S1_BASE + 32'h1000)         return 2;
    if (a <= S1_LIMIT && a > S1_LIMIT - 32'h1000)       return 3;
    if (a > S1_LIMIT && a <= S1_LIMIT + 32'h1000)       return 4;
    if (a >= 32'hFFFF_F000)                             return 5;
    return -1;
  endfunction

  // ID corner: 0 = smallest ID, 1 = largest ID, 2 = any other
  function int idc_bin(int id);
    if (id == 0)                return 0;
    if (id == (1 << AXI_IDW) - 1) return 1;
    return 2;
  endfunction

  function string idc_nm(int i);
    case (i)
      0:       return "id0";
      1:       return "idF";
      default: return "idX";
    endcase
  endfunction

  // writes only: 0 all strobes full, 1 some partial, 2 a beat with WSTRB = 0
  function int strb_bin(axi_txn t);
    bit              full_all, any_empty;
    bit [AXI_SW-1:0] lm;
    if (t.kind != AXI_WRITE)           return -1;
    if (t.strb.size() != t.beats())    return -1;
    full_all  = 1'b1;
    any_empty = 1'b0;
    for (int i = 0; i < t.beats(); i++) begin
      lm = axi_lane_mask(axi_beat_addr(t.addr, t.size, t.len, t.burst, i), t.size);
      if (t.strb[i] == '0) any_empty = 1'b1;
      if (t.strb[i] != lm) full_all  = 1'b0;
    end
    if (any_empty) return 2;
    if (full_all)  return 0;
    return 1;
  endfunction

  // legal response x target, per master; -1 = not a legal combination
  function int rr_bin(int m, int tg, int r);
    int b;
    b = -1;
    if (tg == 0 && r == 0) b = 0;
    if (tg == 0 && r == 2) b = 1;
    if (tg == 1 && r == 0) b = 2;
    if (tg == 1 && r == 2) b = 3;
    if (tg == 2 && r == 3) b = 4;
    if (b < 0 || m < 0 || m > 1) return -1;
    return m * 5 + b;
  endfunction

  // ---------------------------------------------------------------------------
  task txn_loop();
    axi_txn t;
    int     lb, rb, ob;
    forever begin
      mbx.get(t);
      cv_master = t.master;
      cv_kind   = (t.kind == AXI_READ);
      cv_tgt    = rm.target_of(t.addr);
      cv_burst  = t.burst;
      cv_len    = t.len;
      cv_size   = t.size;
      cv_resp   = (t.resp.size() > 0) ? t.resp[0] : 0;
      cv_outst  = t.outstanding_at_issue;
      cv_id     = t.id;
      cv_idc    = idc_bin(t.id);
      cv_bl     = bl_bin(cv_burst, cv_len);
      cv_align  = ((t.addr & ((32'd1 << t.size) - 32'd1)) != 0);
      cv_4k     = page_bin(t);
      cv_edge   = edge_bin(t.addr);
      cv_strb   = strb_bin(t);
      cv_rr     = rr_bin(cv_master, cv_tgt, cv_resp);
`ifndef AXI_NO_COV
      cg_txn.sample();
`endif
      // ---- hit counters
      n_txn_sampled++;
      lb = len_bin(cv_len);
      rb = resp_bin(cv_resp);
      ob = outst_bin(cv_outst);
      if (cv_master >= 0 && cv_master < 2) h_master[cv_master]++;
      h_kind[cv_kind]++;
      if (cv_tgt >= 0 && cv_tgt < 3)       h_tgt[cv_tgt]++;
      if (cv_burst >= 0 && cv_burst < 3)   h_burst[cv_burst]++;
      h_len[lb]++;
      if (cv_size >= 0 && cv_size < 4)     h_size[cv_size]++;
      if (rb >= 0)                         h_resp[rb]++;
      h_outst[ob]++;
      if (cv_master >= 0 && cv_master < 2 && cv_tgt >= 0 && cv_tgt < 3)
        h_route[cv_master][cv_tgt][cv_kind]++;
      if (cv_burst >= 0 && cv_burst < 3)   h_xburst[cv_burst][cv_kind]++;
      // new
      if (cv_id >= 0 && cv_id < 16)        h_id[cv_id]++;
      if (cv_bl >= 0)                      h_bl[cv_bl]++;
      h_align[cv_align]++;
      if (cv_4k >= 0)                      h_4k[cv_4k]++;
      if (cv_edge >= 0)                    h_edge[cv_edge]++;
      if (cv_strb >= 0)                    h_strb[cv_strb]++;
      if (cv_rr >= 0)                      h_rr[cv_rr]++;
      if (cv_burst >= 0 && cv_burst < 3 && cv_size >= 0 && cv_size < 4)
        h_kbs[cv_kind][cv_burst][cv_size]++;
      if (cv_master >= 0 && cv_master < 2) h_om[cv_master][ob]++;
      if (cv_master >= 0 && cv_master < 2 && cv_tgt >= 0 && cv_tgt < 3)
        h_idc[cv_master][cv_idc][cv_tgt][cv_kind]++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // port events (one sample per event)
  // ---------------------------------------------------------------------------
  function void pev(int k, int c);
    pv_kind = k;
    pv_code = c;
    h_port[k][c]++;
`ifndef AXI_NO_COV
    cg_port.sample();
`endif
  endfunction

  // stall streak: returns the new length, fires the long-stall event at 8
  function int unsigned streak(int unsigned r, bit stall, int code);
    if (!stall) return 0;
    if (r + 1 == 8) pev(3, code);
    return r + 1;
  endfunction

  task cycle_loop();
    int t0, t1;
    forever begin
      @(m_vif[0].cb);
      if (m_vif[0].arst_n !== 1'b1) begin
        foreach (run_s[s, c]) run_s[s][c] = 0;
        foreach (run_m[m, c]) run_m[m][c] = 0;
        continue;
      end

      // ---------------- old cycle bins
      t0 = rm.target_of(m_vif[0].cb.awaddr);
      t1 = rm.target_of(m_vif[1].cb.awaddr);
      cv_awc     = m_vif[0].cb.awvalid && m_vif[1].cb.awvalid && (t0 == t1);
      cv_awc_tgt = t0;
      cv_cross   = m_vif[0].cb.awvalid && m_vif[1].cb.awvalid && (t0 != t1) &&
                   (t0 < NUM_S) && (t1 < NUM_S);

      t0 = rm.target_of(m_vif[0].cb.araddr);
      t1 = rm.target_of(m_vif[1].cb.araddr);
      cv_arc     = m_vif[0].cb.arvalid && m_vif[1].cb.arvalid && (t0 == t1);
      cv_arc_tgt = t0;
      cv_cross   = cv_cross || (m_vif[0].cb.arvalid && m_vif[1].cb.arvalid && (t0 != t1) &&
                                (t0 < NUM_S) && (t1 < NUM_S));

      cv_bp_aw = 0; cv_bp_w = 0; cv_bp_ar = 0; cv_bp_b = 0; cv_bp_r = 0;
      for (int s = 0; s < NUM_S; s++) begin
        cv_bp_aw |= s_vif[s].cb.awvalid && !s_vif[s].cb.awready;
        cv_bp_w  |= s_vif[s].cb.wvalid  && !s_vif[s].cb.wready;
        cv_bp_ar |= s_vif[s].cb.arvalid && !s_vif[s].cb.arready;
      end
      for (int m = 0; m < NUM_M; m++) begin
        cv_bp_b  |= m_vif[m].cb.bvalid && !m_vif[m].cb.bready;
        cv_bp_r  |= m_vif[m].cb.rvalid && !m_vif[m].cb.rready;
      end
`ifndef AXI_NO_COV
      cg_cycle.sample();
`endif
      if (cv_awc && cv_awc_tgt >= 0 && cv_awc_tgt < 3) h_awc[cv_awc_tgt]++;
      if (cv_arc && cv_arc_tgt >= 0 && cv_arc_tgt < 3) h_arc[cv_arc_tgt]++;
      if (cv_cross) h_conc++;
      if (cv_bp_aw) h_bp[0]++;
      if (cv_bp_w)  h_bp[1]++;
      if (cv_bp_ar) h_bp[2]++;
      if (cv_bp_b)  h_bp[3]++;
      if (cv_bp_r)  h_bp[4]++;

      // ---------------- new per-port events
      for (int s = 0; s < NUM_S; s++) begin
        if (s_vif[s].cb.awvalid && !s_vif[s].cb.awready) pev(0, 0 + s);
        if (s_vif[s].cb.wvalid  && !s_vif[s].cb.wready)  pev(0, 2 + s);
        if (s_vif[s].cb.arvalid && !s_vif[s].cb.arready) pev(0, 4 + s);
        if (s_vif[s].cb.wvalid  && s_vif[s].cb.rvalid)   pev(4, 2 + s);
        run_s[s][0] = streak(run_s[s][0], s_vif[s].cb.awvalid && !s_vif[s].cb.awready, 0);
        run_s[s][1] = streak(run_s[s][1], s_vif[s].cb.wvalid  && !s_vif[s].cb.wready,  1);
        run_s[s][2] = streak(run_s[s][2], s_vif[s].cb.arvalid && !s_vif[s].cb.arready, 2);
      end
      for (int m = 0; m < NUM_M; m++) begin
        if (m_vif[m].cb.bvalid  && !m_vif[m].cb.bready)  pev(1, 0 + m);
        if (m_vif[m].cb.rvalid  && !m_vif[m].cb.rready)  pev(1, 2 + m);
        if (m_vif[m].cb.awvalid && !m_vif[m].cb.awready) pev(2, 0 + m);
        if (m_vif[m].cb.wvalid  && !m_vif[m].cb.wready)  pev(2, 2 + m);
        if (m_vif[m].cb.arvalid && !m_vif[m].cb.arready) pev(2, 4 + m);
        if (m_vif[m].cb.awvalid && m_vif[m].cb.arvalid)  pev(4, 0 + m);
        run_m[m][0] = streak(run_m[m][0], m_vif[m].cb.bvalid && !m_vif[m].cb.bready, 3);
        run_m[m][1] = streak(run_m[m][1], m_vif[m].cb.rvalid && !m_vif[m].cb.rready, 4);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Percentages (-1 when covergroups are compiled out)
  // ---------------------------------------------------------------------------
  function real txn_pct();
`ifndef AXI_NO_COV
    return cg_txn.get_inst_coverage();
`else
    return -1.0;
`endif
  endfunction

  function real cyc_pct();
`ifndef AXI_NO_COV
    return cg_cycle.get_inst_coverage();
`else
    return -1.0;
`endif
  endfunction

  function real port_pct();
`ifndef AXI_NO_COV
    return cg_port.get_inst_coverage();
`else
    return -1.0;
`endif
  endfunction

  // ---------------------------------------------------------------------------
  // Bin names
  // ---------------------------------------------------------------------------
  function string tgt_nm(int i);
    case (i)
      0:       return "s0";
      1:       return "s1";
      default: return "unmapped";
    endcase
  endfunction

  function string kind_nm(int i);
    if (i == 0) return "wr";
    return "rd";
  endfunction

  function string burst_nm(int i);
    case (i)
      0:       return "fixed";
      1:       return "incr";
      default: return "wrap";
    endcase
  endfunction

  function string len_nm(int i);
    case (i)
      0:       return "single";
      1:       return "2-8";
      2:       return "9-16";
      3:       return "17-255";
      default: return "256";
    endcase
  endfunction

  function string size_nm(int i);
    case (i)
      0:       return "1B";
      1:       return "2B";
      2:       return "4B";
      default: return "8B";
    endcase
  endfunction

  function string resp_nm(int i);
    case (i)
      0:       return "okay";
      1:       return "slverr";
      default: return "decerr";
    endcase
  endfunction

  function string outst_nm(int i);
    case (i)
      0:       return "0";
      1:       return "1";
      2:       return "2-3";
      default: return "4+";
    endcase
  endfunction

  function string bp_nm(int i);
    case (i)
      0:       return "aw";
      1:       return "w";
      2:       return "ar";
      3:       return "b";
      default: return "r";
    endcase
  endfunction

  function string bl_nm(int i);
    case (i)
      0:       return "fixed_1";
      1:       return "fixed_2-16";
      2:       return "incr_1";
      3:       return "incr_2-16";
      4:       return "incr_17-255";
      5:       return "incr_256";
      6:       return "wrap_2";
      7:       return "wrap_4";
      8:       return "wrap_8";
      default: return "wrap_16";
    endcase
  endfunction

  function string edge_nm(int i);
    case (i)
      0:       return "s0_bottom";
      1:       return "s0_top";
      2:       return "s1_bottom";
      3:       return "s1_top";
      4:       return "unmapped_bottom";
      default: return "unmapped_top";
    endcase
  endfunction

  function string strb_nm(int i);
    case (i)
      0:       return "all_full";
      1:       return "partial";
      default: return "has_empty_beat";
    endcase
  endfunction

  function string rr_nm(int i);
    string m, r;
    if (i < 5) m = "m0";
    else       m = "m1";
    case (i % 5)
      0:       r = "s0_okay";
      1:       r = "s0_slverr";
      2:       r = "s1_okay";
      3:       r = "s1_slverr";
      default: r = "unmapped_decerr";
    endcase
    return {m, ".", r};
  endfunction

  function int port_nbins(int k);
    case (k)
      0:       return 6;
      1:       return 4;
      2:       return 6;
      3:       return 5;
      default: return 4;
    endcase
  endfunction

  function string port_grp(int k);
    case (k)
      0:       return "bp_at_slave";
      1:       return "bp_at_master";
      2:       return "xbar_not_rdy";
      3:       return "long_stall_8+";
      default: return "chan_overlap";
    endcase
  endfunction

  function string port_nm(int k, int c);
    case (k)
      0: case (c)
           0: return "aw_s0";  1: return "aw_s1";  2: return "w_s0";
           3: return "w_s1";   4: return "ar_s0";  default: return "ar_s1";
         endcase
      1: case (c)
           0: return "b_m0";   1: return "b_m1";   2: return "r_m0";  default: return "r_m1";
         endcase
      2: case (c)
           0: return "aw_m0";  1: return "aw_m1";  2: return "w_m0";
           3: return "w_m1";   4: return "ar_m0";  default: return "ar_m1";
         endcase
      3: case (c)
           0: return "aw";  1: return "w";  2: return "ar";  3: return "b";  default: return "r";
         endcase
      default: case (c)
           0: return "aw+ar_m0";  1: return "aw+ar_m1";  2: return "w+r_s0";  default: return "w+r_s1";
         endcase
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Bin scan: fills pl_hit / pl_tot / pl_miss, prints one line per
  // coverpoint when show = 1
  // ---------------------------------------------------------------------------
  function void start_cp(string cp);
    pl_cp   = cp;
    pl_line = "";
  endfunction

  function void add_bin(string bn, int unsigned n);
    pl_line = {pl_line, $sformatf(" %s=%0d", bn, n)};
    pl_tot++;
    if (n > 0) pl_hit++;
    else       pl_miss = {pl_miss, $sformatf(" %s.%s", pl_cp, bn)};
  endfunction

  function void end_cp(bit show);
    if (show) $display("   %-14s:%s", pl_cp, pl_line);
  endfunction

  function void scan_bins(bit show);
    pl_hit  = 0;
    pl_tot  = 0;
    pl_miss = "";
    if (show) $display("  -- per transaction --");
    start_cp("cp_master");
    for (int i = 0; i < 2; i++) add_bin($sformatf("m%0d", i), h_master[i]);
    end_cp(show);
    start_cp("cp_kind");
    for (int i = 0; i < 2; i++) add_bin(kind_nm(i), h_kind[i]);
    end_cp(show);
    start_cp("cp_tgt");
    for (int i = 0; i < 3; i++) add_bin(tgt_nm(i), h_tgt[i]);
    end_cp(show);
    start_cp("cp_burst");
    for (int i = 0; i < 3; i++) add_bin(burst_nm(i), h_burst[i]);
    end_cp(show);
    start_cp("cp_len");
    for (int i = 0; i < 5; i++) add_bin(len_nm(i), h_len[i]);
    end_cp(show);
    start_cp("cp_size");
    for (int i = 0; i < 4; i++) add_bin(size_nm(i), h_size[i]);
    end_cp(show);
    start_cp("cp_resp");
    for (int i = 0; i < 3; i++) add_bin(resp_nm(i), h_resp[i]);
    end_cp(show);
    start_cp("cp_outst");
    for (int i = 0; i < 4; i++) add_bin(outst_nm(i), h_outst[i]);
    end_cp(show);
    start_cp("cp_id");
    for (int i = 0; i < 16; i++) add_bin($sformatf("%0h", i), h_id[i]);
    end_cp(show);
    start_cp("burst_len");
    for (int i = 0; i < 10; i++) add_bin(bl_nm(i), h_bl[i]);
    end_cp(show);
    start_cp("align");
    add_bin("aligned", h_align[0]);
    add_bin("unaligned", h_align[1]);
    end_cp(show);
    start_cp("incr_4k_edge");
    add_bin("ends_on_edge", h_4k[0]);
    add_bin("inside_page", h_4k[1]);
    end_cp(show);
    start_cp("addr_edge");
    for (int i = 0; i < 6; i++) add_bin(edge_nm(i), h_edge[i]);
    end_cp(show);
    start_cp("wstrb");
    for (int i = 0; i < 3; i++) add_bin(strb_nm(i), h_strb[i]);
    end_cp(show);
    start_cp("resp_route");
    for (int i = 0; i < 10; i++) add_bin(rr_nm(i), h_rr[i]);
    end_cp(show);
    start_cp("x_route");
    for (int m = 0; m < 2; m++)
      for (int t = 0; t < 3; t++)
        for (int k = 0; k < 2; k++)
          add_bin($sformatf("m%0d.%s.%s", m, tgt_nm(t), kind_nm(k)), h_route[m][t][k]);
    end_cp(show);
    start_cp("x_burst");
    for (int b = 0; b < 3; b++)
      for (int k = 0; k < 2; k++)
        add_bin($sformatf("%s.%s", burst_nm(b), kind_nm(k)), h_xburst[b][k]);
    end_cp(show);
    start_cp("x_kind_brst_sz");
    for (int k = 0; k < 2; k++)
      for (int b = 0; b < 3; b++)
        for (int z = 0; z < 4; z++)
          add_bin($sformatf("%s.%s.%s", kind_nm(k), burst_nm(b), size_nm(z)), h_kbs[k][b][z]);
    end_cp(show);
    start_cp("x_master_outst");
    for (int m = 0; m < 2; m++)
      for (int o = 0; o < 4; o++)
        add_bin($sformatf("m%0d.%s", m, outst_nm(o)), h_om[m][o]);
    end_cp(show);
    start_cp("x_id_corner");
    for (int m = 0; m < 2; m++)
      for (int c = 0; c < 3; c++)
        for (int t = 0; t < 3; t++)
          for (int k = 0; k < 2; k++)
            add_bin($sformatf("m%0d.%s.%s.%s", m, idc_nm(c), tgt_nm(t), kind_nm(k)), h_idc[m][c][t][k]);
    end_cp(show);
    if (show) $display("  -- per clock --");
    start_cp("aw_contend");
    for (int i = 0; i < 3; i++) add_bin(tgt_nm(i), h_awc[i]);
    end_cp(show);
    start_cp("ar_contend");
    for (int i = 0; i < 3; i++) add_bin(tgt_nm(i), h_arc[i]);
    end_cp(show);
    start_cp("concurrent");
    add_bin("yes", h_conc);
    end_cp(show);
    start_cp("backpressure");
    for (int i = 0; i < 5; i++) add_bin(bp_nm(i), h_bp[i]);
    end_cp(show);
    for (int k = 0; k < 5; k++) begin
      start_cp(port_grp(k));
      for (int c = 0; c < port_nbins(k); c++) add_bin(port_nm(k, c), h_port[k][c]);
      end_cp(show);
    end
  endfunction

  // Full table: every bin with its hit count + the list of holes
  function void print_bins();
    $display(" COVERAGE BINS  (name=number of hits; a bin with 0 hits is a hole)");
    $display("   transaction bins: one hit per finished master-side transaction (%0d sampled)", n_txn_sampled);
    $display("   clock bins      : one hit per clock in which the situation was seen");
    scan_bins(1'b1);
    $display("   bins hit          : %0d of %0d", pl_hit, pl_tot);
    if (pl_miss == "") $display("   bins MISSED       : none");
    else               $display("   bins MISSED       :%s", pl_miss);
  endfunction

  function void report();
    $display(" FUNCTIONAL COVERAGE (black-box, from the pins)");
`ifndef AXI_NO_COV
    $display("   transaction coverage      : %6.2f %%", cg_txn.get_inst_coverage());
    $display("   cycle (arb/bp) coverage   : %6.2f %%", cg_cycle.get_inst_coverage());
    $display("   per-port / stall coverage : %6.2f %%", cg_port.get_inst_coverage());
`else
    $display("   (covergroups disabled with +define+AXI_NO_COV, bin counters below still valid)");
`endif
    $display("   (RTL-internal conditions are printed under WHITE-BOX COVERAGE after the test banner)");
    $display("------------------------------------------------------------------");
    print_bins();
    $display("------------------------------------------------------------------");
  endfunction

endclass
`endif // AXI_COVERAGE_SV
