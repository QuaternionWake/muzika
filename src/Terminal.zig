const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log;
const time = std.time;

const input = @import("input.zig");

const Terminal = @This();

const tui_height = 4;
const y_padding = 1;
const x_padding = 2;

io: Io,
ally: Allocator,

stdout_file: Io.File,
stdout_buf: []u8,
stdout: Io.File.Writer,

stdin_file: Io.File,
stdin_buf: []u8,
stdin: Io.File.Reader,

old_termios: ?std.posix.termios,
first_draw: bool,

tui: Tui,

pub fn init(io: Io, ally: Allocator) !Terminal {
    const stdout_file = Io.File.stdout();
    const stdout_buf = try ally.alloc(u8, 1024);
    errdefer ally.free(stdout_buf);
    const stdout = stdout_file.writer(io, stdout_buf);

    const stdin_file = Io.File.stdin();
    const stdin_buf = try ally.alloc(u8, 1024);
    errdefer ally.free(stdin_buf);
    const stdin = stdin_file.reader(io, stdin_buf);

    var size = getSize(stdout_file);
    size.y = tui_height;

    const tui: Tui = try .init(ally, size);
    errdefer tui.deinit(ally);

    var self: Terminal = .{
        .io = io,
        .ally = ally,

        .stdout_file = stdout_file,
        .stdout_buf = stdout_buf,
        .stdout = stdout,

        .stdin_file = stdin_file,
        .stdin_buf = stdin_buf,
        .stdin = stdin,

        .old_termios = null,
        .first_draw = true,

        .tui = tui,
    };
    self.enterRawMode();
    return self;
}

pub fn deinit(self: *Terminal) void {
    self.exitRawMode();
    self.ally.free(self.stdout_buf);
    self.ally.free(self.stdin_buf);
    self.tui.deinit(self.ally);
}

pub fn getInput(self: *Terminal) ?input.KeyboardKey {
    if (self.stdin.interface.bufferedLen() == 0) {
        if (pollFd(self.stdin_file.handle)) {
            self.stdin.interface.fill(1) catch |err| switch (err) {
                error.ReadFailed => log.err("Failed to read from stdin", .{}),
                error.EndOfStream => {},
            };
        }
    }
    if (self.stdin.interface.seek < self.stdin.interface.end) {
        const key, const consumed = input.get(self.stdin.interface.buffered());
        self.stdin.interface.toss(consumed);
        return key;
    }
    return null;
}

pub fn draw(self: *Terminal) !void {
    const size = getSize(self.stdout_file);
    if (self.tui.width != size.x) {
        // TODO: make this not suck
        self.tui.deinit(self.ally);
        self.tui = try .init(self.ally, .{ .x = size.x, .y = self.tui.height });
    }
    if (!self.first_draw) {
        // Go to top right corner
        try self.stdout.interface.print("\x1b[{d}A\r", .{self.tui.height -| 1});
    }

    for (self.tui.pixels) |pixel| {
        try self.stdout.interface.printUnicodeCodepoint(pixel.char);
    }
    try self.stdout.interface.flush();
    @memset(self.tui.pixels, .{});

    self.first_draw = false;
}

