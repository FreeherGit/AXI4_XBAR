`ifndef AXI_TEST_LIST_SV
`define AXI_TEST_LIST_SV

// =============================================================================
// axi_test_list.sv  -  every test file, grouped by topic (included in axi_test_pkg)
//   A file ending in _base.sv holds code shared by the tests below it;
//   it is not a test itself and must be included before them.
//
//   For each topic after reset: ONE simple main test, plus the short
//   "scenario" tests that were already there (they add extra coverage).
// =============================================================================

// ---- smoke                                           (unchanged)
`include "tests/smoke/axi_smoke_test.sv"
`include "tests/smoke/axi_smoke_dense_test.sv"
`include "tests/smoke/axi_smoke_base.sv"
`include "tests/smoke/axi_smoke_walk_test.sv"
`include "tests/smoke/axi_smoke_sweep_test.sv"

// ---- basic                                           (unchanged)
`include "tests/basic/axi_basic_rw_test.sv"
`include "tests/basic/axi_sizes_strobes_test.sv"

// ---- reset                                           (unchanged)
`include "tests/reset/axi_reset_base.sv"
`include "tests/reset/axi_reset_por_test.sv"
`include "tests/reset/axi_reset_test.sv"
`include "tests/reset/axi_reset_idle_test.sv"

// ---- decode
`include "tests/decode/axi_addr_decode_test.sv"
`include "tests/decode/axi_addr_edges_test.sv"

// ---- decerr
`include "tests/decerr/axi_decerr_test.sv"
`include "tests/decerr/axi_decerr_backlog_test.sv"

// ---- burst
`include "tests/burst/axi_burst_test.sv"
`include "tests/burst/axi_burst_corners_test.sv"

// ---- outstanding
`include "tests/outstanding/axi_outstanding_test.sv"
`include "tests/outstanding/axi_deep_outstanding_test.sv"
`include "tests/outstanding/axi_id_corners_test.sv"

// ---- arbitration
`include "tests/arbitration/axi_arbitration_test.sv"
`include "tests/arbitration/axi_arb_rounds_test.sv"

// ---- concurrent
`include "tests/concurrent/axi_concurrent_test.sv"
`include "tests/concurrent/axi_cross_traffic_test.sv"

// ---- backpressure
`include "tests/backpressure/axi_backpressure_test.sv"
`include "tests/backpressure/axi_long_stall_test.sv"

// ---- channels
`include "tests/channels/axi_channel_indep_test.sv"
`include "tests/channels/axi_w_order_fill_test.sv"

// ---- slverr
`include "tests/slverr/axi_slverr_test.sv"

// ---- stress                                          (unchanged)
`include "tests/stress/axi_stress_test.sv"
`include "tests/stress/axi_random_mix_test.sv"

// ---- multi_outstanding
`include "tests/multi_outstanding/axi_multi_outstanding_test.sv"

// ---- bad_id
`include "tests/bad_id/axi_bad_id_test.sv"

`endif
