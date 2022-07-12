`timescale 1ps/1ps

`include "utest.vh"

module vpi_log2 #(parameter ARGUMENT = 1.0,
                  parameter SIGMA = 1e-6);
    real dut, gold;

    initial begin
        gold = $ln(ARGUMENT) / $ln(2);
        dut  = $log2(ARGUMENT);

        `log_info(("Gold: %0f", gold));
        `log_info((" DUT: %0f", dut));

        if ($abs(gold - dut) > SIGMA)
          `log_error(("FAIL"));

        $finish;
    end

endmodule // vpi_log2
