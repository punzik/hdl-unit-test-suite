`timescale 1ps/1ps
`default_nettype none

module simple_counter #(parameter COUNT = 16,
                        localparam WIDTH = $clog2(COUNT-1)) // <-- ERROR
    (input wire clock,
     input wire reset,

     input wire i_inc,
     input wire i_dec,

     output reg [WIDTH-1:0] o_count);

    logic [WIDTH-1:0] count_next;

    always_comb
      case ({i_inc, i_dec})
        2'b01:
          if (o_count == '0)
            count_next = WIDTH'(COUNT-1);
          else
            count_next = o_count - 1'b1;

        2'b10:
          if (o_count == WIDTH'(COUNT-1))
            count_next = '0;
          else
            count_next = o_count + 1'b1;

        default: count_next = o_count;
      endcase

    always_ff @(posedge clock)
      if (reset) o_count <= '0;
      else       o_count <= count_next;

endmodule // simple_counter
