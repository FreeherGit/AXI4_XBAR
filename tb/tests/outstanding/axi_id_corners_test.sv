`ifndef AXI_ID_CORNERS_TEST_SV
`define AXI_ID_CORNERS_TEST_SV

// =============================================================================
// axi_id_corners_test  -  the smallest (0) and largest (F) ID
//
//   Part A : each master alone uses ID 0 and ID F to S0, S1 and UNMAPPED
//   Part B : both masters use the SAME corner ID to the SAME target in the
//            same clock (the crossbar must serve them one after the other)
//   Part C : both masters use the SAME corner ID to DIFFERENT slaves in the
//            same clock
//   Checked: BID == AWID, RID == ARID, response == reference model,
//            read data == written data.
//
//   (This scenario was written in the old axi_cov_scenarios.sv but no test
//    called it. It is new in the regression and can only ADD coverage.)
// =============================================================================
class axi_id_corners_test extends axi_base_test;

  function new(string name = "axi_id_corners_test");
    super.new(name);
  endfunction

  virtual function void configure();
    scenario_setup();
  endfunction

  // M0 -> tg0 and M1 -> tg1, both with the same ID, in the same clock
  task corner_pair(int tg0, int tg1, bit [AXI_IDW-1:0] id);
    axi_txn          w0, w1, r0, r1;
    axi_txn          q[$];
    bit [AXI_AW-1:0] a0, a1;
    a0 = scratch(tg0) + 32'h00D8_0000 + 32'h100 * id;
    a1 = scratch(tg1) + 32'h00DC_0000 + 32'h100 * id;

    wait_clk(1);
    w0 = new_write(id, a0, 3);  q.push_back(w0);  send(0, w0);
    w1 = new_write(id, a1, 3);  q.push_back(w1);  send(1, w1);
    wait_list(q);
    q.delete();
    wait_clk(1);
    r0 = new_read(id, a0, 3);   q.push_back(r0);  send(0, r0);
    r1 = new_read(id, a1, 3);   q.push_back(r1);  send(1, r1);
    wait_list(q);

    check_pair($sformatf("ID %0h M0->%s (M1 used the same ID at once)", id, tgt_name(tg0)), w0, r0);
    check_pair($sformatf("ID %0h M1->%s (M0 used the same ID at once)", id, tgt_name(tg1)), w1, r1);
  endtask

  virtual task main();
    bit [AXI_IDW-1:0] cid[2];
    cid[0] = '0;        // ID 0
    cid[1] = '1;        // ID F

    title("PART A : each master alone, ID 0 and ID F, to every target");
    for (int m = 0; m < NUM_M; m++)
      for (int c = 0; c < 2; c++)
        for (int tg = 0; tg < 3; tg++)
          write_read(m, cid[c], scratch(tg) + 32'h00D0_0000 + 32'h1000 * m + 32'h100 * c, 3,
                     3, BURST_INCR, $sformatf("(corner ID %0h)", cid[c]));

    title("PART B : both masters, same corner ID, same target, same clock");
    for (int c = 0; c < 2; c++)
      for (int tg = 0; tg < 3; tg++)
        corner_pair(tg, tg, cid[c]);

    title("PART C : both masters, same corner ID, different slaves, same clock");
    for (int c = 0; c < 2; c++) begin
      corner_pair(0, 1, cid[c]);
      corner_pair(1, 0, cid[c]);
    end

    prove("IDs 0 and F work from both masters to S0, S1 and UNMAPPED");
    prove("when both masters use the same corner ID at once, every BID / RID and every byte returns to the right master");
  endtask

endclass

`endif
