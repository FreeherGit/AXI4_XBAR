# =============================================================================
# Makefile - AXI4 2x2 crossbar : RTL + layered testbench
#
# Folder layout
#   rtl/axi4_xbar.sv          design
#   tb/*.sv                   testbench (only tb/tb_top.sv is compiled, it
#                             `includes all the other tb files)
#   tb/tests/<topic>/*.sv     one file per test (included by tb/axi_test_list.sv)
#   sim/                      created by make: simulator work files and logs
#
# Usage (run from this folder)
#   make compile                          compile + elaborate (Vivado xsim)
#   make run   TEST=axi_basic_rw_test     run one test, log in sim/logs/
#   make run   TEST=axi_stress_test SEED=7
#   make run   TEST=axi_burst_test ARGS=+VERBOSE       extra detail lines
#   make run   TEST=axi_burst_test ARGS=+SB_VERBOSE    one line per scoreboard compare
#   make run   TEST=axi_burst_test ARGS=+COV_DETAIL    full coverage bin tables
#   make regress                          run every test 10 times (seeds 1..10),
#                                         test output on the terminal +
#                                         PASS/FAIL table at the end +
#                                         merged coverage of all those runs
#   make regress RUNS=20                  run every test 20 times (seeds 1..20)
#   make regress RUNS=20 SEED_START=101   20 runs with seeds 101..120 (new random traffic)
#   make regress SEEDS="3 7 42"           run every test with exactly these seeds
#   make regress QUIET=1                  only the PASS/FAIL table (+ coverage summary)
#   make regress COV=0                    regression without the coverage merge
#   make regress TESTS="axi_smoke_test axi_burst_test"   run a subset
#   make list                             print the test names
#   make clean
#
# Waveforms (Vivado xsim only)  -- all wave files go to sim/waves/
#   make waves      TEST=axi_reset_test   run ONE test in the GUI, every signal
#                                         logged, tb_top signals already added
#   make run        TEST=axi_reset_test WAVES=1
#                                         run ONE test in batch, save
#                                         sim/waves/<TEST>_<SEED>.wdb
#   make waves_all                        run ALL tests in batch (same as
#                                         "make regress WAVES=1"), one .wdb each
#   make waves_all  TESTS="axi_reset_test axi_burst_test"   only some tests
#   make view       TEST=axi_reset_test   open a saved .wdb (no re-run)
#   make list_waves                       show which .wdb files exist
#   Saved layout: in the GUI do File > Save Waveform Configuration as
#   sim/waves/axi.wcfg  -> "make view" / "make waves" will load it next time.
#
# Coverage (Vivado xsim only)
#   Functional coverage = the covergroups in tb/axi_coverage.sv (pins)
#                         and tb/axi_xbar_wb_cov.sv (RTL internals)
#   Code coverage       = statement / branch / condition / toggle
#                         (switched on at elaboration with -cc_type sbct)
#   Every "make run" keeps its own coverage database:
#     functional : sim/xsim.covdb/<TEST>_<SEED>
#     code       : sim/cov_cc/<TEST>_<SEED>/xsim.codeCov/<db>  (copied after the run)
#
#   make regress                          at the end merges the coverage of
#                                         every run of THIS regression
#                                         (TESTS x SEEDS) into one report
#   make cov_merge                        same merge, without re-running
#                                         (uses the same TESTS / SEEDS / RUNS)
#   make cov_merge SEEDS="1 2 3"          merge only these seeds
#   make cov_merge ALL_RUNS=1             merge every database found in sim/
#   make cov_merge MERGE_FAILED=1         also merge runs that FAILED
#                                         (default: only PASSED runs are merged,
#                                          a failing run's coverage is not trusted)
#   make cov_report TEST=axi_burst_test   HTML + text report of ONE test run
#   make cov_summary                      print the scores of the merged report again
#   make cov_summary COV_NAME=axi_burst_test_1   scores of one run's report
#
#   Reports go to sim/cov_report/<TEST>_<SEED>/  or  sim/cov_report/merged/
#     func/functionalCoverageReport/dashboard.html   functional coverage (firefox)
#     code/codeCoverageReport/dashboard.html         code coverage
#     merged/merged_runs.txt                         which runs were merged
#     merged/xcrg_func.log, merged/xcrg_code.log     xcrg tool output
#   CODE_COV=0  elaborates without code coverage (faster simulation)
#   Tip: run "make clean" before a big "make regress", so old databases
#   from an older RTL/testbench are gone.
#
#   SIM=questa or SIM=vcs selects another simulator (default: Vivado xsim).
#   Before using xsim:  source <vivado_install>/settings64.sh
#
#   vim note: every recipe line must start with a TAB  ->  :set noexpandtab
# =============================================================================

