const std = @import("std");
const log = std.log;
const posix = std.posix;

var old_termios: ?posix.termios = null;

pub fn enter(io: std.Io) void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    if (posix.tcgetattr(stdin.handle)) |termios| {
        old_termios = termios;
        var t = termios;

        t.lflag.ICANON = false; // get input byte-by-byte
        t.lflag.ECHO = false; // disable echoing pressed characters
        t.lflag.ISIG = false; // don't generate signals on ctrl+c and co

        posix.tcsetattr(stdin.handle, .NOW, t) catch |err|
            log.err("Failed to set termios state: {t}", .{err});
    } else |err| {
        log.err("Failed to get termios state: {t}", .{err});
    }

    stdout.writeStreamingAll(io, "\x1b[?25l") catch |err| {
        log.err("Failed to write to stdout: {t}", .{err});
    };
}

pub fn exit(io: std.Io) void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    if (old_termios) |ot| posix.tcsetattr(stdin.handle, .NOW, ot) catch |err|
        log.err("Failed to restore terminal state: {t}", .{err});

    stdout.writeStreamingAll(io, "\x1b[?25h") catch |err|
        log.err("Failed to write to stdout: {t}", .{err});
}
