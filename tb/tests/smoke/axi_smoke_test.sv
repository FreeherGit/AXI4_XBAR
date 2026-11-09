`ifndef AXI_SMOKE_TEST_SV
`define AXI_SMOKE_TEST_SV

// =============================================================================
// axi_smoke_test  -  quick "is everything connected?" test
//
//   M0 and M1 send 30 random transactions each, at the same time
//   (random target, burst, length, size; M0 uses IDs 0-7, M1 uses IDs 8-F).
//
//   Checked: every transaction finished, and the scoreboard found no
//   routing / data / response error.
// =============================================================================
class axi_smoke_test extends axi_base_test;

  function new(string name = "axi_smoke_test");
    super.new(name);
  endfunction

  virtual task main();
    axi_rand_gen g0, g1;

    title("Random traffic from M0 and M1 at the same time (30 transactions each)");
    g0 = new("smoke_m0");
    g0.num_txns = 30;  g0.max_len = 31;  g0.id_min = 4'h0;  g0.id_max = 4'h7;
    g1 = new("smoke_m1");
    g1.num_txns = 30;  g1.max_len = 31;  g1.id_min = 4'h8;  g1.id_max = 4'hF;
    quiet(g0);
    quiet(g1);

    fork
      g0.start(env.m_agt[0]);
      g1.start(env.m_agt[1]);
    join
    env.wait_idle();

    check_num("M0 random transactions finished", count_done(g0.sent), 30);
    check_num("M1 random transactions finished", count_done(g1.sent), 30);
    check_num("scoreboard errors (route, data, response)", env.sb.n_err, 0);

    prove("random reads and writes from both masters at once are routed and answered correctly");
  endtask

endclass

`endif
