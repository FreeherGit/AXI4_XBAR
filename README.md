# AXI4 2x2 Crossbar - RTL and Layered SystemVerilog Testbench

```
axi4_xbar_project/
├── Makefile            compile / run / regression (Vivado xsim by default)
├── README.md
├── rtl/
│   └── axi4_xbar.sv    crossbar RTL (v2: multi-slave outstanding, single-slave-per-ID ordering)
└── tb/                 class-based layered testbench (no UVM): interfaces, transaction,
    │                   drivers, monitor, agents, reference model, scoreboard, coverage,
    │                   generator, environment, base test
    └── tests/          one short test per file, in one folder per topic (33 tests)
```

`sim/` is created by `make` and holds the simulator work files and logs
(`sim/logs/<test>_<seed>.log`). Delete it any time with `make clean`.

## Quick start (Ubuntu + Vivado 2025)

```bash
source /tools/Xilinx/Vivado/2025.1/settings64.sh   # adjust to your install path
cd axi4_xbar_project
make compile                         # xvlog + xelab
make run TEST=axi_basic_rw_test      # one test
make regress                         # all 33 tests -> PASS/FAIL table
make cov_merge                       # coverage of all tests together
```

More options:

```bash
make run TEST=axi_stress_test SEED=7          # another random seed
make run TEST=axi_burst_test ARGS=+VERBOSE    # extra detail lines
make run TEST=axi_burst_test ARGS=+SB_VERBOSE # one scoreboard line per transaction
make run TEST=axi_burst_test ARGS=+COV_DETAIL # full coverage bin tables at the end
make waves TEST=axi_basic_rw_test             # open the xsim GUI with waveforms
make list                                     # print all test names
```

## What the log looks like

Every check prints ONE line that says what was compared:

```
[1250000] PASS : M0->S1 write B then read B : 8 beats read back == data written
[1315000] PASS : M0 00008000 : BRESP : got SLVERR == expected SLVERR
[1315000] PASS : M0 writes in flight at the same time : got 8 >= needed 4
```

A failing check prints `FAIL` as an `Error:` line. At the end of each test:
scoreboard summary, a short coverage summary, `TEST CHECKS : n passed, m failed`,
the list "WHAT THIS TEST PROVED" and `TEST <name> : PASSED` (or `FAILED`).

## Important: compile only two files

Only these two files are compile sources:

