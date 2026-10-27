//
// drive_sound.v
//
// 1541 drive sound for the Tang Nano 20k.
//
// The samples are the drive sound set of the 1541 Ultimate firmware by Gideon
// Zweijtzer (https://github.com/GideonZ/1541ultimate, GPL-3.0), recorded from a
// real 1541 -- see sounds/README.md. This core is GPL-3.0 as well. The
// structure is our own Atari ST player (MiSTeryNano, src/misc/drive_sound.v),
// which has been running on this toolchain since September; what it knows about
// latching step pulses, bridging the gaps of a load and keeping the output off
// the critical path is all hard won and kept here.
//
// The samples live in the bitstream, not in the SDRAM. A first attempt loaded
// them from the SD card into the SDRAM and read them back through the DMA time
// slot; it read noise, for a reason never found, and the transport is a part
// this design does not need. The core left four of its 46 block RAMs free, and
// the set fits them exactly:
//
//   drive_motor.hex  hum | slip, 2048 + 2048  two loops       2 blocks
//   drive_head.hex   step in | step out | bang one-shots      2 blocks
//
// Two loops, because they are not interchangeable. The original player picks
// the hum when the drive runs empty and the slipping sound when a disk is in --
// the disk rubs against the liner of its sleeve -- and a disk is always in while
// something loads. 2048 samples each is 186 ms at 11025 Hz, cut from 200 ms with
// the remainder crossfaded into the start so the seam does not click. Being a
// power of two, the loop counter wraps by itself: there is no comparison here
// that could be wrong, which matters after an evening spent suspecting one.
//
// Levels are set from the measured peaks after resampling. At the OSD's "Loud"
// step, of 32767:
//
//   head against the end stop  peak 103  ->  about 22700
//   step out / step in          32 / 26  ->  about 20500 / 20800
//   slip, a disk in the drive         94  ->  about  9400
//   hum, the drive running empty      26  ->  about  2600
//
// "Normal", the default, is half of that. The worst case is the bang landing on
// a slip peak of the same sign, 32100, still below the clamp; the simulation
// runs at "Loud" and checks it.
//
// How they got here, because each step was a finding on the board. The first
// levels held only at "Loud", and the default halved them. Then, at "Loud" with
// the monitor at full volume, it was still too quiet -- the head bang, by far the
// loudest sound, had taken all the headroom. It is now 2 dB down and stays the
// loudest; the steps went up 1 to 2 dB and the running slip, which is what one
// mostly hears, 5.4 dB. The slip stays below the steps, as on a real 1541.
//
// And then a whole load passed without a single clack being heard: the step
// peaks were 1.4 times the running slip, and a short thud that little above a
// steady noise is simply lost in it. The head channel got 6 dB more through
// HEAD_SHIFT, the steps now stand at about twice the slip, and the bang, which
// had the headroom to itself, came down to stay just the loudest.
//
// Both loops share one gain on purpose. They are on the same channel, and with
// one gain the recording's own relation between them is kept: an empty drive is
// quiet, a loaded one is clearly there.
//
// A 1541 seek is a run of distinct clacks, not a buzz, so a new step simply
// restarts the one-shot. That is why there is no continuous seek sound here as
// there is in the ST player: a 5.25" stepper does not produce one.
//
module drive_sound #(
    parameter integer LOOP_BITS     = 11,     // 2048 samples per loop
    parameter integer STEP_IN_LEN   = 1024,   // head_rom: 0 .. STEP_IN_LEN-1
    parameter integer STEP_OUT_OFF  = 1024,
    parameter integer STEP_OUT_LEN  = 1088,
    parameter integer BANG_OFF      = 2112,
    parameter integer BANG_LEN      = 1088,
    parameter integer HEAD_LEN      = 3200,
    parameter [7:0]   MOTOR_GAIN    = 8'd50,  // both loops, see above
    parameter [7:0]   STEP_IN_GAIN  = 8'd200,
    parameter [7:0]   STEP_OUT_GAIN = 8'd160,
    parameter [7:0]   BANG_GAIN     = 8'd55,
    parameter integer HEAD_SHIFT    = 9,      // the head channel's extra 6 dB
    parameter integer OUT_SHIFT     = 7,
    // 150 ms of motor tail in samples, to bridge the gaps of a load
    parameter integer MOTOR_TAIL    = 1654
) (
    input                     clk,
    input                     resetn,

    // clk cycles per sample minus one. A signal and not a constant because the
    // core runs at 31.5 MHz for PAL and 32.94 for NTSC.
    input              [11:0] tick_div,

    input                     motor_on,    // level, the spindle is turning
    input                     disk_in,     // level, a disk is mounted
    input                     step_in,     // one clk pulse per half track
    input                     step_out,
    input                     head_bang,   // stepper pulses against the stop

    input               [1:0] volume,      // 0 = off, 3 = loudest

    output signed      [15:0] snd
);

// ---------------------------------------------------------------- samples --
reg signed [7:0] motor_rom [0:(2<<LOOP_BITS)-1];
reg signed [7:0] head_rom  [0:HEAD_LEN-1];
initial begin
    $readmemh("../../misc/drive_motor.hex", motor_rom);
    $readmemh("../../misc/drive_head.hex",  head_rom);
end

