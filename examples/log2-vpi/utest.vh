`ifndef UTEST_VERILOG_DEFINES
 `define UTEST_VERILOG_DEFINES

// Log level string prefixes for use with $display function.
// Example usage: $display("%sError message", `LOG_ERR);
 `define LOG_INFO "INFO#"
 `define LOG_WARN "WARN#"
 `define LOG_ERR  "FAIL#"

// Dirty hacked redefine of $display function. Must be used with two parentheses.
// Example usage: `log_info(("Information message"));
 `define log_quiet(msg) begin $display({$sformatf msg}); end
 `define log_info(msg)  begin $display({`LOG_INFO, $sformatf msg}); end
 `define log_warn(msg)  begin $display({`LOG_WARN, $sformatf msg}); end
 `define log_error(msg) begin $display({`LOG_ERR, $sformatf msg}); end
`endif
