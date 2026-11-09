`ifndef AXI_AGENTS_SV
`define AXI_AGENTS_SV

// =============================================================================
// axi_agents.sv  (included inside axi_tb_pkg)
//   axi_master_agent : sequence mailbox + master driver + monitor
//   axi_slave_agent  : slave (memory responder) driver + monitor
//   Sequences run on a master agent with  seq.start(env.m_agt[i]).
// =============================================================================

class axi_master_agent;

  string              name;
  axi_agent_cfg       cfg;
  virtual axi_if      vif;
  mailbox #(axi_txn)  seq_mbx;      // sequence -> driver
  axi_master_driver   drv;
  axi_monitor         mon;

  function new(string name, axi_agent_cfg cfg, virtual axi_if vif);
    this.name = name;
    this.cfg  = cfg;
    this.vif  = vif;
    seq_mbx   = new();
    drv       = new({name, ".drv"}, cfg, vif, seq_mbx);
    mon       = new({name, ".mon"}, cfg.port_idx, 1'b1, vif);
  endfunction

  task run();
    fork
      drv.run();
      mon.run();
    join_none
  endtask

  function bit idle();
    return drv.idle() && mon.idle();
  endfunction

endclass


class axi_slave_agent;

  string              name;
  axi_agent_cfg       cfg;
  virtual axi_if      vif;
  axi_slave_driver    drv;
  axi_monitor         mon;

  function new(string name, axi_agent_cfg cfg, virtual axi_if vif);
    this.name = name;
    this.cfg  = cfg;
    this.vif  = vif;
    drv       = new({name, ".drv"}, cfg, vif);
    mon       = new({name, ".mon"}, cfg.port_idx, 1'b0, vif);
  endfunction

  task run();
    fork
      drv.run();
      mon.run();
    join_none
  endtask

  function bit idle();
    return drv.idle() && mon.idle();
  endfunction

endclass
`endif // AXI_AGENTS_SV