const Tui = struct {
    width: u16,
    height: u16,
    pixels: []TuiPixel,

    fn init(ally: Allocator, size: Vec2) !Tui {
        const buf = try ally.alloc(TuiPixel, size.x * size.y);
        @memset(buf, .{});
        return .{
            .width = size.x,
            .height = size.y,
            .pixels = buf,
        };
    }

    fn deinit(self: *Tui, ally: Allocator) void {
        ally.free(self.pixels);
        self.pixels = &.{};
    }

    fn getPixelRef(self: *Tui, x: u16, y: u16) ?[*]TuiPixel {
        if (x >= self.width or y >= self.height) return null;
        const offset = @as(usize, x) + @as(usize, y) * @as(usize, self.width);
        return self.pixels[offset..].ptr;
    }

    pub fn drawTextLine(self: *Tui, text: std.unicode.Utf8View, pos: Vec2, max_width: u16) void {
        const pixels = blk: {
            const pixel = self.getPixelRef(pos.x, pos.y) orelse return;
            const max_width_ = @min(max_width, self.width -| pos.x);
            const slice = pixel[0..max_width_];
            if (slice.len == 0) return;
            break :blk slice;
        };

        var iter = text.iterator();
        for (pixels) |*pixel| {
            pixel.char = iter.nextCodepoint() orelse break;
        } else {
            pixels[pixels.len - 1].char = '…';
        }
    }

    pub fn drawTitle(self: *Tui, title: std.unicode.Utf8View) void {
        self.drawTextLine(title, .{ .x = x_padding, .y = y_padding }, self.width - 2 * x_padding);
    }

    pub fn drawBottomBar(self: *Tui, played: Io.Duration, duration: Io.Duration) void {
        var pixels = blk: {
            const pixel = self.getPixelRef(x_padding, self.height -| (y_padding + 1)) orelse return;
            const slice = pixel[0..self.width -| 2 * x_padding];
            if (slice.len == 0) return;
            break :blk slice;
        };

        const played_seconds = played.toSeconds();
        const duration_seconds = duration.toSeconds();

        const times_played = .{
            .hours = @divTrunc(played_seconds, std.time.s_per_hour),
            .mins = @as(u64, @intCast(@divFloor(@mod(played_seconds, std.time.s_per_hour), std.time.s_per_min))),
            .secs = @as(u64, @intCast(@mod(played_seconds, std.time.s_per_min))),
        };

        const times_duration = .{
            .hours = @divTrunc(duration_seconds, std.time.s_per_hour),
            .mins = @as(u64, @intCast(@divFloor(@mod(duration_seconds, std.time.s_per_hour), std.time.s_per_min))),
            .secs = @as(u64, @intCast(@mod(duration_seconds, std.time.s_per_min))),
        };

        // max len of i64 is 20 chars (sign + 19 digits)
        // that plus 2 two digit numbers and 2 colons plus trailing/leading space => 27
        var buf_played: [32]u8 = undefined;
        const str_played = blk: {
            var writer: Io.Writer = .fixed(&buf_played);
            if (times_played.hours != 0) {
                writer.print("{d}:{d:02}:{d:02}", times_played) catch unreachable;
            } else {
                writer.print("{d}:{d:02}", .{ times_played.mins, times_played.secs }) catch unreachable;
            }
            break :blk buf_played[0..writer.end];
        };

        var buf_duration: [32]u8 = undefined;
        const str_duration = blk: {
            var writer: Io.Writer = .fixed(&buf_duration);
            if (times_duration.hours != 0) {
                writer.print("{d}:{d:02}:{d:02}", times_duration) catch unreachable;
            } else {
                writer.print("{d}:{d:02}", .{ times_duration.mins, times_duration.secs }) catch unreachable;
            }
            break :blk buf_duration[0..writer.end];
        };

        // has space for at least 5 notches on the progress bar + ends + spaces
        if (pixels.len > str_played.len + str_duration.len + 7 + 2) {
            // [played] [progress bar] [duration]
            // 0:33 [####          ] 4:52
            const progress_width = pixels.len - str_played.len - str_duration.len - 2;
            const ratio_played = @min(1, @as(f32, @floatFromInt(played.nanoseconds)) / @as(f32, @floatFromInt(duration.nanoseconds)));
            const num_filled: usize = @round(ratio_played * @as(f32, @floatFromInt(progress_width)));

            // played
            writeTuiPixelString(pixels, str_played);
            pixels = pixels[str_played.len + 1 ..];

            // progress bar
            pixels[0].char = '[';
            @memset(pixels[1..][0..num_filled], .{ .char = '#' });
            pixels[progress_width - 1].char = ']';
            pixels = pixels[progress_width + 1 ..];

            // duration
            writeTuiPixelString(pixels, str_duration);
            pixels = pixels[str_duration.len..];
        } else if (pixels.len > str_played.len + str_duration.len + 3) {
            // [played] / [duration]
            // 0:33 / 4:52

            // played
            writeTuiPixelString(pixels, str_played);
            pixels = pixels[str_played.len..];

            pixels[0].char = '/';
            pixels = pixels[1..];

            // duration
            writeTuiPixelString(pixels, str_duration);
            pixels = pixels[str_duration.len..];
        } else if (pixels.len > str_played.len) {
            // [played]
            // 0:33
            writeTuiPixelString(pixels, str_played);
            pixels = pixels[str_played.len..];
        }
    }
};

const TuiPixel = struct {
    char: u21 = ' ',
};

fn writeTuiPixelString(pixels: []TuiPixel, string: []const u8) void {
    for (pixels[0..string.len], string[0..string.len]) |*pixel, char| {
        pixel.char = char;
    }
}

fn getSize(stdout: Io.File) Vec2 {
    var size: std.posix.winsize = undefined;
    // TODO: figure out what this returns
    _ = std.os.linux.ioctl(stdout.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&size));
    return .{ .x = size.col, .y = size.row };
}

const Vec2 = struct {
    x: u16,
    y: u16,
};

fn enterRawMode(self: *Terminal) void {
    if (std.posix.tcgetattr(self.stdin_file.handle)) |termios| {
        self.old_termios = termios;
        var t = termios;

        t.lflag.ICANON = false; // get input byte-by-byte
        t.lflag.ECHO = false; // disable echoing pressed characters
        t.lflag.ISIG = false; // don't generate signals on ctrl+c and co

        std.posix.tcsetattr(self.stdin_file.handle, .NOW, t) catch |err|
            log.err("Failed to set termios state: {t}", .{err});
    } else |err| {
        log.err("Failed to get termios state: {t}", .{err});
    }

    self.stdout_file.writeStreamingAll(self.io, "\x1b[?25l") catch |err| {
        log.err("Failed to write to stdout: {t}", .{err});
    };
}

fn exitRawMode(self: Terminal) void {
    if (self.old_termios) |ot| std.posix.tcsetattr(self.stdin_file.handle, .NOW, ot) catch |err|
        log.err("Failed to restore terminal state: {t}", .{err});

    self.stdout_file.writeStreamingAll(self.io, "\x1b[?25h") catch |err|
        log.err("Failed to write to stdout: {t}", .{err});
}

fn pollFd(fd: std.posix.fd_t) bool {
    var pollfd: std.posix.pollfd = .{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    };
    _ = std.posix.poll(@ptrCast(&pollfd), 0) catch return false;
    return pollfd.revents & std.posix.POLL.IN != 0;
}
