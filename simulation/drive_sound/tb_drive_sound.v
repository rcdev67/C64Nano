`timescale 1ns/1ns
// Testbench: drives drive_sound.v with a fixed sequence of motor, disk and step
// events, and writes snd after every sample tick to tb_out.txt. tick_div is 3,
// so a tick every 4 clocks: the player's behaviour per tick does not depend on
// the divider, only its speed in real time does.
module tb;
reg clk = 0;
always #5 clk = ~clk;

reg resetn = 0;
reg motor_on = 0, disk_in = 0;
reg step_in = 0, step_out = 0, head_bang = 0;
reg [1:0] volume = 2'd3;
wire signed [15:0] snd;

drive_sound dut (
    .clk(clk), .resetn(resetn), .tick_div(12'd3),
    .motor_on(motor_on), .disk_in(disk_in),
    .step_in(step_in), .step_out(step_out), .head_bang(head_bang),
    .volume(volume), .snd(snd));

integer f, n;
initial begin
    f = $fopen("tb_out.txt", "w");
    #100 resetn = 1;
end

// At every edge where the player acts on a tick, capture what it sees: the
// inputs and the latched step flags, read before the edge updates them. One
// half clock later, log them together with the new snd. The model then works
// from exactly these inputs, so nothing depends on aligning two timelines.
reg c_motor, c_disk, c_in, c_out, c_bang, c_valid = 0;
always @(posedge clk) begin
    c_valid <= resetn && dut.tick;
    c_motor <= motor_on;   c_disk <= disk_in;
    c_in    <= dut.st_in_seen;  c_out <= dut.st_out_seen;  c_bang <= dut.bang_seen;
end
always @(negedge clk) if(c_valid)
    $fdisplay(f, "%0d %0d %0d %0d %0d %0d", c_motor, c_disk, c_in, c_out, c_bang, snd);

// stimulus, in ticks; pulses are placed two clocks after a tick, never on one
task pulse_in;   begin @(negedge clk); @(negedge clk); step_in   = 1; @(negedge clk); step_in   = 0; end endtask
task pulse_out;  begin @(negedge clk); @(negedge clk); step_out  = 1; @(negedge clk); step_out  = 0; end endtask
task pulse_bang; begin @(negedge clk); @(negedge clk); head_bang = 1; @(negedge clk); head_bang = 0; end endtask
task wait_ticks(input integer t); integer k; begin for(k = 0; k < t; k = k + 1) @(posedge dut.tick); end endtask

// Real durations at 11025 ticks a second, so the log doubles as something to
// listen to: what the board has to sound like.
initial begin
    @(posedge resetn);
    wait_ticks(3300);                       // 0.3 s quiet
    motor_on = 1;   wait_ticks(16538);      // 1.5 s empty drive: the hum
    disk_in = 1;    wait_ticks(22050);      // 2.0 s a disk in: the slip
    pulse_in;       wait_ticks(4410);       // single step in, 0.4 s
    pulse_out;      wait_ticks(4410);       // single step out
    pulse_bang;     wait_ticks(6615);       // head against the stop, 0.6 s
    for(n = 0; n < 20; n = n + 1) begin     // a seek: 20 half tracks, 12 ms apart
        pulse_in;   wait_ticks(132);
    end
    wait_ticks(5513);                       // 0.5 s running on
    motor_on = 0;   wait_ticks(5513);       // motor off: tail and fade
    $fclose(f);
    $finish;
end
endmodule
