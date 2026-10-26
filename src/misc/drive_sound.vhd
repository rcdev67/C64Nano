---------------------------------------------------------------------------------
-- drive_sound.vhd
--
-- 1541 drive sound for the Tang Nano 20k.
--
-- Derived from floppy_sound.vhd of the 1541 Ultimate firmware by Gideon
-- Zweijtzer (https://github.com/GideonZ/1541ultimate, GPL-3.0). The two voices,
-- the sample set it reads and the 16:1 weighting of the head against the motor
-- are his; this core is GPL-3.0 as well. What is changed here is the way to
-- memory, the sample clock and the volume -- see below.
--
-- The samples are NOT held in block RAM. On this device that is not a choice:
-- the C64 core fills 42 of the 46 block RAMs, and the four that are left are
-- half a second of audio. They live in the SDRAM instead, 46336 bytes of
-- 8 bit signed PCM at 22050 Hz, and are read one byte at a time -- at most two
-- bytes per sample, so 44100 reads per second.
--
-- The way in is the DMA slot the C64 bus logic already produces. ext_cycle is
-- asserted during CYCLE_DMA0..DMA3, roughly a million times a second, and is
-- otherwise used only by the REU. So the cost of a read is nothing that the
-- machine would notice, and when the REU does want the slot it keeps it: the
-- request simply waits for the next window, which is 44100 to a million away.
--
-- The arbitration itself is deliberately NOT in here. This module asks with
-- ram_req and is told by ram_grant when it is being served, so the priority
-- rule stays where it belongs -- in the top level, next to the other users of
-- that port. The next machine will have a different rule and the same player.
--
-- The volume multiply is one signed 13x9 product, so that GowinSynthesis maps
-- it to a MULT18X18 rather than to logic. That matters here: the core sits at
-- 100% CLS occupancy, where a LUT multiplier would not place, while 17 of the
-- 24 DSP blocks are idle.
---------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity drive_sound is
generic (
    -- where the set was loaded to in the SDRAM
    SND_ADDR       : unsigned(22 downto 0) := 23x"0020000";
    -- How long after ram_grant the byte is on ram_din, counted in clk cycles.
    -- The byte is latched in the cycle where the counter reads 1, which is
    -- READ_LATENCY+1 cycles after the grant -- so 3 puts it on the fourth cycle
    -- of the DMA window, exactly where reu.v takes its own byte. That count and
    -- not the controller's dout_valid, because the SDRAM is clocked at 63 MHz
    -- and a one cycle pulse of its own domain cannot be sampled reliably from
    -- this one.
    READ_LATENCY   : integer := 3;
    -- offsets within the set, from mm_drive.vhd of the 1541 Ultimate
    motor_hum_addr : unsigned(15 downto 0) := x"0000";
    flop_slip_addr : unsigned(15 downto 0) := x"1200";
    track_in_addr  : unsigned(15 downto 0) := x"2400";
    track_out_addr : unsigned(15 downto 0) := x"2C00";
    head_bang_addr : unsigned(15 downto 0) := x"3480";
    insert_addr    : unsigned(15 downto 0) := x"3D00";
    remove_addr    : unsigned(15 downto 0) := x"7D00";
    motor_len      : integer := 4410;              -- 200 ms, the looped length
    track_in_len   : unsigned(15 downto 0) := x"0800";
    track_out_len  : unsigned(15 downto 0) := x"0880";
    head_bang_len  : unsigned(15 downto 0) := x"0880";
    insert_len     : unsigned(15 downto 0) := x"4000";
    remove_len     : unsigned(15 downto 0) := x"3800"
    );
port (
    clk          : in  std_logic;
    reset        : in  std_logic;

    -- clk cycles per sample minus one; PAL and NTSC run at different clocks,
    -- so this is a signal and not a constant
    tick_div     : in  unsigned(10 downto 0);

    -- the drive, as levels: empty drive hums, a disk in it slips
    en_hum       : in  std_logic;
    en_slip      : in  std_logic;

    -- one clk wide pulses
    do_trk_in    : in  std_logic;
    do_trk_out   : in  std_logic;
    do_head_bang : in  std_logic;
    do_insert    : in  std_logic := '0';
    do_remove    : in  std_logic := '0';

    volume       : in  unsigned(1 downto 0);   -- 0 = off, 3 = loudest

    -- SDRAM, one byte at a time through somebody else's time slot
    ram_req      : out std_logic;
    ram_addr     : out unsigned(22 downto 0);
    ram_grant    : in  std_logic;
    ram_din      : in  unsigned(7 downto 0);

    sample_out   : out signed(15 downto 0) := (others => '0')
    );
end drive_sound;

architecture rtl of drive_sound is

    type t_voice_state is (v_idle, v_play);
    type t_state is (st_idle, st_v1_wait, st_v2_sel, st_v2_wait);

    signal state        : t_state := st_idle;
    signal voice1       : t_voice_state := v_idle;

    -- 16 bits, not 14: the insert sound is 16384 samples long and would be
    -- truncated to nothing by a counter that stops at 16383
    signal voice1_cnt   : unsigned(15 downto 0) := (others => '0');
    signal voice1_addr  : unsigned(15 downto 0) := (others => '0');
    signal voice2_cnt   : unsigned(15 downto 0) := (others => '0');

    signal addr_i       : unsigned(15 downto 0) := (others => '0');
    signal rd_cnt       : unsigned(3 downto 0) := (others => '0');

    signal tick_cnt     : unsigned(10 downto 0) := (others => '0');
    signal sample_tick  : std_logic := '0';

    signal motor_sample : signed(7 downto 0) := (others => '0');
    signal head_sample  : signed(7 downto 0) := (others => '0');

    signal mix          : signed(12 downto 0);
    signal gain         : signed(8 downto 0);
    signal scaled       : signed(21 downto 0) := (others => '0');

begin

    ram_addr <= SND_ADDR + resize(addr_i, SND_ADDR'length);

    -- The head is 16 times the motor. That is Gideon's weighting, and the
    -- recordings bear it out: the hum peaks at +-29, the head against the end
    -- stop at -128. A 1541 seeking to track 1 is what the machine sounds like
    -- from the next room; the hum is the background to it.
    mix <= resize(motor_sample, mix'length)
           + shift_left(resize(head_sample, mix'length), 4);

    gain <= to_signed(0, gain'length)   when volume = "00" else
            to_signed(64, gain'length)  when volume = "01" else
            to_signed(128, gain'length) when volume = "10" else
            to_signed(255, gain'length);

    -- one multiply, one register: at 22 kHz a cycle of latency is nothing, and
    -- the register is what lets the tool retime the product into a DSP block
    process(clk)
    begin
        if rising_edge(clk) then
            scaled     <= mix * gain;
            sample_out <= scaled(20 downto 5);
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then

            sample_tick <= '0';
            if tick_cnt = 0 then
                tick_cnt    <= tick_div;
                sample_tick <= '1';
            else
                tick_cnt <= tick_cnt - 1;
            end if;

            case state is

            when st_idle =>
                if sample_tick = '1' then
                    -- Switched off means switched off: no reads at all, so the
                    -- DMA slot is left alone when nobody is listening.
                    if volume = "00" then
                        voice1       <= v_idle;
                        motor_sample <= (others => '0');
                        head_sample  <= (others => '0');
                    elsif voice1 = v_play and voice1_cnt /= 0 then
                        addr_i  <= voice1_addr;
                        ram_req <= '1';
                        rd_cnt  <= (others => '0');
                        state   <= st_v1_wait;
                    else
                        voice1      <= v_idle;
                        head_sample <= (others => '0');
                        state       <= st_v2_sel;
                    end if;
                end if;

            -- ram_req stays asserted across the count. That is safe only
            -- because the count finishes inside the same window: ext_cycle is
            -- CYCLE_DMA0..DMA3, four clk cycles, and the byte is taken on the
            -- fourth. A platform whose window is shorter than READ_LATENCY+1
            -- would be granted twice for one read and has to drop ram_req on
            -- the grant instead.
            when st_v1_wait =>
                if ram_grant = '1' then
                    rd_cnt <= to_unsigned(READ_LATENCY, rd_cnt'length);
                elsif rd_cnt /= 0 then
                    rd_cnt <= rd_cnt - 1;
                    if rd_cnt = 1 then
                        head_sample <= signed(ram_din);
                        voice1_cnt  <= voice1_cnt - 1;
                        voice1_addr <= voice1_addr + 1;
                        ram_req     <= '0';
                        state       <= st_v2_sel;
                    end if;
                end if;

            when st_v2_sel =>
                if en_hum = '1' then
                    addr_i  <= motor_hum_addr + voice2_cnt;
                    ram_req <= '1';
                    rd_cnt  <= (others => '0');
                    state   <= st_v2_wait;
                elsif en_slip = '1' then
                    addr_i  <= flop_slip_addr + voice2_cnt;
                    ram_req <= '1';
                    rd_cnt  <= (others => '0');
                    state   <= st_v2_wait;
                else
                    motor_sample <= (others => '0');
                    voice2_cnt   <= (others => '0');
                    state        <= st_idle;
                end if;

            when st_v2_wait =>
                if ram_grant = '1' then
                    rd_cnt <= to_unsigned(READ_LATENCY, rd_cnt'length);
                elsif rd_cnt /= 0 then
                    rd_cnt <= rd_cnt - 1;
                    if rd_cnt = 1 then
                        motor_sample <= signed(ram_din);
                        ram_req      <= '0';
                        state        <= st_idle;
                        if voice2_cnt = motor_len - 1 then
                            voice2_cnt <= (others => '0');
                        else
                            voice2_cnt <= voice2_cnt + 1;
                        end if;
                    end if;
                end if;

            end case;

            -- A new one-shot always wins over the one playing. A seek is a run
            -- of steps a few milliseconds apart, so this is the normal case and
            -- not an exception: each step cuts off the one before it.
            if do_trk_out = '1' then
                voice1      <= v_play;
                voice1_cnt  <= track_out_len;
                voice1_addr <= track_out_addr;
            elsif do_trk_in = '1' then
                voice1      <= v_play;
                voice1_cnt  <= track_in_len;
                voice1_addr <= track_in_addr;
            elsif do_head_bang = '1' then
                voice1      <= v_play;
                voice1_cnt  <= head_bang_len;
                voice1_addr <= head_bang_addr;
            elsif do_insert = '1' then
                voice1      <= v_play;
                voice1_cnt  <= insert_len;
                voice1_addr <= insert_addr;
            elsif do_remove = '1' then
                voice1      <= v_play;
                voice1_cnt  <= remove_len;
                voice1_addr <= remove_addr;
            end if;

            if reset = '1' then
                state        <= st_idle;
                voice1       <= v_idle;
                voice1_cnt   <= (others => '0');
                voice1_addr  <= (others => '0');
                voice2_cnt   <= (others => '0');
                rd_cnt       <= (others => '0');
                tick_cnt     <= (others => '0');
                ram_req      <= '0';
                motor_sample <= (others => '0');
                head_sample  <= (others => '0');
            end if;

        end if;
    end process;

end rtl;
