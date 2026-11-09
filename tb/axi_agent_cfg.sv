`ifndef AXI_AGENT_CFG_SV
`define AXI_AGENT_CFG_SV

// =============================================================================
// axi_agent_cfg.sv  (included inside axi_tb_pkg)
//   Configuration object for one agent (master or slave). Tests change these
//   knobs in configure() to create backpressure, latency, errors, etc.
//   All "_pct" knobs are percentages 0..100 (per clock cycle).
//   The drivers read the knobs live, so a test may also change them while
//   the simulation runs (best done when the agents are idle).
//   copy_from() copies every knob (used to save / restore a configuration).
// =============================================================================

class axi_agent_cfg;

  string        name;
  bit           is_master;
  int           port_idx;

  // ---------------- master driver knobs
  int unsigned  max_outstanding  = 4;   // transactions in flight per master
  int unsigned  bready_low_pct   = 0;   // % of cycles BREADY is held low
  int unsigned  rready_low_pct   = 0;   // % of cycles RREADY is held low

  // ---------------- slave (responder) knobs
  int unsigned  awready_low_pct  = 0;   // % of cycles AWREADY is low
  int unsigned  wready_low_pct   = 0;   // % of cycles WREADY  is low
  int unsigned  arready_low_pct  = 0;   // % of cycles ARREADY is low
  int unsigned  b_latency_max    = 0;   // extra clocks before BVALID (random, up to max)
  int unsigned  r_latency_max    = 0;   // extra clocks before the first R beat
  int unsigned  b_latency_min    = 0;   // lower bound of the B latency
  int unsigned  r_latency_min    = 0;   // lower bound of the R latency
  int unsigned  r_gap_pct        = 0;   // % chance of an idle cycle between R beats (max 90)
  int unsigned  slave_depth      = 8;   // AW (or AR) the slave may hold unanswered

  // Error injection: requests whose start address is in [err_lo, err_hi]
  // are answered with SLVERR (and the write is not stored).
  bit                 err_en = 1'b0;
  bit [AXI_AW-1:0]    err_lo = '0;
  bit [AXI_AW-1:0]    err_hi = '0;

  function new(string name, bit is_master, int port_idx);
    this.name      = name;
    this.is_master = is_master;
    this.port_idx  = port_idx;
  endfunction

  // Shortcut used by tests: turn on random backpressure everywhere
  function void set_backpressure(int unsigned pct);
    bready_low_pct  = pct;  rready_low_pct  = pct;
    awready_low_pct = pct;  wready_low_pct  = pct;  arready_low_pct = pct;
    r_gap_pct       = (pct > 90) ? 90 : pct;
  endfunction

  function bit is_err_addr(bit [AXI_AW-1:0] a);
    return err_en && (a >= err_lo) && (a <= err_hi);
  endfunction

  // Copy every knob of "o" into this object (name / port are not copied)
  function void copy_from(axi_agent_cfg o);
    max_outstanding = o.max_outstanding;
    bready_low_pct  = o.bready_low_pct;
    rready_low_pct  = o.rready_low_pct;
    awready_low_pct = o.awready_low_pct;
    wready_low_pct  = o.wready_low_pct;
    arready_low_pct = o.arready_low_pct;
    b_latency_max   = o.b_latency_max;
    r_latency_max   = o.r_latency_max;
    b_latency_min   = o.b_latency_min;
    r_latency_min   = o.r_latency_min;
    r_gap_pct       = o.r_gap_pct;
    slave_depth     = o.slave_depth;
    err_en          = o.err_en;
    err_lo          = o.err_lo;
    err_hi          = o.err_hi;
  endfunction

endclass
`endif // AXI_AGENT_CFG_SV
