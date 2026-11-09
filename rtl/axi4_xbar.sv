`timescale 1ns / 1ps

// =============================================================================
// axi4_xbar.sv  -  AXI4 2 masters x 2 slaves crossbar  (v2: multi-target outstanding)
//
// Architecture summary
//   * Targets: T0 = S0, T1 = S1, T2 = internal DECERR responder.
//   * A master may have outstanding transactions to SEVERAL targets at the
//     same time (e.g. a read from S0 and a read from S1 in flight together).
//   * AXI4 ordering is kept with the "single-slave-per-ID" rule:
//       - transactions of one master with the SAME ID may only be outstanding
//         at ONE target at a time; a same-ID request to another target waits
//         until the earlier ones have completed. Same-ID responses therefore
//         always come from one (in-order) slave -> issue order is preserved.
//       - transactions with DIFFERENT IDs may go to different targets and
//         their responses may come back in any order (legal in AXI4).
//   * Slave-side ID width is fixed (= master ID width), so IDs are not widened.
//     Instead every target keeps an ID ownership table:
//       id_busy[t][id] : target t has outstanding transactions with this ID
//       id_own [t][id] : which master owns them
//     Both masters can use the same slave at the same time as long as they use
//     different IDs. If both use the same ID at the same slave, the second one
//     waits until the first drains. B/R responses are routed by looking up
//     id_own[target][BID/RID].
//   * One xbar_req_ctrl per request channel (AW, AR):
//       qualify (ID rules, FIFO space) -> round-robin arbitrate per target ->
//       LOCK grant until handshake -> per (target, ID) outstanding counters.
//   * W routing (AXI4 has no WID, W follows AW order):
//       - per master FIFO : targets of its accepted AWs, in AW order
//       - per target FIFO : masters of the AWs it accepted, in AW order
//       A W beat moves from master m to target t only when both FIFO heads
//       agree (head(master m) == t and head(target t) == m). Both FIFOs are
//       written at the AW handshake, so the order is the same everywhere and
//       no W deadlock is possible.
//   * B / R: per master, a small round-robin selector picks one target that
//     has a response for it; the choice is locked while VALID && !READY so the
//     master sees stable VALID/payload.
//
// Fix / change log
//   FIX-1 (DECERR leak): AW/AR payload muxes are AND-OR muxes on the one-hot
//         grant, so a target that is not granted sees an all-zero payload.
//   CHG-2 (v2): removed "master -> one target at a time" and "target -> one
//         master at a time" restrictions; added single-slave-per-ID ordering,
//         per-(target, ID) ownership table, W-order FIFOs and per-master
//         B/R response selectors.
//
// Known limitation (same as v1): W data is presented to a slave only after
// that slave has accepted the matching AW.
// =============================================================================

// -----------------------------------------------------------------------------
// Small synchronous FIFO
// -----------------------------------------------------------------------------
module xbar_fifo #(
    parameter int WIDTH = 2,
    parameter int DEPTH = 8
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             push,
    input  logic [WIDTH-1:0] din,
    input  logic             pop,
    output logic [WIDTH-1:0] dout,
    output logic             empty,
    output logic             full
);
    localparam int PW = $clog2(DEPTH);

    logic [WIDTH-1:0] mem [DEPTH];
    logic [PW:0]      wptr, rptr;

    assign empty = (wptr == rptr);
    assign full  = (wptr[PW] != rptr[PW]) && (wptr[PW-1:0] == rptr[PW-1:0]);
    assign dout  = empty ? '0 : mem[rptr[PW-1:0]];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= '0;
            rptr <= '0;
        end else begin
            if (push && !full) begin
                mem[wptr[PW-1:0]] <= din;
                wptr              <= wptr + 1'b1;
            end
            if (pop && !empty) rptr <= rptr + 1'b1;
        end
    end
endmodule

// -----------------------------------------------------------------------------
// Request-channel controller (instantiated once for AW, once for AR)
//   Two masters, NT targets. Provides:
//     - qualification:
//         * single-slave-per-ID: master m, ID i may not go to target t while
//           it still has ID i outstanding at another target
//         * ownership: ID i at target t is free or already owned by master m
//         * drain: if the other master waits for the same (t, i), the owner
//           stops issuing more of it, so the waiting master cannot starve
//         * per (t, i) outstanding limit MAXOUT, plus external FIFO space
//     - round-robin arbitration per target
//     - grant LOCK (valid/payload stay stable until the target accepts)
//     - per (target, ID) outstanding counter + owner (id_busy / id_own)
// -----------------------------------------------------------------------------
module xbar_req_ctrl #(
    parameter int NT     = 3,
    parameter int IDW    = 4,
    parameter int MAXOUT = 8
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic [1:0]                   m_valid,    // master request valid
    input  logic [1:0][1:0]              m_tgt,      // decoded target of each master
    input  logic [1:0][IDW-1:0]          m_id,       // request ID of each master
    input  logic [1:0]                   m_ok,       // master-side space (W FIFO)
    input  logic [NT-1:0]                t_ok,       // target-side space (W FIFO)
    input  logic [NT-1:0]                t_ready,    // target ready for the request
    input  logic [NT-1:0]                t_done,     // response complete (B hs / last R hs)
    input  logic [NT-1:0][IDW-1:0]       t_done_id,  // ID of the completed response
    output logic [NT-1:0][1:0]           gnt,        // one-hot master grant per target
    output logic [1:0]                   m_ready,    // ready returned to each master
    output logic [NT-1:0][(1<<IDW)-1:0]  id_busy,    // (target, ID) has outstanding txns
    output logic [NT-1:0][(1<<IDW)-1:0]  id_own      // master that owns (target, ID)
);
    localparam int NID = 1 << IDW;
    localparam int CW  = $clog2(MAXOUT + 1);

    logic [CW-1:0]      cnt [NT][NID];       // outstanding per (target, ID)
    logic [NT-1:0]      last;                // last granted master (round-robin)
    logic [NT-1:0]      lock, lock_m;        // grant lock and locked master
    logic [NT-1:0][1:0] req;

    always_comb begin
        for (int t = 0; t < NT; t++)
            for (int d = 0; d < NID; d++)
                id_busy[t][d] = (cnt[t][d] != '0);
    end

    // Qualification + arbitration
    always_comb begin
        for (int t = 0; t < NT; t++) begin
            for (int m = 0; m < 2; m++) begin
                logic [IDW-1:0] i;
                logic           elsewhere, taken, full, drain;
                i = m_id[m];

                // same ID of this master still outstanding at another target
                elsewhere = 1'b0;
                for (int u = 0; u < NT; u++)
                    if ((u != t) && id_busy[u][i] && (id_own[u][i] == 1'(m))) elsewhere = 1'b1;

                // same ID at this target is owned by the other master
                taken = id_busy[t][i] && (id_own[t][i] != 1'(m));

                // per (target, ID) outstanding limit
                full  = (cnt[t][i] >= CW'(MAXOUT));

                // other master waits for the same (target, ID): stop and drain
                drain = id_busy[t][i] && (id_own[t][i] == 1'(m)) &&
                        m_valid[1-m] && (m_tgt[1-m] == 2'(t)) && (m_id[1-m] == i);

                req[t][m] = m_valid[m] && (m_tgt[m] == 2'(t)) && m_ok[m] && t_ok[t] &&
                            !elsewhere && !taken && !full && !drain;
            end

            if (lock[t])       gnt[t] = lock_m[t] ? 2'b10 : 2'b01;  // hold until hs
            else if (&req[t])  gnt[t] = last[t]   ? 2'b01 : 2'b10;  // round-robin
            else               gnt[t] = req[t];
        end
    end

    always_comb begin
        m_ready = '0;
        for (int t = 0; t < NT; t++)
            for (int m = 0; m < 2; m++)
                if (gnt[t][m] && t_ready[t]) m_ready[m] = 1'b1;
    end

    // State update
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int t = 0; t < NT; t++)
                for (int d = 0; d < NID; d++)
                    cnt[t][d] <= '0;
            last   <= '0;
            lock   <= '0;
            lock_m <= '0;
            id_own <= '0;
        end else begin
            for (int t = 0; t < NT; t++) begin
                logic           hs, gm;
                logic [IDW-1:0] hid;
                hs  = (|gnt[t]) && t_ready[t];
                gm  = gnt[t][1];
                hid = m_id[gm];

                lock[t] <= (|gnt[t]) && !t_ready[t];
                if ((|gnt[t]) && !t_ready[t]) lock_m[t] <= gm;

                if (hs) begin
                    last[t] <= gm;
                    if (!id_busy[t][hid]) id_own[t][hid] <= gm;
                end

                for (int d = 0; d < NID; d++) begin
                    logic inc, dec;
                    inc = hs && (hid == IDW'(d));
                    dec = t_done[t] && (t_done_id[t] == IDW'(d)) && id_busy[t][d];
                    case ({inc, dec})
                        2'b10:   cnt[t][d] <= cnt[t][d] + 1'b1;
                        2'b01:   cnt[t][d] <= cnt[t][d] - 1'b1;
                        default: ;
                    endcase
                end
            end
        end
    end
endmodule

// -----------------------------------------------------------------------------
// Response selector (one per master, for B and for R)
//   Picks one of the targets that currently present a response for this
//   master, round-robin. The selection is locked while VALID && !READY so the
//   master sees a stable VALID and payload (AXI rule).
// -----------------------------------------------------------------------------
module xbar_rsp_sel #(
    parameter int NT = 3
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic [NT-1:0] cand,    // target t has a response for this master
    input  logic          ready,   // master READY
    output logic          valid,   // a response is selected
    output logic [1:0]    sel      // selected target
);
    logic       lock;
    logic [1:0] lsel, last;

    int idx;

    always_comb begin
        valid = 1'b0;
        sel   = '0;
        idx   = 0;
        if (lock) begin
            valid = 1'b1;
            sel   = lsel;
        end else begin
            for (int k = 1; k <= NT; k++) begin
                idx = int'(last) + k;
                if (idx >= NT) idx = idx - NT;
                if (!valid && cand[idx]) begin
                    valid = 1'b1;
                    sel   = 2'(idx);
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lock <= 1'b0;
            lsel <= '0;
            last <= 2'(NT - 1);
        end else begin
            lock <= valid && !ready;
            if (valid && !ready) lsel <= sel;
            if (valid && ready)  last <= sel;
        end
    end
endmodule

// -----------------------------------------------------------------------------
// Top level
// -----------------------------------------------------------------------------
module axi4_xbar #(
    parameter int NUM_MASTERS = 2,
    parameter int NUM_SLAVES  = 2,
    parameter int DATA_WIDTH  = 64,
    parameter int ADDR_WIDTH  = 32,
    parameter int ID_WIDTH    = 4
) (
    input  logic                                    aclk,
    input  logic                                    arst_n,

    // Master interfaces
    input  logic [NUM_MASTERS-1:0][ID_WIDTH-1:0]    m_awid,
    input  logic [NUM_MASTERS-1:0][ADDR_WIDTH-1:0]  m_awaddr,
    input  logic [NUM_MASTERS-1:0][7:0]             m_awlen,
    input  logic [NUM_MASTERS-1:0][2:0]             m_awsize,
    input  logic [NUM_MASTERS-1:0][1:0]             m_awburst,
    input  logic [NUM_MASTERS-1:0]                  m_awvalid,
    output logic [NUM_MASTERS-1:0]                  m_awready,

    input  logic [NUM_MASTERS-1:0][DATA_WIDTH-1:0]  m_wdata,
    input  logic [NUM_MASTERS-1:0][DATA_WIDTH/8-1:0]m_wstrb,
    input  logic [NUM_MASTERS-1:0]                  m_wlast,
    input  logic [NUM_MASTERS-1:0]                  m_wvalid,
    output logic [NUM_MASTERS-1:0]                  m_wready,

    output logic [NUM_MASTERS-1:0][ID_WIDTH-1:0]    m_bid,
    output logic [NUM_MASTERS-1:0][1:0]             m_bresp,
    output logic [NUM_MASTERS-1:0]                  m_bvalid,
    input  logic [NUM_MASTERS-1:0]                  m_bready,

    input  logic [NUM_MASTERS-1:0][ID_WIDTH-1:0]    m_arid,
    input  logic [NUM_MASTERS-1:0][ADDR_WIDTH-1:0]  m_araddr,
    input  logic [NUM_MASTERS-1:0][7:0]             m_arlen,
    input  logic [NUM_MASTERS-1:0][2:0]             m_arsize,
    input  logic [NUM_MASTERS-1:0][1:0]             m_arburst,
    input  logic [NUM_MASTERS-1:0]                  m_arvalid,
    output logic [NUM_MASTERS-1:0]                  m_arready,

    output logic [NUM_MASTERS-1:0][ID_WIDTH-1:0]    m_rid,
    output logic [NUM_MASTERS-1:0][DATA_WIDTH-1:0]  m_rdata,
    output logic [NUM_MASTERS-1:0][1:0]             m_rresp,
    output logic [NUM_MASTERS-1:0]                  m_rlast,
    output logic [NUM_MASTERS-1:0]                  m_rvalid,
    input  logic [NUM_MASTERS-1:0]                  m_rready,

    // Slave interfaces
    output logic [NUM_SLAVES-1:0][ID_WIDTH-1:0]     s_awid,
    output logic [NUM_SLAVES-1:0][ADDR_WIDTH-1:0]   s_awaddr,
    output logic [NUM_SLAVES-1:0][7:0]              s_awlen,
    output logic [NUM_SLAVES-1:0][2:0]              s_awsize,
    output logic [NUM_SLAVES-1:0][1:0]              s_awburst,
    output logic [NUM_SLAVES-1:0]                   s_awvalid,
    input  logic [NUM_SLAVES-1:0]                   s_awready,

    output logic [NUM_SLAVES-1:0][DATA_WIDTH-1:0]   s_wdata,
    output logic [NUM_SLAVES-1:0][DATA_WIDTH/8-1:0] s_wstrb,
    output logic [NUM_SLAVES-1:0]                   s_wlast,
    output logic [NUM_SLAVES-1:0]                   s_wvalid,
    input  logic [NUM_SLAVES-1:0]                   s_wready,

    input  logic [NUM_SLAVES-1:0][ID_WIDTH-1:0]     s_bid,
    input  logic [NUM_SLAVES-1:0][1:0]              s_bresp,
    input  logic [NUM_SLAVES-1:0]                   s_bvalid,
    output logic [NUM_SLAVES-1:0]                   s_bready,

    output logic [NUM_SLAVES-1:0][ID_WIDTH-1:0]     s_arid,
    output logic [NUM_SLAVES-1:0][ADDR_WIDTH-1:0]   s_araddr,
    output logic [NUM_SLAVES-1:0][7:0]              s_arlen,
    output logic [NUM_SLAVES-1:0][2:0]              s_arsize,
    output logic [NUM_SLAVES-1:0][1:0]              s_arburst,
    output logic [NUM_SLAVES-1:0]                   s_arvalid,
    input  logic [NUM_SLAVES-1:0]                   s_arready,

    input  logic [NUM_SLAVES-1:0][ID_WIDTH-1:0]     s_rid,
    input  logic [NUM_SLAVES-1:0][DATA_WIDTH-1:0]   s_rdata,
    input  logic [NUM_SLAVES-1:0][1:0]              s_rresp,
    input  logic [NUM_SLAVES-1:0]                   s_rlast,
    input  logic [NUM_SLAVES-1:0]                   s_rvalid,
    output logic [NUM_SLAVES-1:0]                   s_rready
);

    // This implementation is the fixed 2x2 configuration of the training project.
    if (NUM_MASTERS != 2 || NUM_SLAVES != 2) begin : g_cfg_check
        $error("axi4_xbar: only NUM_MASTERS=2, NUM_SLAVES=2 is supported");
    end

    localparam int         NT     = NUM_SLAVES + 1;   // T0, T1, T2 (DECERR)
    localparam int         NID    = 1 << ID_WIDTH;
    localparam logic [1:0] DECERR = 2'b11;

    // -------------------------------------------------------------------------
    // 1. Target bus: t_*[0], t_*[1] = physical slaves, t_*[2] = DECERR responder
    // -------------------------------------------------------------------------
    logic [NT-1:0][ID_WIDTH-1:0]     t_awid, t_bid, t_arid, t_rid;
    logic [NT-1:0][ADDR_WIDTH-1:0]   t_awaddr, t_araddr;
    logic [NT-1:0][7:0]              t_awlen, t_arlen;
    logic [NT-1:0][2:0]              t_awsize, t_arsize;
    logic [NT-1:0][1:0]              t_awburst, t_arburst, t_bresp, t_rresp;
    logic [NT-1:0]                   t_awvalid, t_awready, t_wlast, t_wvalid, t_wready;
    logic [NT-1:0]                   t_bvalid, t_bready, t_arvalid, t_arready;
    logic [NT-1:0]                   t_rlast, t_rvalid, t_rready;
    logic [NT-1:0][DATA_WIDTH-1:0]   t_wdata, t_rdata;
    logic [NT-1:0][DATA_WIDTH/8-1:0] t_wstrb;

    for (genvar s = 0; s < NUM_SLAVES; s++) begin : g_slave_map
        assign s_awid[s]    = t_awid[s];
        assign s_awaddr[s]  = t_awaddr[s];
        assign s_awlen[s]   = t_awlen[s];
        assign s_awsize[s]  = t_awsize[s];
        assign s_awburst[s] = t_awburst[s];
        assign s_awvalid[s] = t_awvalid[s];
        assign t_awready[s] = s_awready[s];

        assign s_wdata[s]   = t_wdata[s];
        assign s_wstrb[s]   = t_wstrb[s];
        assign s_wlast[s]   = t_wlast[s];
        assign s_wvalid[s]  = t_wvalid[s];
        assign t_wready[s]  = s_wready[s];

        assign t_bid[s]     = s_bid[s];
        assign t_bresp[s]   = s_bresp[s];
        assign t_bvalid[s]  = s_bvalid[s];
        assign s_bready[s]  = t_bready[s];

        assign s_arid[s]    = t_arid[s];
        assign s_araddr[s]  = t_araddr[s];
        assign s_arlen[s]   = t_arlen[s];
        assign s_arsize[s]  = t_arsize[s];
        assign s_arburst[s] = t_arburst[s];
        assign s_arvalid[s] = t_arvalid[s];
        assign t_arready[s] = s_arready[s];

        assign t_rid[s]     = s_rid[s];
        assign t_rdata[s]   = s_rdata[s];
        assign t_rresp[s]   = s_rresp[s];
        assign t_rlast[s]   = s_rlast[s];
        assign t_rvalid[s]  = s_rvalid[s];
        assign s_rready[s]  = t_rready[s];
    end

    // -------------------------------------------------------------------------
    // 2. Address decode  (S0: 0x0xxx_xxxx, S1: 0x1xxx_xxxx, otherwise DECERR)
    // -------------------------------------------------------------------------
    function automatic logic [1:0] decode_addr(input logic [ADDR_WIDTH-1:0] addr);
        case (addr[31:28])
            4'h0:    return 2'd0;
            4'h1:    return 2'd1;
            default: return 2'd2;
        endcase
    endfunction

    logic [1:0][1:0] aw_tgt, ar_tgt;
    for (genvar m = 0; m < 2; m++) begin : g_decode
        assign aw_tgt[m] = decode_addr(m_awaddr[m]);
        assign ar_tgt[m] = decode_addr(m_araddr[m]);
    end

    // -------------------------------------------------------------------------
    // 3. Write subsystem  (AW -> W -> B)
    // -------------------------------------------------------------------------
    logic [NT-1:0][1:0]     aw_gnt;
    logic [NT-1:0][NID-1:0] w_id_busy, w_id_own;
    logic [NT-1:0]          b_done;

    // W-order FIFOs (declared here, used by the AW qualification)
    logic [1:0][1:0]        wq_head;               // per master: target of oldest AW still owing W
    logic [1:0]             wq_empty, wq_full;
    logic [NT-1:0]          tq_head;               // per target: master of oldest AW still owing W
    logic [NT-1:0]          tq_empty, tq_full;

    xbar_req_ctrl #(.NT(NT), .IDW(ID_WIDTH)) u_aw_ctrl (
        .clk(aclk), .rst_n(arst_n),
        .m_valid(m_awvalid), .m_tgt(aw_tgt), .m_id(m_awid),
        .m_ok(~wq_full), .t_ok(~tq_full),
        .t_ready(t_awready), .t_done(b_done), .t_done_id(t_bid),
        .gnt(aw_gnt), .m_ready(m_awready),
        .id_busy(w_id_busy), .id_own(w_id_own)
    );

    // AW mux (grant is locked by the controller, so payload is stable).
    // FIX-1: AND-OR mux on the one-hot grant -> payload is all-zero for any
    // target that is not granted (no DECERR / foreign address on slave ports).
    always_comb begin
        for (int t = 0; t < NT; t++) begin
            t_awvalid[t] = |aw_gnt[t];
            t_awid[t]    = ({ID_WIDTH{aw_gnt[t][0]}}   & m_awid[0])
                         | ({ID_WIDTH{aw_gnt[t][1]}}   & m_awid[1]);
            t_awaddr[t]  = ({ADDR_WIDTH{aw_gnt[t][0]}} & m_awaddr[0])
                         | ({ADDR_WIDTH{aw_gnt[t][1]}} & m_awaddr[1]);
            t_awlen[t]   = ({8{aw_gnt[t][0]}}          & m_awlen[0])
                         | ({8{aw_gnt[t][1]}}          & m_awlen[1]);
            t_awsize[t]  = ({3{aw_gnt[t][0]}}          & m_awsize[0])
                         | ({3{aw_gnt[t][1]}}          & m_awsize[1]);
            t_awburst[t] = ({2{aw_gnt[t][0]}}          & m_awburst[0])
                         | ({2{aw_gnt[t][1]}}          & m_awburst[1]);
        end
    end

    // Handshake events that write / read the W-order FIFOs
    logic [1:0]    m_aw_hs, m_wlast_hs;
    logic [NT-1:0] t_aw_hs, t_wlast_hs;

    always_comb begin
        for (int m = 0; m < 2; m++) begin
            m_aw_hs[m]    = m_awvalid[m] && m_awready[m];
            m_wlast_hs[m] = m_wvalid[m]  && m_wready[m] && m_wlast[m];
        end
        for (int t = 0; t < NT; t++) begin
            t_aw_hs[t]    = (|aw_gnt[t]) && t_awready[t];
            t_wlast_hs[t] = t_wvalid[t]  && t_wready[t] && t_wlast[t];
        end
    end

    for (genvar m = 0; m < 2; m++) begin : g_wq
        xbar_fifo #(.WIDTH(2), .DEPTH(8)) u_wq (
            .clk(aclk), .rst_n(arst_n),
            .push(m_aw_hs[m]),    .din(aw_tgt[m]),
            .pop(m_wlast_hs[m]),  .dout(wq_head[m]),
            .empty(wq_empty[m]),  .full(wq_full[m])
        );
    end

    for (genvar t = 0; t < NT; t++) begin : g_tq
        xbar_fifo #(.WIDTH(1), .DEPTH(8)) u_tq (
            .clk(aclk), .rst_n(arst_n),
            .push(t_aw_hs[t]),    .din(aw_gnt[t][1]),
            .pop(t_wlast_hs[t]),  .dout(tq_head[t]),
            .empty(tq_empty[t]),  .full(tq_full[t])
        );
    end

    // W router: beat moves from master m to target t only when
    //   head(target t FIFO) == m  and  head(master m FIFO) == t
    always_comb begin
        m_wready = '0;
        t_wvalid = '0;
        t_wdata  = '0;
        t_wstrb  = '0;
        t_wlast  = '0;
        for (int t = 0; t < NT; t++) begin
            logic o;
            o = tq_head[t];
            if (!tq_empty[t] && !wq_empty[o] && (wq_head[o] == 2'(t))) begin
                t_wvalid[t] = m_wvalid[o];
                t_wdata[t]  = m_wdata[o];
                t_wstrb[t]  = m_wstrb[o];
                t_wlast[t]  = m_wlast[o];
                m_wready[o] = t_wready[t];
            end
        end
    end

    // B router: BID is looked up in the ownership table of the target
    logic [NT-1:0]      b_route, b_dst;
    logic [1:0][NT-1:0] b_cand;
    logic [1:0]         b_val;
    logic [1:0][1:0]    b_sel;

    always_comb begin
        for (int t = 0; t < NT; t++) begin
            b_route[t] = t_bvalid[t] && w_id_busy[t][t_bid[t]];
            b_dst[t]   = w_id_own[t][t_bid[t]];
        end
        for (int m = 0; m < 2; m++)
            for (int t = 0; t < NT; t++)
                b_cand[m][t] = b_route[t] && (b_dst[t] == 1'(m));
    end

    for (genvar m = 0; m < 2; m++) begin : g_bsel
        xbar_rsp_sel #(.NT(NT)) u_bsel (
            .clk(aclk), .rst_n(arst_n),
            .cand(b_cand[m]), .ready(m_bready[m]),
            .valid(b_val[m]), .sel(b_sel[m])
        );
    end

    always_comb begin
        m_bvalid = '0;
        m_bid    = '0;
        m_bresp  = '0;
        t_bready = '0;
        // response with an ID nobody is waiting for (slave protocol error): sink it
        for (int t = 0; t < NT; t++)
            if (t_bvalid[t] && !b_route[t]) t_bready[t] = 1'b1;
        for (int m = 0; m < 2; m++) begin
            if (b_val[m]) begin
                m_bvalid[m]          = 1'b1;
                m_bid[m]             = t_bid[b_sel[m]];
                m_bresp[m]           = t_bresp[b_sel[m]];
                t_bready[b_sel[m]]   = m_bready[m];
            end
        end
    end

    always_comb begin
        for (int t = 0; t < NT; t++) b_done[t] = t_bvalid[t] && t_bready[t] && b_route[t];
    end

    // -------------------------------------------------------------------------
    // 4. Read subsystem  (AR -> R)
    // -------------------------------------------------------------------------
    logic [NT-1:0][1:0]     ar_gnt;
    logic [NT-1:0][NID-1:0] r_id_busy, r_id_own;
    logic [NT-1:0]          r_done;

    xbar_req_ctrl #(.NT(NT), .IDW(ID_WIDTH)) u_ar_ctrl (
        .clk(aclk), .rst_n(arst_n),
        .m_valid(m_arvalid), .m_tgt(ar_tgt), .m_id(m_arid),
        .m_ok(2'b11), .t_ok({NT{1'b1}}),
        .t_ready(t_arready), .t_done(r_done), .t_done_id(t_rid),
        .gnt(ar_gnt), .m_ready(m_arready),
        .id_busy(r_id_busy), .id_own(r_id_own)
    );

    // AR mux - FIX-1: same AND-OR gating as the AW mux.
    always_comb begin
        for (int t = 0; t < NT; t++) begin
            t_arvalid[t] = |ar_gnt[t];
            t_arid[t]    = ({ID_WIDTH{ar_gnt[t][0]}}   & m_arid[0])
                         | ({ID_WIDTH{ar_gnt[t][1]}}   & m_arid[1]);
            t_araddr[t]  = ({ADDR_WIDTH{ar_gnt[t][0]}} & m_araddr[0])
                         | ({ADDR_WIDTH{ar_gnt[t][1]}} & m_araddr[1]);
            t_arlen[t]   = ({8{ar_gnt[t][0]}}          & m_arlen[0])
                         | ({8{ar_gnt[t][1]}}          & m_arlen[1]);
            t_arsize[t]  = ({3{ar_gnt[t][0]}}          & m_arsize[0])
                         | ({3{ar_gnt[t][1]}}          & m_arsize[1]);
            t_arburst[t] = ({2{ar_gnt[t][0]}}          & m_arburst[0])
                         | ({2{ar_gnt[t][1]}}          & m_arburst[1]);
        end
    end

    // R router: RID is looked up in the ownership table of the target
    logic [NT-1:0]      r_route, r_dst;
    logic [1:0][NT-1:0] r_cand;
    logic [1:0]         r_val;
    logic [1:0][1:0]    r_sel;

    always_comb begin
        for (int t = 0; t < NT; t++) begin
            r_route[t] = t_rvalid[t] && r_id_busy[t][t_rid[t]];
            r_dst[t]   = r_id_own[t][t_rid[t]];
        end
        for (int m = 0; m < 2; m++)
            for (int t = 0; t < NT; t++)
                r_cand[m][t] = r_route[t] && (r_dst[t] == 1'(m));
    end

    for (genvar m = 0; m < 2; m++) begin : g_rsel
        xbar_rsp_sel #(.NT(NT)) u_rsel (
            .clk(aclk), .rst_n(arst_n),
            .cand(r_cand[m]), .ready(m_rready[m]),
            .valid(r_val[m]), .sel(r_sel[m])
        );
    end

    always_comb begin
        m_rvalid = '0;
        m_rid    = '0;
        m_rdata  = '0;
        m_rresp  = '0;
        m_rlast  = '0;
        t_rready = '0;
        for (int t = 0; t < NT; t++)
            if (t_rvalid[t] && !r_route[t]) t_rready[t] = 1'b1;
        for (int m = 0; m < 2; m++) begin
            if (r_val[m]) begin
                m_rvalid[m]          = 1'b1;
                m_rid[m]             = t_rid[r_sel[m]];
                m_rdata[m]           = t_rdata[r_sel[m]];
                m_rresp[m]           = t_rresp[r_sel[m]];
                m_rlast[m]           = t_rlast[r_sel[m]];
                t_rready[r_sel[m]]   = m_rready[m];
            end
        end
    end

    always_comb begin
        for (int t = 0; t < NT; t++)
            r_done[t] = t_rvalid[t] && t_rready[t] && t_rlast[t] && r_route[t];
    end

    // -------------------------------------------------------------------------
    // 5. DECERR responder (target T2)
    //    Write: AW id queue + count of finished W bursts -> one B per burst
    //    Read : {id,len} queue + beat counter            -> len+1 R beats
    //    W data reaches T2 only after its AW was accepted (W-order FIFOs).
    // -------------------------------------------------------------------------
    logic                err_id_full, err_b_hs;
    logic [3:0]          err_wdone;

    assign err_b_hs     = t_bvalid[2] && t_bready[2];
    assign t_awready[2] = !err_id_full;
    assign t_wready[2]  = 1'b1;
    assign t_bvalid[2]  = (err_wdone != 4'd0);
    assign t_bresp[2]   = DECERR;

    xbar_fifo #(.WIDTH(ID_WIDTH), .DEPTH(8)) u_err_id_fifo (
        .clk(aclk), .rst_n(arst_n),
        .push(t_awvalid[2] && t_awready[2]), .din(t_awid[2]),
        .pop(err_b_hs),                      .dout(t_bid[2]),
        .empty(),                            .full(err_id_full)
    );

    always_ff @(posedge aclk or negedge arst_n) begin
        if (!arst_n) err_wdone <= 4'd0;
        else begin
            case ({(t_wvalid[2] && t_wlast[2]), err_b_hs})
                2'b10:   err_wdone <= err_wdone + 4'd1;
                2'b01:   err_wdone <= err_wdone - 4'd1;
                default: ;
            endcase
        end
    end

    logic                  err_ar_empty, err_ar_full;
    logic [ID_WIDTH+8-1:0] err_ar_q;
    logic [7:0]            err_beat;

    assign t_arready[2] = !err_ar_full;
    assign t_rvalid[2]  = !err_ar_empty;
    assign t_rid[2]     = err_ar_q[ID_WIDTH+8-1:8];
    assign t_rdata[2]   = '0;
    assign t_rresp[2]   = DECERR;
    assign t_rlast[2]   = !err_ar_empty && (err_beat == err_ar_q[7:0]);

    xbar_fifo #(.WIDTH(ID_WIDTH+8), .DEPTH(8)) u_err_ar_fifo (
        .clk(aclk), .rst_n(arst_n),
        .push(t_arvalid[2] && t_arready[2]),
        .din({t_arid[2], t_arlen[2]}),
        .pop(t_rvalid[2] && t_rready[2] && t_rlast[2]),
        .dout(err_ar_q),
        .empty(err_ar_empty), .full(err_ar_full)
    );

    always_ff @(posedge aclk or negedge arst_n) begin
        if (!arst_n)                           err_beat <= 8'd0;
        else if (t_rvalid[2] && t_rready[2])   err_beat <= t_rlast[2] ? 8'd0 : err_beat + 8'd1;
    end

endmodule
