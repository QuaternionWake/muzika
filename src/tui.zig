const std = @import("std");

const Track = @import("Player.zig").Track;
const Fb = @import("Framebuffer.zig");

pub const tui_height = 14;
const y_padding = 1;
const x_padding = 2;

const cover_art_min_width = 50;
const cover_art_width = 16;
const cover_art_height = 7;
pub fn drawCoverArt(fb: *Fb) void {
    if (fb.width < cover_art_min_width) return;

    for (0..cover_art_height) |y| {
        const pixels = paddedLineSlice(fb, 0, @intCast(y), cover_art_width) orelse return;
        for (pixels) |*p| {
            p.char = '.';
        }
    }
}

pub fn drawTrackList(fb: *Fb, tracks: []Track, current_track: usize) void {
    const x: u16 = if (fb.width < cover_art_min_width) 2 else cover_art_width + 5;

    const start = blk: {
        if (tracks.len <= cover_art_height) break :blk 0;
        break :blk @min(current_track -| cover_art_height / 2, tracks.len - cover_art_height);
    };
    const end =
        if (tracks.len <= cover_art_height) tracks.len else start + cover_art_height;

    for (tracks[start..end], 0..) |track, y| {
        const view = utf8View(track.get(.title));

        drawTextUtf8View(fb, x, @intCast(y), null, view);
    }

    const arrow_pixel = paddedPixel(fb, x - 2, @intCast(current_track - start)) orelse return;
    arrow_pixel.char = '>';
}

pub fn drawTrackInfo(fb: *Fb, track: Track) void {
    drawTextUtf8View(fb, 0, 8, null, utf8View(track.get(.title)));
    drawTextChunks(fb, 0, 9, null, &.{
        .{ .utf8 = utf8View(track.get(.artist)) },
        .{ .ascii = " | " },
        .{ .utf8 = utf8View(track.get(.album)) },
    });
}

pub fn drawBottomBar(fb: *Fb, played: std.Io.Duration, duration: std.Io.Duration) void {
    const y = fb.height - 2 * y_padding - 1;
    var line = paddedLine(fb, y) orelse return;

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
        var writer: std.Io.Writer = .fixed(&buf_played);
        if (times_played.hours != 0) {
            writer.print("{d}:{d:02}:{d:02}", times_played) catch unreachable;
        } else {
            writer.print("{d}:{d:02}", .{ times_played.mins, times_played.secs }) catch unreachable;
        }
        break :blk buf_played[0..writer.end];
    };

    var buf_duration: [32]u8 = undefined;
    const str_duration = blk: {
        var writer: std.Io.Writer = .fixed(&buf_duration);
        if (times_duration.hours != 0) {
            writer.print("{d}:{d:02}:{d:02}", times_duration) catch unreachable;
        } else {
            writer.print("{d}:{d:02}", .{ times_duration.mins, times_duration.secs }) catch unreachable;
        }
        break :blk buf_duration[0..writer.end];
    };

    // has space for at least 5 notches on the progress bar + ends + spaces
    if (line.len > str_played.len + str_duration.len + 5 + 2 + 2) {
        // [played] [progress bar] [duration]
        // 0:33 [####          ] 4:52
        const progress_width = line.len - str_played.len - str_duration.len - 2;
        const inner_width = progress_width - 2;
        const ratio_played = @min(1, @as(f32, @floatFromInt(played.nanoseconds)) / @as(f32, @floatFromInt(duration.nanoseconds)));
        const num_filled: usize = @round(ratio_played * @as(f32, @floatFromInt(inner_width)));

        // played
        for (line[0..str_played.len], str_played) |*pixel, char| {
            pixel.char = char;
        }
        line = line[str_played.len + 1 ..];

        // progress bar
        line[0].char = '[';
        @memset(line[1..][0..num_filled], .{ .char = '#' });
        line[progress_width - 1].char = ']';
        line = line[progress_width + 1 ..];

        // duration
        for (line[0..str_duration.len], str_duration) |*pixel, char| {
            pixel.char = char;
        }
        line = line[str_duration.len..];
        std.debug.assert(line.len == 0);
    } else if (line.len > str_played.len + str_duration.len + 3) {
        // [played] / [duration]
        // 0:33 / 4:52

        drawTextChunks(fb, 0, y, null, &.{
            .{ .ascii = str_played },
            .{ .ascii = " / " },
            .{ .ascii = str_duration },
        });
    } else if (line.len > str_played.len) {
        // [played]
        // 0:33
        drawTextAscii(fb, 0, y, null, str_played);
    }
}

fn drawTextAscii(fb: *Fb, x: u16, y: u16, x_end: ?u16, ascii: []const u8) void {
    drawTextChunks(fb, x, y, x_end, &.{.{ .ascii = ascii }});
}

fn drawTextUtf8View(fb: *Fb, x: u16, y: u16, x_end: ?u16, view: std.unicode.Utf8View) void {
    drawTextChunks(fb, x, y, x_end, &.{.{ .utf8 = view }});
}

fn drawTextChunks(fb: *Fb, x: u16, y: u16, x_end: ?u16, text_chunks: []const Fb.TextChunk) void {
    fb.drawText(
        x +| x_padding,
        @min(y +| y_padding, fb.height -| y_padding),
        @min(x_end orelse @as(u16, std.math.maxInt(u16)) +| x_padding, fb.width -| x_padding),
        text_chunks,
    );
}

fn paddedLine(fb: *Fb, y: u16) ?[]Fb.Pixel {
    const y_ = y +| y_padding;
    if (y_ > fb.height -| y_padding) return null;

    const start = x_padding;
    const end = fb.width -| x_padding;
    if (start > end) return null;

    return fb.pixels[y_ * fb.width ..][start..end];
}

pub fn paddedPixel(fb: *Fb, x: u16, y: u16) ?*Fb.Pixel {
    const x_ = x +| x_padding;
    const y_ = y +| y_padding;
    if (x_ >= fb.width -| x_padding or y_ >= fb.height -| y_padding) return null;
    return &fb.pixels[y_ * fb.width + x_];
}

fn paddedLineSlice(fb: *Fb, x: u16, y: u16, x_end: ?u16) ?[]Fb.Pixel {
    const line = paddedLine(fb, y) orelse return null;
    const x_end_ = x_end orelse std.math.maxInt(u16);
    if (x > x_end_ or x > line.len) return null;

    return line[x..@min(x_end_, line.len)];
}

fn utf8View(str: []const u8) std.unicode.Utf8View {
    return std.unicode.Utf8View.init(str) catch std.unicode.Utf8View.initComptime("???");
}