SIM      ?= xsim
TEST     ?= axi_smoke_test
SEED     ?= 1
ARGS     ?=
QUIET    ?= 0
CODE_COV ?= 1
WAVES    ?= 0

# coverage merge options
COV          ?= 1
MERGE_FAILED ?= 0
ALL_RUNS     ?= 0
COV_NAME     ?= merged

# regression: how many times every test is run, and with which seeds
RUNS       ?= 10
SEED_START ?= 1
SEEDS      ?= $(shell seq $(SEED_START) $(shell expr $(SEED_START) + $(RUNS) - 1))

ROOT    := $(abspath .)
RTL     := $(ROOT)/rtl/axi4_xbar.sv
TB_DIR  := $(ROOT)/tb
TB_TOP  := $(TB_DIR)/tb_top.sv
TOP     := tb_top
SIM_DIR := $(ROOT)/sim
LOG     := $(SIM_DIR)/logs/$(TEST)_$(SEED).log
RUN_ID  := $(TEST)_$(SEED)

COV_DIR  := $(SIM_DIR)/cov_report
CC_DIR   := $(SIM_DIR)/cov_cc
MRG_DIR  := $(COV_DIR)/merged
WAVE_DIR := $(SIM_DIR)/waves
WDB      := $(WAVE_DIR)/$(RUN_ID).wdb
WCFG     ?= $(WAVE_DIR)/axi.wcfg

# add new test names here so "make regress" runs them
TESTS   ?= axi_smoke_test axi_smoke_dense_test axi_smoke_walk_test axi_smoke_sweep_test \
           axi_basic_rw_test axi_sizes_strobes_test axi_reset_por_test axi_reset_test \
           axi_reset_idle_test axi_addr_decode_test axi_addr_edges_test axi_decerr_test \
           axi_decerr_backlog_test axi_burst_test axi_burst_corners_test \
           axi_outstanding_test axi_deep_outstanding_test axi_id_corners_test \
           axi_arbitration_test axi_arb_rounds_test \
           axi_concurrent_test axi_cross_traffic_test axi_backpressure_test \
           axi_long_stall_test axi_channel_indep_test axi_w_order_fill_test \
           axi_slverr_test axi_stress_test axi_random_mix_test \
           axi_multi_outstanding_test axi_bad_id_test

TB_FILES := $(wildcard $(TB_DIR)/*.sv) $(wildcard $(TB_DIR)/tests/*/*.sv)

# lines pulled out of a failing log and shown in the final summary
ERR_PATTERN := ERROR|Error|FATAL|Fatal|MISMATCH|FAIL|TIMEOUT

ifeq ($(CODE_COV),1)
CC_OPTS := -cc_type sbct
else
CC_OPTS :=
endif

# WAVES=1 : batch run that records every signal into sim/waves/<TEST>_<SEED>.wdb
# WAVES=0 : normal batch run (-R = run all and quit), no wave file
ifeq ($(WAVES),1)
RUN_MODE := -wdb $(WDB) -tclbatch $(WAVE_DIR)/record.tcl
else
RUN_MODE := -R
endif

.PHONY: compile run regress waves waves_all view list_waves list clean \
        cov_report cov_merge cov_summary

