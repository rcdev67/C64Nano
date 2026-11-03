//
// net_port.v
//
// The companion's port 1 on the C64: two FIFOs between its SPI port
// commands (sysctrl.v) and the external UART on the PMOD pins (uart_ext.v),
// for the companion's own download to the SD card through the WiFi modem.
// Our Atari ST core does the same in its top level; here it is a module of
// its own, as VHDL cannot name io_fifo's ports "in" and "out".
//
// 15 bytes each way, as the 6551's FIFOs, and like them in distributed RAM:
// the core has no block RAM left. The companion fetches on a level
// interrupt while bytes are waiting, see sysctrl.v.
//
// Off, the port reports nothing waiting and plenty of space: the companion's
// port write spins until there is room, so a write is swallowed instead.
//

module net_port (
    input        clk,
    input        reset,
    input        enable,             // "RS232 port: Netz"

    // the companion, through sysctrl.v
    output [7:0] mcu_available,      // bytes from the modem waiting
    output [7:0] mcu_data,
    input        mcu_strobe,
    output [7:0] mcu_space,          // free bytes towards the modem
    input  [7:0] mcu_in_data,
    input        mcu_in_strobe,

    // the external UART
    output [7:0] uart_tx_available,
    output [7:0] uart_tx_data,
    input        uart_tx_strobe,
    output [7:0] uart_rx_space,
    input  [7:0] uart_rx_data,
    input        uart_rx_strobe
);

wire       fifo_reset = reset || !enable;
wire [3:0] tx_used, tx_space, rx_used, rx_space;

// companion -> modem
io_fifo tx_fifo (
    .reset      ( fifo_reset ),
    .in         ( mcu_in_data ),
    .in_clk     ( clk ),
    .in_strobe  ( mcu_in_strobe ),
    .in_enable  ( 1'b0 ),
    .out_clk    ( clk ),
    .out        ( uart_tx_data ),
    .out_strobe ( uart_tx_strobe ),
    .out_enable ( 1'b0 ),
    .space      ( tx_space ),
    .empty      ( ),
    .used       ( tx_used ),
    .full       ( )
);

// modem -> companion
io_fifo rx_fifo (
    .reset      ( fifo_reset ),
    .in         ( uart_rx_data ),
    .in_clk     ( clk ),
    .in_strobe  ( uart_rx_strobe ),
    .in_enable  ( 1'b0 ),
    .out_clk    ( clk ),
    .out        ( mcu_data ),
    .out_strobe ( mcu_strobe ),
    .out_enable ( 1'b0 ),
    .space      ( rx_space ),
    .empty      ( ),
    .used       ( rx_used ),
    .full       ( )
);

assign uart_tx_available = { 4'd0, tx_used };
assign uart_rx_space     = { 4'd0, rx_space };
assign mcu_available     = enable ? { 4'd0, rx_used } : 8'd0;
assign mcu_space         = enable ? { 4'd0, tx_space } : 8'd255;

endmodule
