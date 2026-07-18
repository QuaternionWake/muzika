const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mem = std.mem;

const sdl = @import("sdl");
const flac = @import("flac");

const Player = @This();

const clock: Io.Clock = .awake;

pub const Track = struct {
    strings: []u8,
    title: usize,
    artist: usize,
    album: usize,

    const String = enum { path, title, artist, album };

    pub fn get(self: Track, string: String) [*:0]const u8 {
        return switch (string) {
            .path => @ptrCast(self.strings[0..]),
            .title => @ptrCast(self.strings[self.title..]),
            .artist => @ptrCast(self.strings[self.artist..]),
            .album => @ptrCast(self.strings[self.album..]),
        };
    }

    fn init(ally: Allocator, path: []const []const u8, decoder: flac.Decoder) !Track {
        var title = blk: {
            if (path.len == 0) break :blk "";
            const start = mem.findScalarLast(u8, path[path.len - 1], Io.Dir.path.sep) orelse 0;
            break :blk path[path.len - 1][start + 1 ..];
        };
        var artist: []const u8 = "unknown artist";
        var album: []const u8 = "unknown album";
        for (decoder.metadata) |m| {
            switch (m) {
                .vorbis_comment => |vc| {
                    var iter = vc.iterator();
                    while (iter.next()) |entry| {
                        if (mem.eql(u8, entry.key, "TITLE")) {
                            title = entry.value;
                        } else if (mem.eql(u8, entry.key, "ARTIST")) {
                            artist = entry.value;
                        } else if (mem.eql(u8, entry.key, "ALBUM")) {
                            album = entry.value;
                        }
                    }
                },
                else => {},
            }
        }

        // path.len - 1 separators, plus a null terminator for each field
        var len = path.len -| 1 + 4;
        // all the paths
        for (path) |p| len += p.len;
        // and all the fields
        len += title.len + artist.len + album.len;

        const buffer = try ally.alloc(u8, len);
        var buf_ally: std.heap.FixedBufferAllocator = .init(buffer);

        const path_len = (mem.joinZ(buf_ally.allocator(), Io.Dir.path.sep_str, path) catch unreachable).len;
        _ = mem.joinZ(buf_ally.allocator(), &.{0}, &.{ title, artist, album }) catch unreachable;

        std.debug.assert(buf_ally.end_index == buffer.len);

        const title_start = path_len + 1;
        const artist_start = title_start + title.len + 1;
        const album_start = artist_start + artist.len + 1;
        return .{
            .strings = buffer,
            .title = title_start,
            .artist = artist_start,
            .album = album_start,
        };
    }

    fn deinit(self: Track, ally: Allocator) void {
        ally.free(self.strings);
    }
};

io: Io,
ally: Allocator,

file: ?Io.File,
file_buffer: []u8,
file_reader: *Io.File.Reader,

tracks: []Track,
current_track: usize,

sample_count: u36,
last_measurement: Io.Timestamp,
played: Io.Duration,
duration: Io.Duration,
paused: bool,

decoder_arena: std.heap.ArenaAllocator,
decoder: flac.Decoder,

stream: ?*sdl.AudioStream,

pub fn play(self: *Player) !void {
    if (self.current_track >= self.tracks.len) return;

    const min_queued = 10240;
    if (!self.paused) {
        const stream = self.stream orelse return error.StreamUninitialized;
        const queued = try sdl.getAudioStreamQueued(stream);
        if (queued < min_queued) {
            var buffer: [10240]f32 = undefined;
            const samples = try self.decoder.read(f32, &buffer);
            try sdl.putAudioStreamData(stream, f32, samples);

            if (samples.len == 0) {
                try self.nextTrack();
            }

            const t = clock.now(self.io);
            self.played.nanoseconds += self.last_measurement.durationTo(t).nanoseconds;
            self.last_measurement = t;
        }
    }
}

pub fn playCurrentTrack(self: *Player) !void {
    if (self.current_track >= self.tracks.len) {
        self.paused = true;
        self.played = .zero;
        self.duration = .zero;
        self.sample_count = 0;
        return;
    }

    const track = self.tracks[self.current_track];
    _ = self.decoder_arena.reset(.retain_capacity);

    if (self.file) |f| f.close(self.io);
    self.file = try Io.Dir.cwd().openFile(self.io, mem.span(track.get(.path)), .{});
    self.file_reader.* = self.file.?.reader(self.io, self.file_buffer);
    self.decoder = try .init(self.decoder_arena.allocator(), &self.file_reader.interface, .{ .seek_impl = .file });

    // decoder ensures first metadata block is a stream_info
    self.sample_count = self.decoder.metadata[0].stream_info.sample_count;
    self.duration = samplesToDuration(self.sample_count, self.decoder.sample_rate);

    if (self.stream) |s| sdl.destroyAudioStream(s);
    self.paused = true;
    self.stream = null;
    const spec: sdl.AudioSpec = .{
        .format = .f32,
        .channels = self.decoder.channels,
        .freq = @intCast(self.decoder.sample_rate), // probably not ever gonna need to play a file with a > 2^31 sample rate
    };
    self.stream = try sdl.openAudioDeviceStream(.default_playback, &spec, null, null);
    try sdl.resumeAudioStreamDevice(self.stream.?);
    self.paused = false;
    self.played = .zero;
    self.last_measurement = clock.now(self.io);
}

pub fn seekRelative(self: *Player, ms: i32) !void {
    const sample_offset = std.math.mulWide(u32, @abs(ms), self.decoder.sample_rate) / std.time.ms_per_s;
    const target =
        if (ms < 0)
            self.decoder.frame_offset -| sample_offset
        else
            self.decoder.frame_offset +| sample_offset;

    try self.seekSample(target);
}