- `rtl/axi4_xbar.sv`
- `tb/tb_top.sv`  (it `` `include``s every other file in `tb/` and `tb/tests/`)

The `tb/` folder must be on the include path (`xvlog -i tb`, `+incdir+tb`).

### Vivado GUI (project mode)

1. Add Sources -> Add or create simulation sources -> add **only**
   `rtl/axi4_xbar.sv` and `tb/tb_top.sv`.
2. Settings -> Simulation -> Simulation tab: *Verilog options* -> *Include directories*:
   add the `tb` folder.
3. Set `tb_top` as the simulation top.
4. Settings -> Simulation -> Simulation tab -> `xsim.simulate.xsim.more_options`:
   `-testplusarg TESTNAME=axi_basic_rw_test -sv_seed 1`
5. Set *Simulation run time* to `all` and Run Behavioral Simulation.

## Testbench files (`tb/`)

| File | Layer / role |
|---|---|
| `tb_top.sv` | top: clock, reset, interfaces, DUT, runs `+TESTNAME` (**compile this**) |
| `axi_params_pkg.sv` | widths, address map, AXI constants |
| `axi_if.sv` | AXI4 port interface + protocol checks |
| `axi_rst_if.sv` | reset control (`apply_reset`, `assert_reset`, `release_reset`) |
| `axi_tb_pkg.sv` | package that includes all component classes below |
| `axi_utils.sv` | beat address / byte-lane math (FIXED, INCR, WRAP, narrow) |
| `axi_txn.sv` | transaction (one whole burst) with constraints |
| `axi_agent_cfg.sv` | per-agent knobs (outstanding, backpressure, latency, SLVERR window) |
| `axi_master_driver.sv` | master driver |
| `axi_slave_driver.sv` | slave driver = memory model responder |
| `axi_monitor.sv` | passive monitor, used on master AND slave ports |
| `axi_agents.sv` | `axi_master_agent`, `axi_slave_agent` |
| `axi_ref_model.sv` | reference model: routing, expected response, byte-level memory model |
| `axi_scoreboard.sv` | compares master side, slave side and reference model |
| `axi_coverage.sv` | functional coverage from the pins |
| `axi_xbar_wb_cov.sv` | white-box coverage of conditions inside the RTL |
| `axi_env.sv` | environment (+ short coverage summary at the end of a test) |
| `axi_generator.sv` | `axi_make_txn`, `axi_check_readback`, random generator `axi_rand_gen` |
| `axi_test_pkg.sv` | test package + `axi_create_test()` (test name -> test object) |
| `axi_base_test.sv` | base test: run flow + all the easy helpers used by the tests |
| `axi_test_list.sv` | list of `` `include``s, one per file in `tests/` |

## Tests

`tb/tests/<topic>/<test>.sv`. A file ending in `_base.sv` is shared code for
the tests in the same folder, not a test.

Every topic from *decode* on has **one simple main test** (written as a few
numbered STEPs, explained in the comment at the top of the file) and the
short **scenario** tests that add extra coverage.

| Folder | `+TESTNAME=` | What it checks |
|---|---|---|
| smoke | `axi_smoke_test` | random traffic from both masters at once |
| smoke | `axi_smoke_dense_test` | every byte of the first / last 4 KB of S0 and S1 |
| smoke | `axi_smoke_walk_test` | walking-1 / walking-0 on every address bit, address at the slave port |
| smoke | `axi_smoke_sweep_test` | one word every 1 MB over all of S0 and S1 |
| basic | `axi_basic_rw_test` | TC-01 read / write on M0->S0, M0->S1, M1->S0, M1->S1 |
| basic | `axi_sizes_strobes_test` | 1/2/4/8-byte beats and partial / empty strobes on every path |
| reset | `axi_reset_por_test` | TC-02 all crossbar VALIDs 0 after power-on reset |
| reset | `axi_reset_test` | TC-02 asynchronous reset mid-traffic, recovery on every path |
| reset | `axi_reset_idle_test` | reset while idle, then every master to S0 / S1 / unmapped |
| decode | `axi_addr_decode_test` | TC-03 first / last word of S0 and S1 + unmapped, write counters per slave |
| decode | `axi_addr_edges_test` | first / last address of every region from both masters |
| decerr | `axi_decerr_test` | TC-04 DECERR for 1/16/256 beats + 4 DECERRs in flight while M1 uses S0 |
| decerr | `axi_decerr_backlog_test` | DECERR responder full (10 requests, READY held low) |
| burst | `axi_burst_test` | TC-05 INCR (lengths, narrow, unaligned, 256), FIXED, WRAP, random strobes |
| burst | `axi_burst_corners_test` | INCR 256, WRAP 2/4/8/16, FIXED 1/16, INCR to a 4 KB edge, every path |
| outstanding | `axi_outstanding_test` | TC-06 8 writes in flight with own IDs, 8 same-ID reads in order |
| outstanding | `axi_deep_outstanding_test` | 10 same-ID transactions in flight (limit 8 per ID) |
| outstanding | `axi_id_corners_test` | IDs 0 and F from both masters, also at the same time |
| arbitration | `axi_arbitration_test` | TC-07 both masters share a slave (no starvation) + round-robin tie |
| arbitration | `axi_arb_rounds_test` | same-clock requests to every target, grant locked while not ready |
| concurrent | `axi_concurrent_test` | TC-08 two paths in parallel (time < 1.5 x one path), data correct |
| concurrent | `axi_cross_traffic_test` | different / same targets at once, two responses for one master at once |
| backpressure | `axi_backpressure_test` | TC-09 50 % READY low everywhere: directed + random traffic |
| backpressure | `axi_long_stall_test` | each READY held low 14 clocks, one channel at a time |
| channels | `axi_channel_indep_test` | TC-10 B / AR / W / R blocked one at a time, other traffic still works |
| channels | `axi_w_order_fill_test` | W-order FIFOs full, W order kept at a shared target |
| slverr | `axi_slverr_test` | TC-11 SLVERR inside / OKAY just outside the windows, 8-beat SLVERR read |
| slverr | `axi_slverr_matrix_test` | SLVERR from S0 and S1 to M0 and M1, INCR and WRAP |
| stress | `axi_stress_test` | TC-12 long random mix (`+STRESS_N=<n>`) |
| stress | `axi_random_mix_test` | random traffic, backpressure, latency, both masters share all IDs |
| multi_outstanding | `axi_multi_outstanding_test` | TC-13 different IDs out of order, same ID held back, two masters share S0 |
| multi_outstanding | `axi_id_rules_test` | ID rules: same ID elsewhere / taken by other master / drain |
| bad_id | `axi_bad_id_test` | TC-14 stray B / R accepted, not forwarded, every path still works |

## Writing a test

A test is a class with two parts: `configure()` (knobs, optional) and `main()`
(traffic + checks). All helpers are in `tb/axi_base_test.sv` with a short list
at the top of that file.

```systemverilog
class my_test extends axi_base_test;

  function new(string name = "my_test");
    super.new(name);
  endfunction

  virtual function void configure();
    env.s_cfg[0].wready_low_pct = 30;        // S0 holds WREADY low 30 % of the time
  endfunction

  virtual task main();
    axi_txn wr, rd;
    title("M0 writes 4 beats to S1 and reads them back");
    wr = new_write(4'h1, 32'h1000_0000, 3);  // ID 1, address, len = beats - 1
    rd = new_read (4'h1, 32'h1000_0000, 3);
    send_wait(0, wr);                        // master 0, wait until finished
    send_wait(0, rd);
    check_resp("BRESP", wr.resp[0], RESP_OKAY);
    check_data("read back", wr, rd);

    write_read(1, 4'h9, 32'h0000_2000, 7);   // the same in one line, from M1 to S0

    prove("M0 can write and read S1");
  endtask

endclass
```

Then:

1. Save it as `tb/tests/<topic>/my_test.sv` (wrap it in `` `ifndef MY_TEST_SV `` /
   `` `define MY_TEST_SV `` / `` `endif `` like the other files).
2. Add `` `include "tests/<topic>/my_test.sv" `` to `tb/axi_test_list.sv`.
3. Add one line to `axi_create_test()` in `tb/axi_test_pkg.sv`.
4. Add the name to `TESTS` in the Makefile.

## What the scoreboard checks (for every transaction of every test)

- `[ROUTE]` every request reaches the right slave exactly once, unchanged (ID, ADDR, LEN, SIZE, BURST)
- `[WDATA]` W data and strobes reach the slave unchanged
- `[RDATA]`/`[RESP]` RDATA/RRESP/BRESP/BID/RID come back to the right master unchanged
- `[RESP]` response code equals the reference model (OKAY / SLVERR / DECERR)
- `[DECERR]` unmapped requests never reach a slave; DECERR on every beat with the right ID
- `[GHOST]` nothing appears on a slave that no master issued
- `[REF]` read data equals the reference memory model (byte level, ordering-aware)
- `[PROTO]` monitor protocol checks + the checks in `tb/axi_if.sv`
