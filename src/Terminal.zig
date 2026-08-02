const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log;
const time = std.time;

const input = @import("input.zig");
const Track = @import("Player.zig").Track;
const Framebuffer = @import("Framebuffer.zig");
const tui = @import("tui.zig");

const Terminal = @This();

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

framebuffer: Framebuffer,

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
    size.height = tui.tui_height;

    const framebuffer: Framebuffer = try .init(ally, size.width, size.height);
    errdefer framebuffer.deinit(ally);

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

        .framebuffer = framebuffer,
    };
    self.enterRawMode();
    return self;
}

pub fn deinit(self: *Terminal) void {
    self.exitRawMode();
    self.ally.free(self.stdout_buf);
    self.ally.free(self.stdin_buf);
    self.framebuffer.deinit(self.ally);
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
    if (self.framebuffer.width != size.width) {
        // TODO: make this not suck
        self.framebuffer.deinit(self.ally);
        self.framebuffer = try .init(self.ally, size.width, tui.tui_height);
    }
    if (!self.first_draw) {
        // Go to top right corner
        try self.stdout.interface.print("\x1b[{d}A\r", .{self.framebuffer.height -| 1});
    }

    for (self.framebuffer.pixels) |pixel| {
        try self.stdout.interface.printUnicodeCodepoint(pixel.char);
    }
    try self.stdout.interface.flush();
    @memset(self.framebuffer.pixels, .{});

    self.first_draw = false;
}

fn getSize(stdout: Io.File) Size {
    var size: std.posix.winsize = undefined;
    // TODO: figure out what this returns
    _ = std.os.linux.ioctl(stdout.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&size));
    return .{ .width = size.col, .height = size.row };
}

const Size = struct {
    width: u16,
    height: u16,
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
