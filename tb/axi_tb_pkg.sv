// =============================================================================
// axi_tb_pkg.sv
//   All reusable verification components (the layered testbench).
//   Order matters: every class is included after the classes it uses.
//
//   The old axi_cov_closure.sv and axi_cov_scenarios.sv are gone: every
//   coverage scenario is now a normal test in tb/tests/.
// =============================================================================
`ifndef AXI_TB_PKG_SV
`define AXI_TB_PKG_SV
`timescale 1ns / 1ps

package axi_tb_pkg;

  import axi_params_pkg::*;

  `include "axi_utils.sv"          // types + address/strobe math
  `include "axi_txn.sv"            // transaction
  `include "axi_agent_cfg.sv"      // agent configuration knobs
  `include "axi_master_driver.sv"  // master driver
  `include "axi_slave_driver.sv"   // slave driver (memory responder)
  `include "axi_monitor.sv"        // passive monitor
  `include "axi_agents.sv"         // master / slave agents
  `include "axi_ref_model.sv"      // reference model
  `include "axi_scoreboard.sv"     // scoreboard
  `include "axi_coverage.sv"       // functional coverage
  `include "axi_env.sv"            // environment
  `include "axi_generator.sv"      // generators (directed helpers + random)

endpackage

`endif
