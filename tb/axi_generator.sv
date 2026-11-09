`ifndef AXI_GENERATOR_SV
`define AXI_GENERATOR_SV

// =============================================================================
// axi_generator.sv  (included inside axi_tb_pkg, replaces axi_seq_lib.sv)
//
//   GENERATOR layer of the layered testbench (no UVM):
//
//       test --> generator --(mailbox)--> master driver --> DUT
//                                         monitor --> scoreboard
//
//   The generator CREATES transactions (directed or constrained-random) and
//   puts them into the driver's mailbox (m_agt[m].seq_mbx).
//
//   Contents
//     axi_make_txn()       : build one directed transaction
//     axi_check_readback() : compare a read with the write that filled the
//                            same bytes, printing every compared value
//     axi_generator        : base generator. Extend it and override gen_txns().
//         run(mbx)              connect to a driver mailbox, generate, report
//         start(agent)          same as run(agent.seq_mbx)
//         send(t)               put t into the mailbox (non-blocking)
//         send_wait(t)          send and wait until the response is back
//         wait_all(q)           wait for a list of sent transactions
//         write(...) / read(...) quick directed blocking calls
//     axi_rand_gen         : constrained-random generator with knobs
//
//   New-style use in a test
//     axi_rand_gen gen = new("gen_m0");
//     gen.num_txns  = 20;                  // how many transactions
//     gen.only_kind = 0;                   // knob: writes only
//     gen.run(env.m_agt[0].seq_mbx);       // generate -> driver of master 0
//
//   Compatibility (so NO other file has to change)
//     typedef axi_base_seq / axi_rand_seq  -> old class names still work
//     start(env.m_agt[m])                  -> old call still works
//     body()                               -> old override still works
//                                             (gen_txns() calls body())
//
//   Vivado xsim note:
//     xsim does not support "wait (arg.field)" when "arg" is an input argument
//     of a class task (warning XSIM 43-3980). send_wait() and wait_all()
//     copy the argument into a LOCAL variable first and wait on that.
// =============================================================================

// -----------------------------------------------------------------------------
// Build a directed transaction (random data, legal strobes, no delays)
// -----------------------------------------------------------------------------
function automatic axi_txn axi_make_txn(axi_kind_e        kind,
                                        bit [AXI_IDW-1:0] id,
                                        bit [AXI_AW-1:0]  addr,
                                        bit [7:0]         len   = 0,
                                        bit [2:0]         size  = 3,
                                        bit [1:0]         burst = BURST_INCR);
  axi_txn t = new();
  t.kind      = kind;
  t.id        = id;
  t.addr      = addr;
  t.len       = len;
  t.size      = size;
  t.burst     = burst;
  t.req_delay = 0;
  t.gap_pct   = 0;
  t.fill_payload();
  return t;
endfunction

