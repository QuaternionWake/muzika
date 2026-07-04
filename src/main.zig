const std = @import("std");
const log = std.log;
const Io = std.Io;

const sdl = @import("sdl");
const flac = @import("flac");

const raw_mode = @import("raw_mode.zig");
const input = @import("input.zig");

pub fn main(init: std.process.Init) !u8 {
    var stdout_buf: [1024]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch @panic("failed to flush stdout");

    var stdin_buf: [1024]u8 = undefined;
    const stdin_file = std.Io.File.stdin();
    var stdin_reader = stdin_file.reader(init.io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    var args_iter = init.minimal.args.iterate();
    const prog_name = args_iter.next().?;
    const filename = args_iter.next() orelse {
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

    var file_buf: [1024]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(init.io, filename, .{});
    var file_reader = file.reader(init.io, &file_buf);

    var decoder = flac.Decoder.init(init.gpa, &file_reader.interface, .{}) catch |err| {
        log.err("Failed to initialize flac decoder: {t}", .{err});
        return 1;
    };
    defer decoder.deinit(init.gpa);

    // decoder ensures first metadata block is a StreamInfo
    const sample_count = decoder.metadata[0].stream_info.sample_count;

    const title = blk: for (decoder.metadata) |metadata| {
        switch (metadata) {
            .vorbis_comment => |vc| {
                var iter = vc.iterator();
                while (iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key, "TITLE")) {
                        break :blk entry.value;
                    }
                }
            },
            else => {},
        }
    } else null;

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
    const duration_seconds = sample_count / decoder.sample_rate;
    const duration: std.Io.Duration = .fromSeconds(duration_seconds);
    var played: std.Io.Duration = .zero;
    const clock: std.Io.Clock = .awake;
    var prev_timestamp = clock.now(init.io);

    try stdout.print("{s}\n", .{title orelse filename});
    try stdout.flush();
    const min_samples = 10240;
    var should_quit = false;
    while (!should_quit) {
        if (sdl.getAudioStreamQueued(stream) catch break < min_samples) {
            var buf: [min_samples]f32 = undefined;
            const samples = decoder.read(f32, &buf) catch |err| {
                log.err("Failed to read audio data: {t}", .{err});
                return err;
            };
            if (samples.len == 0) {
                should_quit = true;
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

        const played_seconds: u32 = @intCast(played.toSeconds());
        try stdout.print(
            "\r{d:02}:{d:02} / {d:02}:{d:02}",
            .{ played_seconds / 60, played_seconds % 60, duration_seconds / 60, duration_seconds % 60 },
        );
        const progress_width = 50;
        const ratio_played = @min(1, @as(f32, @floatFromInt(played.nanoseconds)) / @as(f32, @floatFromInt(duration.nanoseconds)));
        const num_filled: usize = (@round(ratio_played * progress_width));
        try stdout.writeAll("   ");
        try stdout.writeByte('[');
        try stdout.splatByteAll('#', num_filled);
        try stdout.splatByteAll(' ', progress_width - num_filled);
        try stdout.writeByte(']');
        try stdout.flush();

        if (stdin.bufferedLen() == 0) {
            if (pollFd(stdin_file.handle)) {
                stdin.fill(1) catch |err| switch (err) {
                    error.ReadFailed => log.err("Failed to read from stdin", .{}),
                    error.EndOfStream => {},
                };
            }
        }
        if (stdin.seek < stdin.end) {
            const key, const consumed = input.get(stdin.buffer[stdin.seek..stdin.end]);
            stdin.toss(consumed);
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
        }
    }
    try stdout.writeByte('\n');

    return 0;
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