list:
	@for t in $(TESTS); do echo $$t; done

# ----------------------------------------------------------------- Vivado xsim
ifeq ($(SIM),xsim)
SNAP := $(SIM_DIR)/xsim.dir/tb_snap/xsimk

# the Makefile is a dependency too: changing CC_OPTS here re-elaborates
# -debug typical is required, otherwise waveforms are empty
$(SNAP): $(RTL) $(TB_FILES) $(ROOT)/Makefile
	mkdir -p $(SIM_DIR)/logs
	cd $(SIM_DIR) && xvlog -sv -i $(TB_DIR) $(RTL) $(TB_TOP) -log $(SIM_DIR)/logs/xvlog.log
	cd $(SIM_DIR) && xelab $(TOP) -debug typical -timescale 1ns/1ps $(CC_OPTS) -s tb_snap \
	  -log $(SIM_DIR)/logs/xelab.log

compile: $(SNAP)

# functional coverage is saved under its own name (TEST_SEED);
# the code coverage folder is copied to sim/cov_cc/TEST_SEED after the run
run: $(SNAP)
	@mkdir -p $(WAVE_DIR) $(SIM_DIR)/logs
	@printf 'log_wave -recursive *\nrun all\nquit\n' > $(WAVE_DIR)/record.tcl
	cd $(SIM_DIR) && xsim tb_snap $(RUN_MODE) -sv_seed $(SEED) -testplusarg TESTNAME=$(TEST) \
	  $(foreach a,$(ARGS),-testplusarg $(patsubst +%,%,$(a))) \
	  -cov_db_dir $(SIM_DIR) -cov_db_name $(RUN_ID) -log $(LOG)
	@for d in $(SIM_DIR)/xsim.codeCov $(SIM_DIR)/xsim.CodeCov; do \
	  if [ -d $$d ]; then \
	    rm -rf $(CC_DIR)/$(RUN_ID); mkdir -p $(CC_DIR)/$(RUN_ID); \
	    cp -r $$d $(CC_DIR)/$(RUN_ID)/; \
	    echo " code coverage of this run copied to $(CC_DIR)/$(RUN_ID)"; \
	  fi; \
	done
	@if [ "$(WAVES)" = "1" ]; then \
	  echo " waveform saved : $(WDB)"; \
	  echo " open it with   : make view TEST=$(TEST) SEED=$(SEED)"; fi

# ---------------------------------------------------------- waveforms
# one test, live in the GUI: every signal is logged (so you can add any
# signal later without re-running), tb_top signals are added automatically.
# If sim/waves/axi.wcfg exists, that saved layout is loaded instead.
waves: $(SNAP)
	@mkdir -p $(WAVE_DIR)
	@if [ -f $(WCFG) ]; then \
	  printf 'log_wave -recursive *\nrun all\n' > $(WAVE_DIR)/gui.tcl; \
	else \
	  printf 'log_wave -recursive *\nadd_wave /$(TOP)/*\nrun all\n' > $(WAVE_DIR)/gui.tcl; \
	fi
	cd $(SIM_DIR) && xsim tb_snap -gui -sv_seed $(SEED) -testplusarg TESTNAME=$(TEST) \
	  $(foreach a,$(ARGS),-testplusarg $(patsubst +%,%,$(a))) \
	  -wdb $(WDB) -tclbatch $(WAVE_DIR)/gui.tcl \
	  $(if $(wildcard $(WCFG)),-view $(WCFG)) \
	  -log $(SIM_DIR)/logs/$(RUN_ID)_gui.log

# every test in batch, one .wdb per test (regress with WAVES=1)
waves_all:
	@$(MAKE) --no-print-directory regress WAVES=1 SEEDS="$(SEED)" TESTS="$(TESTS)" \
	  ARGS="$(ARGS)" QUIET=$(QUIET) COV=$(COV) || true
	@$(MAKE) --no-print-directory list_waves

