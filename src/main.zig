const std = @import("std");
const log = std.log;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Utf8View = std.unicode.Utf8View;

const sdl = @import("sdl");
const flac = @import("flac");

const raw_mode = @import("raw_mode.zig");
const input = @import("input.zig");
const Terminal = @import("Terminal.zig");
const Player = @import("Player.zig");

pub fn main(init: std.process.Init) !u8 {
    var stdout_buf: [1024]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch @panic("failed to flush stdout");

    var terminal: Terminal = try .init(init.io, init.gpa);
    defer terminal.deinit();

    var args_iter = init.minimal.args.iterate();
    const prog_name = args_iter.next().?;
    _ = prog_name;
    const path = args_iter.next();

    raw_mode.enter(init.io);
    defer raw_mode.exit(init.io);

    sdlInit() catch {
        log.err("Failied to initialize SDL: {s}", .{sdl.getError()});
        return error.SdlInitFailed;
    };
    defer sdlDeinit();

    var player = Player.init(init.io, init.gpa, path, init.environ_map) catch |err| {
        log.err("Failed to initialize player: {t}", .{err});
        return err;
    };
    defer player.deinit();

    player.playCurrentTrack() catch |err| {
        switch (err) {
            error.SdlError => log.err("Failed to initialize player: {s}", .{sdl.getError()}),
            else => log.err("Failed to initialize player: {t}", .{err}),
        }
        return err;
    };

    var should_quit = false;
    while (!should_quit) {
        player.play() catch |err| switch (err) {
            error.SdlError => log.err("Failed to initialize player: {s}", .{sdl.getError()}),
            else => log.err("Failed to initialize player: {t}", .{err}),
        };
        std.Io.sleep(init.io, .fromMilliseconds(10), .awake) catch unreachable;

        terminal.tui.drawCoverArt();
        terminal.tui.drawTrackList(player.tracks, player.current_track);
        const title_view = Utf8View.init(player.trackString(.title)) catch Utf8View.initComptime("???");
        const artist_view = Utf8View.init(player.trackString(.artist)) catch Utf8View.initComptime("???");
        const album_view = Utf8View.init(player.trackString(.album)) catch Utf8View.initComptime("???");
        terminal.tui.drawTitle(title_view);
        terminal.tui.drawArtistAlbum(artist_view, album_view);
        terminal.tui.drawBottomBar(player.played, player.duration);

        try terminal.draw();

        while (terminal.getInput()) |key| {
            switch (key) {
                .q => should_quit = true,
                .space => {
                    player.togglePause() catch
                        log.err("Failed to pause/resume audio stream device: {s}\n", .{sdl.getError()});
                },
                .right => {
                    player.seekRelative(5000) catch |err| switch (err) {
                        error.SdlError => log.err("Failed to clear stream: {s}", .{sdl.getError()}),
                        else => log.err("Failed to seek: {t}", .{err}),
                    };
                },
                .left => {
                    player.seekRelative(-5000) catch |err| switch (err) {
                        error.SdlError => log.err("Failed to clear stream: {s}", .{sdl.getError()}),
                        else => log.err("Failed to seek: {t}", .{err}),
                    };
                },
                .p => {
                    player.previousTrack() catch |err| switch (err) {
                        error.SdlError => log.err("Failed to play track: {s}", .{sdl.getError()}),
                        else => log.err("Failed to play track: {t}", .{err}),
                    };
                },
                .n => {
                    player.nextTrack() catch |err| switch (err) {
                        error.SdlError => log.err("Failed to play track: {s}", .{sdl.getError()}),
                        else => log.err("Failed to play track: {t}", .{err}),
                    };
                },
                .zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine => |value| {
                    const value_f32: f32 = @floatFromInt((@intFromEnum(value) - '0'));
                    player.seekPercent(value_f32 * 10) catch |err| switch (err) {
                        error.SdlError => log.err("Failed to clear stream: {s}", .{sdl.getError()}),
                        else => log.err("Failed to seek: {t}", .{err}),
                    };
                },
                else => {},
            }
        }
    }
    try stdout.writeByte('\n');

    return 0;
}

fn sdlInit() !void {
    sdl.setAppMetadataProperty(.name, "Muzika") catch
        log.err("Failed to set metadata property 'type': {s}", .{sdl.getError()});
    sdl.setAppMetadataProperty(.version, "0.0.0") catch
        log.err("Failed to set metadata property 'name': {s}", .{sdl.getError()});
    sdl.setAppMetadataProperty(.creator, "QuaternionWake") catch
        log.err("Failed to set metadata property 'version': {s}", .{sdl.getError()});
    sdl.setAppMetadataProperty(.type, "mediaplayer") catch
        log.err("Failed to set metadata property 'creator': {s}", .{sdl.getError()});

    try sdl.initSubSystem(.{ .audio = true });
}

fn sdlDeinit() void {
    sdl.quit();
}