// -----------------------------------------------------------------------------
// axi_check_readback
//   wr : a finished write,  rd : a finished read of (some of) the same bytes.
//   Builds the byte image the write left in memory (strobes, FIXED/INCR/WRAP,
//   narrow transfers, "last beat wins" for FIXED) and compares every byte lane
//   of every read beat that the write covered.
//   Prints:  beat, beat address, compared lanes, expected word, read word.
//   Long bursts print the first 4 and last 2 beats (+ every mismatch).
//   Returns the number of errors.
// -----------------------------------------------------------------------------
function automatic int unsigned axi_check_readback(axi_txn   wr,
                                                   axi_txn   rd,
                                                   string    tag,
                                                   bit [1:0] exp_resp = RESP_OKAY,
                                                   bit       verbose  = 1'b1);
  bit [7:0]        img [bit [AXI_AW-1:0]];
  bit [AXI_AW-1:0] baddr, a;
  bit [AXI_SW-1:0] m, cmp;
  bit [AXI_DW-1:0] exp_w;
  int unsigned     errs = 0, nbytes = 0;
  bit              ok;

  if (wr.aborted || rd.aborted || !wr.done || !rd.done) begin
    $error("[CHECK] %s : write or read did not finish (aborted/done=%0d/%0d)", tag, wr.done, rd.done);
    return 1;
  end

  // ---- byte image written by wr
  for (int i = 0; i < wr.beats(); i++) begin
    baddr = axi_beat_addr(wr.addr, wr.size, wr.len, wr.burst, i);
    m     = wr.strb[i] & axi_lane_mask(baddr, wr.size);
    for (int b = 0; b < AXI_SW; b++)
      if (m[b]) img[axi_lane_addr(baddr, b)] = wr.data[i][8*b +: 8];
  end

  if (verbose)
    $display("[CHECK] %s : WR %s -> BRESP=%s | RD %s",
             tag, wr.req_str(), axi_resp_str(wr.resp[0]), rd.req_str());

  if (wr.resp[0] !== exp_resp) begin
    errs++;
    $error("[CHECK] %s : BRESP=%s, expected %s", tag, axi_resp_str(wr.resp[0]), axi_resp_str(exp_resp));
  end
  if (rd.rsp_id !== rd.id || wr.rsp_id !== wr.id) begin
    errs++;
    $error("[CHECK] %s : response ID mismatch (BID %0h/AWID %0h, RID %0h/ARID %0h)",
           tag, wr.rsp_id, wr.id, rd.rsp_id, rd.id);
  end

  for (int i = 0; i < rd.beats(); i++) begin
    baddr = axi_beat_addr(rd.addr, rd.size, rd.len, rd.burst, i);
    m     = axi_lane_mask(baddr, rd.size);
    exp_w = rd.data[i];
    cmp   = '0;
    for (int b = 0; b < AXI_SW; b++) begin
      a = axi_lane_addr(baddr, b);
      if (m[b] && img.exists(a)) begin
        exp_w[8*b +: 8] = img[a];
        cmp[b]          = 1'b1;
      end
    end
    ok = (rd.resp[i] === exp_resp);
    if (exp_resp == RESP_OKAY) ok = ok && (rd.data[i] === exp_w);
    if (!ok) errs++;
    if (exp_resp == RESP_OKAY) nbytes += $countones(cmp);
    if (!ok)
      $error("[CHECK] %s beat %0d addr=%08h lanes=%b expected=%h read=%h RRESP=%s (expected %s) -> MISMATCH",
             tag, i, baddr, cmp, exp_w, rd.data[i], axi_resp_str(rd.resp[i]), axi_resp_str(exp_resp));
    else if (verbose && (i < 4 || i >= rd.beats() - 2))
      $display("        beat %3d addr=%08h lanes=%b expected=%h read=%h RRESP=%s -> OK",
               i, baddr, cmp, exp_w, rd.data[i], axi_resp_str(rd.resp[i]));
    else if (verbose && i == 4)
      $display("        ... (beats 4..%0d also compared, not printed)", rd.beats() - 3);
  end

  if (verbose)
    $display("[CHECK] %s : %0d beats, %0d bytes compared, %0d errors -> %s",
             tag, rd.beats(), nbytes, errs, (errs == 0) ? "PASS" : "FAIL");
  return errs;
endfunction


// =============================================================================
// axi_generator : base class of every generator
// =============================================================================
class axi_generator;

  string              name;
  mailbox #(axi_txn)  gen2drv;        // generator -> driver (= m_agt[m].seq_mbx)
  axi_master_agent    agt;            // set only when start(agent) is used
  event               gen_done;       // triggered when generation has finished
  bit                 verbose = 1'b1; // print start / finish lines

  // what this generator has sent (counted in send())
  int unsigned        n_sent, n_wr, n_rd;

  function new(string name = "axi_generator");
    this.name = name;
  endfunction

  // ---- override ONE of these in a generator (new name / old name)
  virtual task gen_txns();
    body();
  endtask

  virtual task body();
  endtask

  // ---- connect to a driver mailbox and generate
  task run(mailbox #(axi_txn) mbx);
    if (mbx == null) $fatal(1, "[GEN %s] run() called with a null mailbox", name);
    gen2drv = mbx;
    n_sent  = 0;  n_wr = 0;  n_rd = 0;
    if (verbose)
      $display("[%0t] [GEN %s] started : transactions go to the driver through the mailbox",
               $time, name);
    gen_txns();
    if (verbose)
      $display("[%0t] [GEN %s] finished: %0d transactions generated and completed (%0d writes, %0d reads)",
               $time, name, n_sent, n_wr, n_rd);
    -> gen_done;
  endtask

  // ---- old call style: gen.start(env.m_agt[m])
  task start(axi_master_agent agt);
    this.agt = agt;
    run(agt.seq_mbx);
  endtask

  // ---------------------------------------------------------------------------
  task send(axi_txn t);
    n_sent++;
    if (t.kind == AXI_WRITE) n_wr++;
    else                     n_rd++;
    gen2drv.put(t);
  endtask

  // wait on a LOCAL copy of the handle (xsim cannot wait on a task argument)
  task send_wait(axi_txn t);
    axi_txn lt;
    lt = t;
    send(lt);
    wait (lt.done);
  endtask

  task wait_all(axi_txn q[$]);
    axi_txn lt;
    foreach (q[i]) begin
      lt = q[i];
      wait (lt.done);
    end
  endtask

  function axi_txn make(axi_kind_e        kind,
                        bit [AXI_IDW-1:0] id,
                        bit [AXI_AW-1:0]  addr,
                        bit [7:0]         len   = 0,
                        bit [2:0]         size  = 3,
                        bit [1:0]         burst = BURST_INCR);
    return axi_make_txn(kind, id, addr, len, size, burst);
  endfunction

  task write(input  bit [AXI_IDW-1:0] id,
             input  bit [AXI_AW-1:0]  addr,
             input  bit [7:0]         len,
             input  bit [2:0]         size,
             input  bit [1:0]         burst,
             output axi_txn           t);
    t = make(AXI_WRITE, id, addr, len, size, burst);
    send_wait(t);
  endtask

  task read(input  bit [AXI_IDW-1:0] id,
            input  bit [AXI_AW-1:0]  addr,
            input  bit [7:0]         len,
            input  bit [2:0]         size,
            input  bit [1:0]         burst,
            output axi_txn           t);
    t = make(AXI_READ, id, addr, len, size, burst);
    send_wait(t);
  endtask

endclass


// =============================================================================
// axi_rand_gen : constrained-random generator. Leave a knob at -1 for "anything".
//   Prints the knob settings, the first print_max generated transactions and
//   a summary (kind / target / burst) that shows the knobs were respected.
// =============================================================================
class axi_rand_gen extends axi_generator;

  int unsigned      num_txns    = 20;     // number of transactions to generate
  int               only_region = -1;     // 0: S0, 1: S1, 2: unmapped
  int               only_kind   = -1;     // 0: write, 1: read
  int               only_burst  = -1;     // 0: FIXED, 1: INCR, 2: WRAP
  int               max_len     = 255;
  bit               blocking    = 1'b0;   // 1: wait for each txn before the next
  bit [AXI_AW-1:0]  addr_window = 32'h0001_0000;
  bit               sparse_strb = 1'b0;
  int unsigned      gap_pct     = 15;
  bit               no_unmapped = 1'b0;   // 1: never pick region 2
  bit [AXI_IDW-1:0] id_min      = '0;     // ID range used by this generator
  bit [AXI_IDW-1:0] id_max      = '1;
  int unsigned      print_max   = 10;     // how many generated txns to print
  axi_txn           sent[$];

  function new(string name = "axi_rand_gen");
    super.new(name);
  endfunction

  function string knob_str(int v);
    if (v < 0) return "any";
    return $sformatf("%0d", v);
  endfunction

  virtual task gen_txns();
    axi_txn      t;
    bit          ok;
    int unsigned n_reg[3], n_bur[3], n_kind[2], n_bad;

    $display("[%0t] [GEN %s] knobs: num_txns=%0d only_kind=%s only_region=%s only_burst=%s max_len=%0d IDs=%0h..%0h no_unmapped=%0d blocking=%0d",
             $time, name, num_txns, knob_str(only_kind), knob_str(only_region), knob_str(only_burst),
             max_len, id_min, id_max, no_unmapped, blocking);

    for (int i = 0; i < num_txns; i++) begin
      t = new();
      t.addr_window = addr_window;
      t.sparse_strb = sparse_strb;
      t.gap_pct     = gap_pct;
      t.max_len     = max_len;
      t.id_min      = id_min;
      t.id_max      = id_max;
      // fix the fields the knobs ask for (rand_mode(0) = "do not randomize")
      if (only_region < 0 && no_unmapped) begin
        t.region = $urandom_range(1); t.region.rand_mode(0);
      end
      if (only_region >= 0) begin t.region = only_region;              t.region.rand_mode(0); end
      if (only_kind   >= 0) begin t.kind   = axi_kind_e'(only_kind);   t.kind.rand_mode(0);   end
      if (only_burst  >= 0) begin t.burst  = only_burst;               t.burst.rand_mode(0);  end
      // a few retries: some solvers pick a "dist" bucket first and fail if it
      // clashes with other constraints; LRM-compliant simulators pass at once
      ok = 1'b0;
      for (int r = 0; r < 50 && !ok; r++) ok = t.randomize();
      if (!ok) $fatal(1, "[GEN %s] randomize() failed", name);

      if (i < print_max)
        $display("[%0t] [GEN %s] #%0d generated: %s", $time, name, i, t.req_str());
      else if (i == print_max)
        $display("[%0t] [GEN %s] ... (remaining %0d transactions not printed)", $time, name, num_txns - print_max);

      if (t.region < 3) n_reg[t.region]++;
      if (t.burst  < 3) n_bur[t.burst]++;
      if (t.kind == AXI_WRITE) n_kind[0]++;
      else                     n_kind[1]++;

      sent.push_back(t);
      if (blocking) send_wait(t);
      else          send(t);
    end
    wait_all(sent);

    // ---- summary: what was generated, and were the knobs respected?
    n_bad = 0;
    foreach (sent[i]) begin
      if (only_kind   >= 0 && sent[i].kind   != axi_kind_e'(only_kind)) n_bad++;
      if (only_region >= 0 && sent[i].region != only_region)            n_bad++;
      if (only_burst  >= 0 && sent[i].burst  != only_burst)             n_bad++;
      if (no_unmapped && sent[i].region == 2)                           n_bad++;
      if (sent[i].id < id_min || sent[i].id > id_max)                   n_bad++;
      if (sent[i].len > max_len)                                        n_bad++;
    end
    $display("[%0t] [GEN %s] summary: %0d txns | WRITE=%0d READ=%0d | S0=%0d S1=%0d UNMAPPED=%0d | FIXED=%0d INCR=%0d WRAP=%0d | knob violations=%0d -> %s",
             $time, name, sent.size(), n_kind[0], n_kind[1], n_reg[0], n_reg[1], n_reg[2],
             n_bur[0], n_bur[1], n_bur[2], n_bad, (n_bad == 0) ? "KNOBS RESPECTED" : "KNOBS VIOLATED");
    if (n_bad != 0) $error("[GEN %s] %0d generated transactions break the knob settings", name, n_bad);
  endtask

endclass


// -----------------------------------------------------------------------------
// Old names kept so the existing tests, axi_cov_closure.sv and
// axi_cov_scenarios.sv compile without any change.
// -----------------------------------------------------------------------------
typedef axi_generator axi_base_seq;
typedef axi_rand_gen  axi_rand_seq;

`endif // AXI_GENERATOR_SV