# open a saved waveform, no simulation is run
view:
	@if [ ! -f $(WDB) ]; then \
	  echo " no waveform $(WDB)"; \
	  echo " make it first : make run TEST=$(TEST) SEED=$(SEED) WAVES=1   (or make waves_all)"; \
	  exit 1; fi
	@printf 'add_wave /$(TOP)/*\n' > $(WAVE_DIR)/view.tcl
	cd $(SIM_DIR) && xsim $(WDB) -gui \
	  $(if $(wildcard $(WCFG)),-view $(WCFG),-tclbatch $(WAVE_DIR)/view.tcl) &

list_waves:
	@echo "------------------------------------------------------------"
	@echo " Saved waveforms in sim/waves/   (open: make view TEST=<name> SEED=<n>)"
	@echo "------------------------------------------------------------"
	@ls -1 $(WAVE_DIR)/*.wdb 2>/dev/null | sed 's#.*/##; s#\.wdb$$##; s#^#   #' \
	  || echo "   none yet - run  make waves_all"

# ---------------------------------------------------------- coverage reports
# one test run
cov_report:
	@echo "------------------------------------------------------------"
	@echo " Coverage report for $(RUN_ID)"
	@echo "------------------------------------------------------------"
	@if [ ! -d $(SIM_DIR)/xsim.covdb/$(RUN_ID) ]; then \
	  echo " no coverage database for $(RUN_ID): run  make run TEST=$(TEST) SEED=$(SEED)  first"; exit 1; fi
	@mkdir -p $(COV_DIR)/$(RUN_ID)/func $(COV_DIR)/$(RUN_ID)/code
	cd $(SIM_DIR) && xcrg -cov_db_dir $(SIM_DIR) -cov_db_name $(RUN_ID) \
	  -report_dir $(COV_DIR)/$(RUN_ID)/func -report_format all
	@args=""; \
	for n in $$(ls $(CC_DIR)/$(RUN_ID)/xsim.[cC]odeCov 2>/dev/null); do \
	  args="$$args -cov_db_dir $(CC_DIR)/$(RUN_ID) -cov_db_name $$n"; done; \
	if [ -n "$$args" ]; then \
	  echo "cd $(SIM_DIR) && xcrg $$args -cc_report $(COV_DIR)/$(RUN_ID)/code -report_format all"; \
	  cd $(SIM_DIR) && xcrg $$args -cc_report $(COV_DIR)/$(RUN_ID)/code -report_format all; \
	else \
	  echo " no code coverage data (elaborated with CODE_COV=0?)"; fi
	@$(MAKE) --no-print-directory cov_summary COV_NAME=$(RUN_ID)

