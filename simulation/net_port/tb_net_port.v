`ifndef RATE
`define RATE 24'd460800
`endif
`timescale 1ns/1ps
// net_port + uart_ext, TX looped back to RX: what the companion writes to
// port 1 has to come back from it unchanged and in order.
module tb;

reg clk = 0;
always #15.5 clk = ~clk;          // ~32 MHz

reg reset = 1;
reg enable = 0;
reg [23:0] bitrate = 24'd0;
// set after time 0: uart_ext's always @(*) would not see a value set before
initial #1 bitrate = `RATE;

wire [7:0] mcu_available, mcu_data, mcu_space;
reg        mcu_strobe = 0;
reg  [7:0] mcu_in_data = 0;
reg        mcu_in_strobe = 0;

wire [7:0] tx_avail, tx_data, rx_space, rx_data;
wire       tx_strobe, rx_strobe;
wire       line;

net_port dut (
    .clk(clk), .reset(reset), .enable(enable),
    .mcu_available(mcu_available), .mcu_data(mcu_data), .mcu_strobe(mcu_strobe),
    .mcu_space(mcu_space), .mcu_in_data(mcu_in_data), .mcu_in_strobe(mcu_in_strobe),
    .uart_tx_available(tx_avail), .uart_tx_data(tx_data), .uart_tx_strobe(tx_strobe),
    .uart_rx_space(rx_space), .uart_rx_data(rx_data), .uart_rx_strobe(rx_strobe)
);

uart_ext #(.CLK_HZ(32_220_000)) uart (
    .clk(clk), .resetn(!reset), .enable(enable), .bitrate(bitrate),
    .tx_available(tx_avail), .tx_data(tx_data), .tx_strobe(tx_strobe),
    .rx_space(rx_space), .rx_data(rx_data), .rx_strobe(rx_strobe),
    .txd(line), .rxd(line)
);

localparam N = 40;
integer sent = 0, got = 0, errors = 0;
reg [7:0] want;

// the companion writing: one byte per SPI transfer, only into free space
initial begin
    repeat(10) @(posedge clk);
    // off: nothing waiting, plenty of space
    if(mcu_available != 0 || mcu_space != 8'd255) begin
        $display("FAIL off: available %d space %d", mcu_available, mcu_space);
        errors = errors + 1;
    end
    reset = 0;
    enable = 1;
    repeat(10) @(posedge clk);
    while(sent < N) begin
        if(mcu_space != 0) begin
            mcu_in_data <= 8'hA0 ^ sent[7:0];
            mcu_in_strobe <= 1;
            @(posedge clk);
            mcu_in_strobe <= 0;
            sent = sent + 1;
        end
        repeat(8) @(posedge clk);     // an SPI byte takes far longer
    end
end

// the companion reading: on the level interrupt, byte by byte
initial begin
    @(negedge reset);
    while(got < N) begin
        @(posedge clk);
        if(mcu_available != 0) begin
            want = 8'hA0 ^ got[7:0];
            if(mcu_data !== want) begin
                $display("FAIL byte %0d: got %02x, wanted %02x", got, mcu_data, want);
                errors = errors + 1;
            end
            mcu_strobe <= 1;
            @(posedge clk);
            mcu_strobe <= 0;
            got = got + 1;
            repeat(8) @(posedge clk);
        end
    end
    $display("%0d bytes sent, %0d read back, %0d errors", sent, got, errors);
    if(errors == 0) $display("PASS");
    $finish;
end

initial begin
    #(40_000_000);
    $display("FAIL timeout: %0d sent, %0d read", sent, got);
    $finish;
end

endmodule
