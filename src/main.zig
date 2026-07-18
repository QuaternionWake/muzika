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
    const path = args_iter.next() orelse {
        try stdout.print("Usage: {s} FILENAME\n", .{prog_name});
        return 1;
    };

    raw_mode.enter(init.io);
    defer raw_mode.exit(init.io);

    sdlInit() catch {
        log.err("Failied to initialize SDL: {s}", .{sdl.getError()});
        return error.SdlInitFailed;
    };
    defer sdlDeinit();

    const songs = getSongs(init.io, init.gpa, path) catch |err| {
        log.err("Failied to open file(s): {t}", .{err});
        return error.LoadSongsFailed;
    };
    defer {
        for (songs) |s| s.deinit(init.io, init.gpa);
        init.gpa.free(songs);
    }

    if (songs.len == 0) {
        log.err("No file(s) found", .{});
        return error.LoadSongsFailed;
    }

    var player = Player.init(init.io, init.gpa, path) catch |err| {
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

const Song = struct {
    title: []const u8,
    file: Io.File,

    fn deinit(self: Song, io: Io, ally: Allocator) void {
        ally.free(self.title);
        self.file.close(io);
    }
};

fn getSongs(io: Io, ally: Allocator, path: []const u8) ![]Song {
    const cwd = Io.Dir.cwd();
    const is_dir = blk: {
        const file = try cwd.openFile(io, path, .{ .allow_directory = true, .path_only = true });
        const stat = try file.stat(io);
        defer file.close(io);
        break :blk stat.kind == .directory;
    };

    var songs: std.ArrayList(Song) = .empty;
    errdefer {
        for (songs.items) |s| {
            ally.free(s.title);
            s.file.close(io);
        }
        songs.deinit(ally);
    }

    if (is_dir) {
        const dir = try cwd.openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var iter = dir.iterateAssumeFirstIteration();
        while (iter.next(io) catch null) |entry| {
            // TODO: symlinks?
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".flac")) {
                const file = dir.openFile(io, entry.name, .{}) catch continue;
                errdefer file.close(io);

                var buf: [1024]u8 = undefined;
                var reader = file.reader(io, &buf);

                const decoder = flac.Decoder.init(ally, &reader.interface, .{}) catch continue;
                defer decoder.deinit(ally);
                const title = blk: for (decoder.metadata) |metadata| {
                    switch (metadata) {
                        .vorbis_comment => |vc| {
                            var vc_iter = vc.iterator();
                            while (vc_iter.next()) |vc_entry| {
                                if (std.mem.eql(u8, vc_entry.key, "TITLE")) {
                                    break :blk vc_entry.value;
                                }
                            }
                        },
                        else => {},
                    }
                } else entry.name;

                songs.append(ally, .{
                    .title = try ally.dupe(u8, title),
                    .file = file,
                }) catch continue;
            }
        }
    } else {
        const file = try cwd.openFile(io, path, .{});
        errdefer file.close(io);

        var buf: [1024]u8 = undefined;
        var reader = file.reader(io, &buf);

        const decoder: flac.Decoder = try .init(ally, &reader.interface, .{});
        defer decoder.deinit(ally);
        const title = blk: for (decoder.metadata) |metadata| {
            switch (metadata) {
                .vorbis_comment => |vc| {
                    var vc_iter = vc.iterator();
                    while (vc_iter.next()) |vc_entry| {
                        if (std.mem.eql(u8, vc_entry.key, "TITLE")) {
                            break :blk vc_entry.value;
                        }
                    }
                },
                else => {},
            }
        } else path;

        try songs.append(ally, .{
            .title = try ally.dupe(u8, title),
            .file = file,
        });
    }

    return songs.toOwnedSlice(ally);
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
