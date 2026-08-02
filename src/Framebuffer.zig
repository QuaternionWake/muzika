const std = @import("std");

const Framebuffer = @This();

width: u16,
height: u16,
pixels: []Pixel,

pub fn init(ally: std.mem.Allocator, width: u16, height: u16) !Framebuffer {
    const pixels = try ally.alloc(Pixel, width * height);
    @memset(pixels, .{});
    return .{
        .width = width,
        .height = height,
        .pixels = pixels,
    };
}

pub fn deinit(self: *Framebuffer, ally: std.mem.Allocator) void {
    ally.free(self.pixels);
    self.pixels = &.{};
}

pub const Pixel = struct {
    char: u21 = ' ',
};

pub fn pixel(self: *Framebuffer, x: u16, y: u16) ?*Pixel {
    if (x >= self.width or y >= self.height) return null;
    return &self.pixels[y * self.width + x];
}

pub fn line(self: *Framebuffer, y: u16) ?[]Pixel {
    if (y > self.height) return null;

    return self.pixels[y * self.width ..][0..self.width];
}

pub fn lineSlice(self: *Framebuffer, x: u16, y: u16, x_end: u16) ?[]Pixel {
    const line_ = self.line(y) orelse return null;
    if (x > x_end or x > line_.len) return null;

    return line_[x..@min(x_end, line_.len)];
}

pub fn drawText(self: *Framebuffer, x: u16, y: u16, x_end: u16, text_chunks: []const TextChunk) void {
    var slice = self.lineSlice(x, y, x_end) orelse return;

    for (text_chunks) |chunk| {
        if (slice.len == 0) break;
        switch (chunk) {
            .ascii => |str| {
                const len = @min(str.len, slice.len);
                for (slice[0..len], str[0..len]) |*pixel_, char| {
                    pixel_.char = char;
                }
                slice = slice[len..];
            },
            .utf8 => |view| {
                var iter = view.iterator();
                while (iter.nextCodepoint()) |char| {
                    slice[0].char = char;
                    slice = slice[1..];
                    if (slice.len == 0) break;
                }
            },
        }
    }
}

pub const TextChunk = union(enum) {
    ascii: []const u8,
    utf8: std.unicode.Utf8View,
};
