set source_dir [file normalize $env(BOARD_RTL_DIR)]
set output_dir [file normalize $env(BOARD_BUILD_DIR)]
set_arch -family Logos2 -device PG2L200H -speedgrade -6 -package FBB676
foreach source [glob -directory [file join $source_dir core] *.sv] {
    add_design $source
}
foreach source [glob -directory $source_dir *.sv] {
    add_design $source
}
add_design [file join $source_dir cpu_pll120.v]
add_constraint [file join $output_dir board_200pro.fdc]
compile -system_verilog -beta_feature_for_verilog -loop_limit 16384 -top_module board_top
synthesize -ads -frequency 120
dev_map -detail
pnr -number_of_router_thread 4 -action_timeout 30
report_timing -max_path 20 -nworst 2
gen_bit_stream
puts "BOARD_TEST_BUILD_COMPLETE: $output_dir"
exit
