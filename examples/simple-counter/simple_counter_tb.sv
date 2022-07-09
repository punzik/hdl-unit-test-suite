`timescale 1ps/1ps

`include "utest.vh"

module simple_counter_tb;
    logic clock = 1'b0;
    logic reset = 1'b1;

    always #(10ns/2) clock = ~clock;

    parameter COUNT = 16;
    parameter ITERATIONS = 100;
    parameter DIRECTION = 1;    // 1 - increment, -1 - decrement, 0 - random

    localparam WIDTH = $clog2(COUNT-1); // <-- ERROR

    logic i_inc;
    logic i_dec;
    logic [WIDTH-1:0] o_count;

    simple_counter #(.COUNT(COUNT))
    DUT (.*);

    int gold_count;

    //// Shows that a `UTEST_BASE_DIR define exists
    // initial begin
    //     `log_info(("From verilog code. Base dir: %s", `UTEST_BASE_DIR));
    // end

    initial begin
        i_inc = 1'b0;
        i_dec = 1'b0;
        reset = 1'b1;
        repeat(2) @(posedge clock) #1;

        reset = 1'b0;
        @(posedge clock) #1;

        gold_count = '0;

        for (int i = 0; i < ITERATIONS; i += 1) begin
            case (DIRECTION)
              -1:      {i_inc, i_dec} = 2'b01;
              1:       {i_inc, i_dec} = 2'b10;
              default: {i_inc, i_dec} = 2'($urandom);
            endcase

            @(posedge clock) #1;

            if (i_inc && !i_dec)
              gold_count ++;
            else if (!i_inc && i_dec)
              gold_count --;

            if (gold_count >= COUNT) gold_count = 0;
            if (gold_count < 0) gold_count = COUNT-1;

            if (gold_count != int'(o_count))
              `log_error(("#%0t: Gold count = %0d, DUT count = %0d", $time, gold_count, o_count));
        end

        repeat(2) @(posedge clock) #1;
        $finish;
    end

endmodule // simple_counter_tb