# Merge the coverage of many runs into ONE functional + ONE code report.
# Which runs:
#   default      : every TEST in TESTS x every SEED in SEEDS (= this regression)
#   ALL_RUNS=1   : every database found in sim/xsim.covdb
# Only PASSED runs are merged (log contains "TEST <name> : PASSED"),
# unless MERGE_FAILED=1. Runs with no database are listed as "missing".
cov_merge:
	@echo ""
	@echo "============================================================"
	@echo " MERGING COVERAGE"
	@echo "============================================================"
	@rm -rf $(MRG_DIR); mkdir -p $(MRG_DIR)/func $(MRG_DIR)/code
	@if [ "$(ALL_RUNS)" = "1" ]; then \
	  runs=$$(ls $(SIM_DIR)/xsim.covdb 2>/dev/null | grep '^axi_'); \
	  echo " run selection : ALL databases found in sim/xsim.covdb"; \
	else \
	  runs=""; for t in $(TESTS); do for s in $(SEEDS); do runs="$$runs $${t}_$${s}"; done; done; \
	  echo " run selection : $(words $(TESTS)) tests x seeds ($(SEEDS))"; \
	fi; \
	fargs=""; cargs=""; nf=0; nc=0; nfail=0; nmiss=0; \
	: > $(MRG_DIR)/merged_runs.txt; \
	for r in $$runs; do \
	  if [ ! -d $(SIM_DIR)/xsim.covdb/$$r ]; then \
	    nmiss=$$((nmiss+1)); echo "MISSING  $$r  (no functional database)" >> $(MRG_DIR)/merged_runs.txt; continue; fi; \
	  t=$${r%_*}; \
	  if [ "$(MERGE_FAILED)" != "1" ] && ! grep -q "TEST $$t : PASSED" $(SIM_DIR)/logs/$$r.log 2>/dev/null; then \
	    nfail=$$((nfail+1)); echo "SKIPPED  $$r  (run did not PASS)" >> $(MRG_DIR)/merged_runs.txt; continue; fi; \
	  fargs="$$fargs -cov_db_dir $(SIM_DIR) -cov_db_name $$r"; nf=$$((nf+1)); \
	  cc=""; \
	  for n in $$(ls $(CC_DIR)/$$r/xsim.[cC]odeCov 2>/dev/null); do \
	    cargs="$$cargs -cov_db_dir $(CC_DIR)/$$r -cov_db_name $$n"; cc="yes"; done; \
	  if [ -n "$$cc" ]; then nc=$$((nc+1)); echo "MERGED   $$r  (functional + code)" >> $(MRG_DIR)/merged_runs.txt; \
	  else echo "MERGED   $$r  (functional only, no code coverage copy)" >> $(MRG_DIR)/merged_runs.txt; fi; \
	done; \
	echo " runs merged (functional) : $$nf"; \
	echo " runs merged (code)       : $$nc"; \
	echo " runs skipped (not PASSED): $$nfail   (MERGE_FAILED=1 to include them)"; \
	echo " runs missing (no db)     : $$nmiss"; \
	echo " full list                : $(MRG_DIR)/merged_runs.txt"; \
	if [ $$nfail -gt 0 ] || [ $$nmiss -gt 0 ]; then \
	  echo " not merged:"; grep -v '^MERGED' $(MRG_DIR)/merged_runs.txt | head -n 20 | sed 's/^/     /'; fi; \
	if [ $$nf -eq 0 ]; then echo " nothing to merge: run  make regress  first"; exit 1; fi; \
	echo ""; \
	echo " xcrg: merging functional coverage ..."; \
	if ( cd $(SIM_DIR) && xcrg $$fargs -merge_dir $(MRG_DIR)/func_db -merge_db_name merged_func \
	     -report_dir $(MRG_DIR)/func -report_format all ) > $(MRG_DIR)/xcrg_func.log 2>&1; then \
	  echo "   done (log: $(MRG_DIR)/xcrg_func.log)"; \
	else echo "   xcrg FAILED, last lines of $(MRG_DIR)/xcrg_func.log:"; tail -n 15 $(MRG_DIR)/xcrg_func.log; fi; \
	if [ $$nc -eq 0 ]; then \
	  echo " no code coverage data (elaborated with CODE_COV=0?)"; \
	else \
	  echo " xcrg: merging code coverage ..."; \
	  if ( cd $(SIM_DIR) && xcrg $$cargs -merge_dir $(MRG_DIR)/code_db -merge_db_name merged_code \
	       -cc_report $(MRG_DIR)/code -report_format all ) > $(MRG_DIR)/xcrg_code.log 2>&1; then \
	    echo "   done (log: $(MRG_DIR)/xcrg_code.log)"; \
	  else echo "   xcrg FAILED, last lines of $(MRG_DIR)/xcrg_code.log:"; tail -n 15 $(MRG_DIR)/xcrg_code.log; fi; \
	fi
	@$(MAKE) --no-print-directory cov_summary COV_NAME=merged