// ------------------------------------------------------------ sample tick --
reg [11:0] tick_cnt;
reg        tick;
always @(posedge clk) begin
    if(!resetn) begin
        tick_cnt <= 12'd0;
        tick     <= 1'b0;
    end else if(tick_cnt == 12'd0) begin
        tick_cnt <= tick_div;
        tick     <= 1'b1;
    end else begin
        tick_cnt <= tick_cnt - 12'd1;
        tick     <= 1'b0;
    end
end

// ------------------------------------------------------- step retriggering --
// The step inputs are one clk wide, and the ticks are 90us apart. Without
// latching them, most steps are simply never seen. The clears come first so
// that a pulse landing on a tick is kept for the next one rather than lost.
reg st_in_seen, st_out_seen, bang_seen;
always @(posedge clk) begin
    if(!resetn) begin
        st_in_seen  <= 1'b0;
        st_out_seen <= 1'b0;
        bang_seen   <= 1'b0;
    end else begin
        if(tick) begin
            st_in_seen  <= 1'b0;
            st_out_seen <= 1'b0;
            bang_seen   <= 1'b0;
        end
        if(step_in)   st_in_seen  <= 1'b1;
        if(step_out)  st_out_seen <= 1'b1;
        if(head_bang) bang_seen   <= 1'b1;
    end
end

// ---------------------------------------------------------------- envelope --
// Only the motor has one. It fades in and out over about 23ms, which keeps the
// spindle from starting with a click, and the tail bridges the moments when the
// drive drops the motor between sectors. The one-shots need no envelope: the
// recordings already end quietly.
reg [14:0] motor_hold;
reg  [7:0] motor_env;
always @(posedge clk) begin
    if(!resetn) begin
        motor_hold <= 15'd0;
        motor_env  <= 8'd0;
    end else if(tick) begin
        if(motor_on)             motor_hold <= MOTOR_TAIL[14:0];
        else if(motor_hold != 0) motor_hold <= motor_hold - 15'd1;

        if(motor_hold != 0) begin
            if(motor_env < 8'd255) motor_env <= motor_env + 8'd1;
        end else if(motor_env != 8'd0)
            motor_env <= motor_env - 8'd1;
    end
end

// -------------------------------------------------------- sample playback --
reg [LOOP_BITS-1:0] motor_pos;     // wraps by itself
reg          [11:0] head_pos;
reg           [1:0] head_snd;      // 0 = step in, 1 = step out, 2 = bang
reg                 head_active;
reg signed    [7:0] motor_s, head_s;

always @(posedge clk) begin
    if(!resetn) begin
        motor_pos   <= {LOOP_BITS{1'b0}};
        head_pos    <= 12'd0;
        head_snd    <= 2'd0;
        head_active <= 1'b0;
        motor_s     <= 8'sd0;
        head_s      <= 8'sd0;
    end else if(tick) begin
        // Read unconditionally, so this infers a block RAM rather than logic.
        // An idle head channel is silenced through its gain, not by not reading.
        // The upper address bit picks the loop: hum below, slip above.
        motor_s <= motor_rom[{disk_in, motor_pos}];
        head_s  <= head_rom[head_pos];

        // ---- motor: loop, restarting from the top when it starts turning --
        if(motor_hold != 0) motor_pos <= motor_pos + 1'b1;
        else                motor_pos <= {LOOP_BITS{1'b0}};

        // ---- head: one shot, and a new step restarts it -----------------
        if(bang_seen) begin
            head_pos <= BANG_OFF[11:0];     head_snd <= 2'd2; head_active <= 1'b1;
        end else if(st_out_seen) begin
            head_pos <= STEP_OUT_OFF[11:0]; head_snd <= 2'd1; head_active <= 1'b1;
        end else if(st_in_seen) begin
            head_pos <= 12'd0;              head_snd <= 2'd0; head_active <= 1'b1;
        end else if(head_active) begin
            case(head_snd)
            2'd0: if(head_pos == STEP_IN_LEN[11:0] - 12'd1)
                      head_active <= 1'b0;
                  else head_pos <= head_pos + 12'd1;
            2'd1: if(head_pos == STEP_OUT_OFF[11:0] + STEP_OUT_LEN[11:0] - 12'd1)
                      head_active <= 1'b0;
                  else head_pos <= head_pos + 12'd1;
            default: if(head_pos == BANG_OFF[11:0] + BANG_LEN[11:0] - 12'd1)
                      head_active <= 1'b0;
                  else head_pos <= head_pos + 12'd1;
            endcase
        end
    end
end

// ---------------------------------------------------------------- mixing ---
wire [7:0] h_gain = !head_active     ? 8'd0          :
                    (head_snd == 0)  ? STEP_IN_GAIN  :
                    (head_snd == 1)  ? STEP_OUT_GAIN : BANG_GAIN;

wire signed [25:0] m_mul = motor_s * $signed({1'b0, MOTOR_GAIN}) * $signed({1'b0, motor_env});
wire signed [25:0] h_mul = (head_s * $signed({1'b0, h_gain})) <<< HEAD_SHIFT;
wire signed [25:0] sum   = (m_mul + h_mul) >>> OUT_SHIFT;

// volume 0 mutes entirely, so it can be switched off from the OSD
wire signed [25:0] scaled = (volume == 2'd0) ? 26'sd0 :
                            (volume == 2'd1) ? (sum >>> 2) :
                            (volume == 2'd2) ? (sum >>> 1) : sum;

// The measured peaks stay well inside 16 bits, but clamp rather than wrap: a
// wrap is a click, and the mixer above us saturates only its own sum.
wire signed [25:0] lim = (scaled >  26'sd32767) ?  26'sd32767 :
                         (scaled < -26'sd32768) ? -26'sd32768 : scaled;

// Registered output. The value only changes on the sample tick, but without
// this register the multipliers, the adder and the volume mux sit on a
// combinational path running into the HDMI audio packetizer -- on the ST that
// was the worst timing path of the whole core.
reg signed [15:0] snd_r;
always @(posedge clk) if(tick) snd_r <= lim[15:0];
assign snd = snd_r;

endmodule
