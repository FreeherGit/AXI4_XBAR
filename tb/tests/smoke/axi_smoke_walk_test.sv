`ifndef AXI_SMOKE_WALK_TEST_SV
`define AXI_SMOKE_WALK_TEST_SV

// =============================================================================
// axi_smoke_walk_test  -  every address bit of S0 and S1 works on its own
//
//   For every address bit b inside a slave window (bits 3..27):
//     walking-1 : base with ONLY bit b = 1
//     walking-0 : last word with ONLY bit b = 0
//   plus the first and the last word of the window.
//
//   ALL words are written first, THEN all are read back (by the other
//   master). If two addresses reached the same memory location (a stuck or
//   shorted address bit), one of them would read back the other one's data.
//   The address that arrived at the slave port is compared with the address
//   the master sent. (shared code: axi_smoke_base.sv)
// =============================================================================
class axi_smoke_walk_test extends axi_smoke_base;

  function new(string name = "axi_smoke_walk_test");
    super.new(name);
  endfunction

  virtual task main();
    bit [AXI_AW-1:0] addrs[$];
    string           notes[$];
    bit [AXI_AW-1:0] first_w, last_w;
    int              nbits;

    nbits = $clog2(span());                // 28 -> bits 0..27 are inside a window
    fork watch_slaves(); join_none

    for (int s = 0; s < NUM_S; s++) begin
      title($sformatf("S%0d : walking-1 and walking-0 on address bits 3..%0d", s, nbits - 1));
      first_w = slave_base(s);
      last_w  = slave_base(s) + last_off();
      addrs.delete();
      notes.delete();
      addrs.push_back(first_w);  notes.push_back("first word");
      addrs.push_back(last_w);   notes.push_back("last word");
      for (int b = 3; b < nbits; b++) begin
        addrs.push_back(first_w | (32'd1 << b));
        notes.push_back($sformatf("walking-1, bit %0d", b));
        addrs.push_back(last_w & ~(32'd1 << b));
        notes.push_back($sformatf("walking-0, bit %0d", b));
      end
      check_words("WALK", s, addrs, notes, 1'b1);
    end

    prove($sformatf("every address bit 3..%0d reaches S0 and S1 unchanged as 0 and as 1, and no two addresses alias", nbits - 1));
    prove("data written by one master is read back unchanged by the other master");
  endtask

endclass

`endif