# Print the main numbers of a coverage report on the terminal:
#   functional : number of tests, total score, score of every covergroup
#   code       : total statement/branch/condition/toggle score, and the
#                same four scores for every DUT module (instances under tb_top.dut)
# COV_NAME=merged (default) or COV_NAME=<TEST>_<SEED> for one run
cov_summary:
	@d=$(COV_DIR)/$(COV_NAME); \
	f=$$d/func/functionalCoverageReport/xcrg_func_cov_report.txt; \
	c=$$d/code/codeCoverageReport; \
	echo ""; \
	echo "============================================================"; \
	echo " COVERAGE SUMMARY : $(COV_NAME)"; \
	echo "============================================================"; \
	if [ -f $$f ]; then \
	  echo " FUNCTIONAL COVERAGE (covergroups, goal = 100 %)"; \
	  grep -m1 'Number of Tests' $$f | sed 's/ *:, */ : /; s/^ */   /'; \
	  grep -m1 'Coverage Score'  $$f | sed 's/ *:, */ : /; s/^ */   /; s/$$/ %/'; \
	  echo "   ----------------------------------------------------------"; \
	  sed -n '/Total Summary/,/CoverGroups Summary/p' $$f | grep -E '::[A-Za-z0-9_]+ *,' | \
	    awk -F, '{gsub(/ /,"",$$1); gsub(/ /,"",$$2); n=$$1; sub(/.*::/,"",n); \
	              printf "   %-12s %7.2f %%   (%s)\n", n, $$2, $$1}'; \
	else echo " functional report not found: $$f"; fi; \
	echo ""; \
	if [ -f $$c/dashboard.html ]; then \
	  echo " CODE COVERAGE (all compiled files, testbench included)"; \
	  grep -o "<td class='dashTable'>[0-9.]*</td>" $$c/dashboard.html | sed 's/<[^>]*>//g' | \
	    awk 'BEGIN{split("Statement Branch Condition Toggle",l," ")} \
	         {printf "   %-10s : %7.2f %%\n", l[NR], $$1}'; \
	  echo "   ----------------------------------------------------------"; \
	  echo "   DUT modules only            stmt   branch     cond   toggle"; \
	  tr -d '\n' < $$c/modules.html | sed 's#<tr>#\n#g' | grep 'tb_top\.dut' | \
	    sed 's#<[^>]*>#|#g' | \
	    awk -F'|' '{k=0; for(i=1;i<=NF;i++){g=$$i; gsub(/^ +| +$$/,"",g); if(g!="") a[++k]=g} \
	                printf "   %-26s %7.2f  %7.2f  %7.2f  %7.2f\n", a[2], a[5], a[6], a[7], a[8]}'; \
	else echo " code report not found: $$c/dashboard.html"; fi; \
	echo ""; \
	echo " open in firefox:"; \
	echo "   functional : firefox $$d/func/functionalCoverageReport/dashboard.html &"; \
	echo "   code       : firefox $$c/dashboard.html &"; \
	echo "   text       : vim $$f"; \
	echo "============================================================"
endif

# ----------------------------------------------------------------- Questa
ifeq ($(SIM),questa)
compile:
	mkdir -p $(SIM_DIR)/logs
	cd $(SIM_DIR) && vlib work && vlog -sv +incdir+$(TB_DIR) $(RTL) $(TB_TOP)

run: compile
	cd $(SIM_DIR) && vsim -c $(TOP) -sv_seed $(SEED) +TESTNAME=$(TEST) $(ARGS) \
	  -do "run -all; quit -f" | tee $(LOG)
endif

# ----------------------------------------------------------------- Synopsys VCS
ifeq ($(SIM),vcs)
compile:
	mkdir -p $(SIM_DIR)/logs
	cd $(SIM_DIR) && vcs -sverilog -full64 -timescale=1ns/1ps +incdir+$(TB_DIR) $(RTL) $(TB_TOP) -o simv

run: compile
	cd $(SIM_DIR) && ./simv +ntb_random_seed=$(SEED) +TESTNAME=$(TEST) $(ARGS) | tee $(LOG)
endif