// why is there no nice and understandable word for percentage but only 0 to 1?
// grumble, grumble...
pub fn seekPercent(self: *Player, percent: f32) !void {
    const target = percent / 100 * @as(f32, @floatFromInt(self.sample_count));

    try self.seekSample(@round(target));
}

fn seekSample(self: *Player, target: u64) !void {
    // Reading past the end of a file blocks, so set a max
    const target_ = @min(target, self.sample_count -| 1);

    try self.decoder.seekTo(target_);
    self.played = samplesToDuration(@intCast(self.decoder.frame_offset), self.decoder.sample_rate);
    try sdl.clearAudioStream(self.stream orelse return);
}

pub fn togglePause(self: *Player) !void {
    const stream = self.stream orelse return;
    if (self.paused) {
        try sdl.resumeAudioStreamDevice(stream);
        self.paused = false;

        self.last_measurement = clock.now(self.io);
    } else {
        try sdl.pauseAudioStreamDevice(stream);
        self.paused = true;

        const t = clock.now(self.io);
        self.played.nanoseconds += self.last_measurement.durationTo(t).nanoseconds;
    }
}

pub fn trackString(self: Player, string: Track.String) []const u8 {
    if (self.current_track < self.tracks.len) {
        return mem.span(self.tracks[self.current_track].get(string));
    } else {
        return "n/a";
    }
}

pub fn nextTrack(self: *Player) !void {
    if (self.current_track + 1 < self.tracks.len) {
        self.current_track += 1;
    } else {
        try self.seekSample(std.math.maxInt(u64));
        return;
    }
    try self.playCurrentTrack();
}

pub fn previousTrack(self: *Player) !void {
    if (self.current_track > 0) {
        self.current_track -= 1;
    }
    try self.playCurrentTrack();
}

pub fn init(io: Io, ally: Allocator, path: []const u8) !Player {
    const is_dir = blk: {
        const file = try Io.Dir.cwd().openFile(io, path, .{ .allow_directory = true, .path_only = true });
        defer file.close(io);
        const stat = try file.stat(io);
        break :blk stat.kind == .directory;
    };

    const file_buffer = try ally.alloc(u8, 1024);
    errdefer ally.free(file_buffer);
    const file_reader = try ally.create(Io.File.Reader);
    errdefer ally.destroy(file_reader);

    var player: Player = .{
        .io = io,
        .ally = ally,

        .file = null,
        .file_buffer = file_buffer,
        .file_reader = file_reader,

        .tracks = &.{},
        .current_track = 0,

        .sample_count = 0,
        .last_measurement = .zero,
        .played = .zero,
        .duration = .zero,
        .paused = true,

        .decoder_arena = .init(ally),
        .decoder = undefined,

        .stream = null,
    };

    if (is_dir) {
        try player.loadDir(path);
    } else {
        try player.loadFile(path);
    }

    return player;
}

pub fn deinit(self: *Player) void {
    self.clearTracks();
    self.decoder_arena.deinit();
    self.ally.free(self.file_buffer);
    self.ally.destroy(self.file_reader);
    if (self.file) |f| f.close(self.io);
    if (self.stream) |s| sdl.destroyAudioStream(s);
}

fn loadFile(self: *Player, path: []const u8) !void {
    self.clearTracks();

    _ = self.decoder_arena.reset(.retain_capacity);

    if (self.file) |f| f.close(self.io);
    self.file = try Io.Dir.cwd().openFile(self.io, path, .{});
    self.file_reader.* = self.file.?.reader(self.io, self.file_buffer);
    self.decoder = try .init(self.decoder_arena.allocator(), &self.file_reader.interface, .{ .seek_impl = .file });

    self.tracks = try self.ally.alloc(Track, 1);
    self.tracks[0] = try .init(self.ally, &.{path}, self.decoder);
}

fn loadDir(self: *Player, path: []const u8) !void {
    self.clearTracks();

    const dir = try Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
    var iter = dir.iterate();

    var track_list: std.ArrayList(Track) = .empty;
    while (true) {
        const entry = iter.next(self.io) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => continue,
            else => return err,
        } orelse break;
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.name, ".flac")) continue;

        const file = try dir.openFile(self.io, entry.name, .{});
        var reader = file.reader(self.io, self.file_buffer);
        const decoder: flac.Decoder = try .init(self.decoder_arena.allocator(), &reader.interface, .{});
        defer _ = self.decoder_arena.reset(.retain_capacity);

        try track_list.append(self.ally, try .init(
            self.ally,
            &.{ path, entry.name },
            decoder,
        ));
    }

    self.tracks = try track_list.toOwnedSlice(self.ally);
    if (self.tracks.len == 0) return;

    _ = self.decoder_arena.reset(.retain_capacity);

    if (self.file) |f| f.close(self.io);
    self.file = try Io.Dir.cwd().openFile(self.io, mem.span(self.tracks[0].get(.path)), .{});
    self.file_reader.* = self.file.?.reader(self.io, self.file_buffer);
    self.decoder = try .init(self.decoder_arena.allocator(), &self.file_reader.interface, .{ .seek_impl = .file });
}

pub fn clearTracks(self: *Player) void {
    for (self.tracks) |t| t.deinit(self.ally);
    self.ally.free(self.tracks);
    self.tracks.len = 0;
    self.current_track = 0;
}

fn samplesToDuration(sample_count: u36, sample_rate: u32) Io.Duration {
    return .{
        .nanoseconds = std.math.mulWide(u36, std.time.ns_per_s, sample_count) / sample_rate,
    };
}
