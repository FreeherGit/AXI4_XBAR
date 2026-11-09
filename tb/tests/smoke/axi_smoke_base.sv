`ifndef AXI_SMOKE_BASE_SV
`define AXI_SMOKE_BASE_SV

// =============================================================================
// axi_smoke_base  -  shared code of axi_smoke_walk_test and axi_smoke_sweep_test
//                    (not a test on its own)
//
//   check_words(part, s, addrs, notes):
//     step 1  write one 8-byte word at every address (M0 and M1 take turns)
//     step 2  read every word back with the OTHER master
//     step 3  for every word compare
//               address : address sent by the master == address seen at the slave port
//               data    : data read == data written
//               response: BRESP and RRESP == OKAY
//   A watcher records the AWADDR / ARADDR that really arrived at slave s.
// =============================================================================
class axi_smoke_base extends axi_base_test;

  // ---- slave-port address watcher
  bit              watch_on;
  int              watch_s;
  bit [AXI_AW-1:0] seen_aw[$];
  bit [AXI_AW-1:0] seen_ar[$];

  function new(string name);
    super.new(name);
    timeout_ns = 50_000_000;
  endfunction

  // size of one slave window and offset of its last 8-byte word
  function bit [AXI_AW-1:0] span();
    return S0_LIMIT - S0_BASE + 1;          // 0x1000_0000 (S1 has the same size)
  endfunction

  function bit [AXI_AW-1:0] last_off();
    return span() - 8;
  endfunction

  // records every AW / AR handshake at slave port watch_s while watch_on = 1
  task watch_slaves();
    virtual axi_if v0, v1;
    v0 = env.s_vif[0];
    v1 = env.s_vif[1];
    forever begin
      @(v0.cb);
      if (watch_on) begin
        if (watch_s == 0) begin
          if (v0.cb.awvalid && v0.cb.awready) seen_aw.push_back(v0.cb.awaddr);
          if (v0.cb.arvalid && v0.cb.arready) seen_ar.push_back(v0.cb.araddr);
        end else begin
          if (v1.cb.awvalid && v1.cb.awready) seen_aw.push_back(v1.cb.awaddr);
          if (v1.cb.arvalid && v1.cb.arready) seen_ar.push_back(v1.cb.araddr);
        end
      end
    end
  endtask

  // print_all = 1: one line per word; 0: only wrong words + a summary line
  task check_words(string part, int s, bit [AXI_AW-1:0] addrs[$], string notes[$], bit print_all);
    axi_txn            wr[$], rd[$];
    axi_txn            t;
    int                wrm, rdm;
    int unsigned       n_ok;
    bit                a_ok, d_ok, r_ok;
    logic [AXI_AW-1:0] at_aw, at_ar;
    bit [AXI_IDW-1:0]  wid, rid;
    string             line;

    seen_aw.delete();
    seen_ar.delete();
    watch_s  = s;
    watch_on = 1'b1;

    // step 1 : write every word (M0, M1, M0, ...)
    foreach (addrs[i]) begin
      wrm = i % 2;
      if (wrm == 0) wid = 4'h1;
      else         wid = 4'h9;
      t = new_write(wid, addrs[i]);
      t.strb[0] = '1;
      send_wait(wrm, t);
      wr.push_back(t);
    end

    // step 2 : read every word back with the OTHER master
    foreach (addrs[i]) begin
      rdm = 1 - (i % 2);
      if (rdm == 0) rid = 4'h2;
      else         rid = 4'hA;
      t = new_read(rid, addrs[i]);
      send_wait(rdm, t);
      rd.push_back(t);
    end
    wait_clk(3);
    watch_on = 1'b0;

    // step 3 : compare
    check_num($sformatf("%s S%0d: AW handshakes seen at S%0d", part, s, s), seen_aw.size(), addrs.size());
    check_num($sformatf("%s S%0d: AR handshakes seen at S%0d", part, s, s), seen_ar.size(), addrs.size());
    n_ok = 0;
    foreach (addrs[i]) begin
      wrm = i % 2;
      rdm = 1 - wrm;
      at_aw = 'x;
      at_ar = 'x;
      if (i < seen_aw.size()) at_aw = seen_aw[i];
      if (i < seen_ar.size()) at_ar = seen_ar[i];
      a_ok = (at_aw === addrs[i]) && (at_ar === addrs[i]);
      d_ok = (axi_check_readback(wr[i], rd[i], "", RESP_OKAY, 1'b0) == 0);
      r_ok = (wr[i].resp[0] == RESP_OKAY) && (rd[i].resp[0] == RESP_OKAY);
      if (a_ok && d_ok && r_ok) n_ok++;
      line = $sformatf("%s S%0d #%0d (%s): addr sent %08h, AW at slave %08h, AR at slave %08h | M%0d wrote %016h, M%0d read %016h | BRESP=%s RRESP=%s",
                       part, s, i, notes[i], addrs[i], at_aw, at_ar,
                       wrm, wr[i].data[0], rdm, rd[i].data[0],
                       axi_resp_str(wr[i].resp[0]), axi_resp_str(rd[i].resp[0]));
      if (print_all) check(a_ok && d_ok && r_ok, line);
      else if (!(a_ok && d_ok && r_ok)) check(1'b0, line);
    end
    check_num($sformatf("%s S%0d: words with address, data and response all correct", part, s),
              n_ok, addrs.size());
  endtask

endclass

`endif
