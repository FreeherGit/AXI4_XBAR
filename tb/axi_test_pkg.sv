`ifndef AXI_TEST_PKG_SV
`define AXI_TEST_PKG_SV
`timescale 1ns / 1ps

// =============================================================================
// axi_test_pkg.sv
//   Base test + all tests + axi_create_test(), which creates the test named
//   on the command line with +TESTNAME=<name>.
//
//   Adding a test: one more line in axi_create_test() below
//   (see "Adding a test" in README.md).
// =============================================================================

package axi_test_pkg;

  import axi_params_pkg::*;
  import axi_tb_pkg::*;

  `include "axi_base_test.sv"
  `include "axi_test_list.sv"

  function automatic axi_base_test axi_create_test(string name);
    case (name)
      "axi_smoke_test":              begin axi_smoke_test              t = new(); return t; end
      "axi_smoke_dense_test":        begin axi_smoke_dense_test        t = new(); return t; end
      "axi_smoke_walk_test":         begin axi_smoke_walk_test         t = new(); return t; end
      "axi_smoke_sweep_test":        begin axi_smoke_sweep_test        t = new(); return t; end
      "axi_basic_rw_test":           begin axi_basic_rw_test           t = new(); return t; end
      "axi_sizes_strobes_test":      begin axi_sizes_strobes_test      t = new(); return t; end
      "axi_reset_por_test":          begin axi_reset_por_test          t = new(); return t; end
      "axi_reset_test":              begin axi_reset_test              t = new(); return t; end
      "axi_reset_idle_test":         begin axi_reset_idle_test         t = new(); return t; end
      "axi_addr_decode_test":        begin axi_addr_decode_test        t = new(); return t; end
      "axi_addr_edges_test":         begin axi_addr_edges_test         t = new(); return t; end
      "axi_decerr_test":             begin axi_decerr_test             t = new(); return t; end
      "axi_decerr_backlog_test":     begin axi_decerr_backlog_test     t = new(); return t; end
      "axi_burst_test":              begin axi_burst_test              t = new(); return t; end
      "axi_burst_corners_test":      begin axi_burst_corners_test      t = new(); return t; end
      "axi_outstanding_test":        begin axi_outstanding_test        t = new(); return t; end
      "axi_deep_outstanding_test":   begin axi_deep_outstanding_test   t = new(); return t; end
      "axi_id_corners_test":         begin axi_id_corners_test         t = new(); return t; end
      "axi_arbitration_test":        begin axi_arbitration_test        t = new(); return t; end
      "axi_arb_rounds_test":         begin axi_arb_rounds_test         t = new(); return t; end
      "axi_concurrent_test":         begin axi_concurrent_test         t = new(); return t; end
      "axi_cross_traffic_test":      begin axi_cross_traffic_test      t = new(); return t; end
      "axi_backpressure_test":       begin axi_backpressure_test       t = new(); return t; end
      "axi_long_stall_test":         begin axi_long_stall_test         t = new(); return t; end
      "axi_channel_indep_test":      begin axi_channel_indep_test      t = new(); return t; end
      "axi_w_order_fill_test":       begin axi_w_order_fill_test       t = new(); return t; end
      "axi_slverr_test":             begin axi_slverr_test             t = new(); return t; end
      "axi_stress_test":             begin axi_stress_test             t = new(); return t; end
      "axi_random_mix_test":         begin axi_random_mix_test         t = new(); return t; end
      "axi_multi_outstanding_test":  begin axi_multi_outstanding_test  t = new(); return t; end
      "axi_bad_id_test":             begin axi_bad_id_test             t = new(); return t; end
      default: return null;
    endcase
  endfunction

endpackage

`endif
