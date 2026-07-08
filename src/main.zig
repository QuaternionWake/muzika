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

    var current_song: usize = 0;
    var file_buf: [1024]u8 = undefined;
    var file_reader = songs[0].file.reader(init.io, &file_buf);

    var decoder = flac.Decoder.init(init.gpa, &file_reader.interface, .{ .seek_impl = .file }) catch |err| {
        log.err("Failed to initialize flac decoder: {t}", .{err});
        return 1;
    };
    defer decoder.deinit(init.gpa);

    // decoder ensures first metadata block is a StreamInfo
    var sample_count = decoder.metadata[0].stream_info.sample_count;

    const spec: sdl.AudioSpec = .{
        .format = .f32,
        .channels = decoder.channels,
        .freq = @intCast(decoder.sample_rate),
    };
    const stream = sdl.openAudioDeviceStream(.default_playback, &spec, null, null) catch {
        log.err("Failed to open audio stream device: {s}\n", .{sdl.getError()});
        return error.SdlOpenAudioDeviceStreamFailed;
    };
    defer sdl.destroyAudioStream(stream);
    sdl.resumeAudioStreamDevice(stream) catch {
        log.err("Failed to resume audio device stream: {s}\n", .{sdl.getError()});
        return error.SdlResumeAudioDeviceStreamFailed;
    };

    var playing: bool = true;
    var duration_seconds = sample_count / decoder.sample_rate;
    var duration: std.Io.Duration = .fromSeconds(duration_seconds);
    var played: std.Io.Duration = .zero;
    const clock: std.Io.Clock = .awake;
    var prev_timestamp = clock.now(init.io);

    const min_samples = 10240;
    var should_quit = false;
    var flushed = false;
    while (!should_quit) {
        const queued = sdl.getAudioStreamQueued(stream) catch {
            log.err("Failed to get number of queued bytes: {s}\n", .{sdl.getError()});
            return error.SdlGetAudioStreamQueuedFailed;
        };
        if (queued < min_samples) {
            var buf: [min_samples]f32 = undefined;
            const samples = decoder.read(f32, &buf) catch |err| {
                log.err("Failed to read audio data: {t}", .{err});
                return err;
            };
            if (samples.len == 0) {
                current_song += 1;
                if (current_song < songs.len) {
                    file_reader = songs[current_song].file.reader(init.io, &file_buf);
                    decoder.deinit(init.gpa);
                    decoder = flac.Decoder.init(init.gpa, &file_reader.interface, .{ .seek_impl = .file }) catch |err| {
                        log.err("Failed to initialize flac decoder: {t}", .{err});
                        return 1;
                    };
                    // decoder ensures first metadata block is a StreamInfo
                    sample_count = decoder.metadata[0].stream_info.sample_count;
                    duration_seconds = sample_count / decoder.sample_rate;
                    duration = .fromSeconds(duration_seconds);
                    played.nanoseconds = 0;
                    prev_timestamp = clock.now(init.io);
                } else {
                    if (queued == 0) {
                        should_quit = true;
                    }
                    if (!flushed) {
                        sdl.flushAudioStream(stream) catch
                            log.err("Failed to flush audio stream: {s}\n", .{sdl.getError()});
                        flushed = true;
                    }
                }
            }

            sdl.putAudioStreamData(stream, f32, &buf) catch
                log.err("Failed to put data in audio stream: {s}\n", .{sdl.getError()});
        } else {
            std.Io.sleep(init.io, .fromMilliseconds(10), .awake) catch unreachable;
        }

        if (playing) {
            const timestamp = clock.now(init.io);
            played.nanoseconds += prev_timestamp.durationTo(timestamp).nanoseconds;
            prev_timestamp = timestamp;
        }

        const view = Utf8View.init(songs[current_song].title) catch Utf8View.initComptime("???");
        terminal.tui.drawTitle(view);
        terminal.tui.drawBottomBar(played, duration);

        try terminal.draw();

        while (terminal.getInput()) |key| {
            if (key == .q) {
                should_quit = true;
            }
            if (key == .p or key == .space) {
                if (playing) {
                    playing = false;
                    sdl.pauseAudioStreamDevice(stream) catch
                        log.err("Failed to pause audio stream device: {s}\n", .{sdl.getError()});
                } else {
                    prev_timestamp = clock.now(init.io);
                    playing = true;
                    sdl.resumeAudioStreamDevice(stream) catch
                        log.err("Failed to resume audio stream device: {s}\n", .{sdl.getError()});
                }
            }
            if (key == .right) {
                const five_secs = decoder.sample_rate * 5;
                // Reading past the end of a file blocks, so set a max
                decoder.seekTo(@min(sample_count -| 1, decoder.frame_offset +| five_secs)) catch |err|
                    log.err("Failed to seek: {t}", .{err});
                played.nanoseconds = @min(duration.nanoseconds, played.nanoseconds + 5 * std.time.ns_per_s);
                sdl.clearAudioStream(stream) catch
                    log.err("Failed to clear stream: {s}", .{sdl.getError()});
            }
            if (key == .left) {
                const five_secs = decoder.sample_rate * 5;
                decoder.seekTo(decoder.frame_offset -| five_secs) catch |err|
                    log.err("Failed to seek: {t}", .{err});
                played.nanoseconds = @max(0, played.nanoseconds - 5 * std.time.ns_per_s);
                sdl.clearAudioStream(stream) catch
                    log.err("Failed to clear stream: {s}", .{sdl.getError()});
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