# ----------------------------------------------------------------- regression
# Every test in TESTS is run once per seed in SEEDS
# (default: RUNS=10 -> seeds 1..10, so 10 runs of every test).
# Default : each run's output is printed live on the terminal, then a
#           PASS/FAIL table is printed at the end: one line per test with
#           "passed runs / total runs", and for every failing run its seed,
#           its log file and the first ERROR / FAIL lines of that log.
# QUIET=1 : output of each run is hidden, only the table is printed.
# WAVES=1 : every run also saves sim/waves/<TEST>_<SEED>.wdb (xsim only)
# COV=1   : (default, xsim only) after the table, the coverage of all
#           PASSED runs of this regression is merged into one functional and
#           one code coverage report (see cov_merge), and a summary is printed.
#           The coverage merge runs even if some tests failed; the make exit
#           status is still FAIL when any run failed.
regress: compile
	@total=0; pass=0; fail=0; summary=""; \
	for t in $(TESTS); do \
	  tp=0; tf=0; bad=""; \
	  for s in $(SEEDS); do \
	    log=$(SIM_DIR)/logs/$${t}_$${s}.log; \
	    rm -f $$log; \
	    if [ "$(QUIET)" = "1" ]; then \
	      echo " running $$t  seed $$s"; \
	      $(MAKE) --no-print-directory run TEST=$$t SEED=$$s ARGS="$(ARGS)" WAVES=$(WAVES) > /dev/null 2>&1 || true; \
	    else \
	      echo ""; \
	      echo "############################################################"; \
	      echo "#  RUNNING TEST : $$t   (seed $$s)"; \
	      echo "############################################################"; \
	      $(MAKE) --no-print-directory run TEST=$$t SEED=$$s ARGS="$(ARGS)" WAVES=$(WAVES) 2>&1 || true; \
	    fi; \
	    total=$$((total+1)); \
	    if grep -q "TEST $$t : PASSED" $$log 2>/dev/null; then \
	      pass=$$((pass+1)); tp=$$((tp+1)); \
	    else \
	      fail=$$((fail+1)); tf=$$((tf+1)); \
	      errs=$$(grep -E "$(ERR_PATTERN)" $$log 2>/dev/null | head -n 5 | sed 's/^/            | /'); \
	      if [ -z "$$errs" ]; then errs="            | (no ERROR line found - test may have hung or not started)"; fi; \
	      bad="$${bad}      seed $$s   (log: sim/logs/$${t}_$${s}.log)\n$${errs}\n"; \
	    fi; \
	  done; \
	  if [ $$tf -eq 0 ]; then st="PASS"; else st="FAIL"; fi; \
	  line=$$(printf "%-4s  %3d/%-3d  %s" "$$st" "$$tp" "$$((tp+tf))" "$$t"); \
	  summary="$${summary}$${line}\n$${bad}"; \
	done; \
	echo ""; \
	echo "============================================================"; \
	echo " REGRESSION SUMMARY   SIM=$(SIM)   runs per test: $(words $(SEEDS))"; \
	echo " seeds: $(SEEDS)"; \
	echo "============================================================"; \
	echo " result  passed/runs  test"; \
	echo "------------------------------------------------------------"; \
	printf "%b" "$$summary"; \
	echo "------------------------------------------------------------"; \
	echo " TESTS: $(words $(TESTS))   RUNS: $$total   PASSED: $$pass   FAILED: $$fail"; \
	echo "============================================================"; \
	if [ "$(COV)" = "1" ] && [ "$(SIM)" = "xsim" ]; then \
	  $(MAKE) --no-print-directory cov_merge TESTS="$(TESTS)" SEEDS="$(SEEDS)" \
	    MERGE_FAILED=$(MERGE_FAILED) || echo " coverage merge did not finish - see the messages above"; \
	  echo " REGRESSION RESULT : PASSED $$pass / $$total runs   (FAILED: $$fail)"; \
	  echo "============================================================"; \
	fi; \
	[ $$fail -eq 0 ]

clean:
	rm -rf $(SIM_DIR) *.jou *.log *.pb .Xil
