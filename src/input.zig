const std = @import("std");
const ascii = std.ascii;

pub fn get(string: []const u8) struct { ?KeyboardKey, usize } {
    var tokenizer = tokenizeInputSequence(string);
    const token = tokenizer.next() orelse return .{
        null,
        tokenizer.pos,
    };
    return .{
        keyboardKeyFromToken(token) catch null,
        tokenizer.pos,
    };
}

fn keyboardKeyFromToken(token: Token) error{UnknownKey}!KeyboardKey {
    switch (token) {
        .ascii_char => |value| {
            if (ascii.isAlphanumeric(value) or
                std.mem.findScalar(u8, " [];'\\,./{}:\"|<>?`~-=!@#$%^&*()_+\x7f", value) != null)
            {
                return @enumFromInt(value);
            }
        },
        .unicode_char => return error.UnknownKey,
        .c0_control_code => |value| {
            return switch (value) {
                .esc => .escape,
                .lf => .enter,
                .ht => .tab,
                else => error.UnknownKey,
            };
        },
        .c1_control_code => return error.UnknownKey,
        .ss3_control_code => |value| {
            return switch (value) {
                0x50 => .f1,
                0x51 => .f2,
                0x52 => .f3,
                0x53 => .f4,
                else => error.UnknownKey,
            };
        },
        .control_sequence => |value| {
            if (value.intermediates.len != 0) return error.UnknownKey;
            const params = value.params;
            if (value.final_byte == '~') {
                if (eql(params, "15")) return .f5;
                if (eql(params, "17")) return .f6;
                if (eql(params, "18")) return .f7;
                if (eql(params, "19")) return .f8;
                if (eql(params, "20")) return .f9;
                if (eql(params, "21")) return .f10;
                if (eql(params, "23")) return .f11;
                if (eql(params, "24")) return .f12;
                if (eql(params, "2")) return .insert;
                if (eql(params, "3")) return .delete;
                if (eql(params, "5")) return .page_up;
                if (eql(params, "6")) return .page_down;
            }
            if (value.params.len != 0) return error.UnknownKey;
            return switch (value.final_byte) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'F' => .end,
                'H' => .home,
                else => error.UnknownKey,
            };
        },
    }
    return error.UnknownKey;
}

pub const KeyboardKey = enum(u8) {
    // zig fmt: off
    q='q', w='w', e='e', r='r', t='t', y='y', u='u', i='i', o='o', p='p',
    a='a', s='s', d='d', f='f', g='g', h='h', j='j', k='k', l='l',
    z='z', x='x', c='c', v='v', b='b', n='n', m='m',

    Q='Q', W='W', E='E', R='R', T='T', Y='Y', U='U', I='I', O='O', P='P',
    A='A', S='S', D='D', F='F', G='G', H='H', J='J', K='K', L='L',
    Z='Z', X='X', C='C', V='V', B='B', N='N', M='M',

    space=' ',

    left_bracket='[', right_bracket=']',
    semicolon=';', apostrophe='\'', backslash='\\',
    comma=',', period='.', slash='/',

    left_brace='{', right_brace='}',
    colon=':', quote='"', pipe='|',
    less_than='<', greater_than='>', question_mark='?',

    escape=@intFromEnum(C0.esc), backtick='`', tilda='~', tab='\t',
    backspace=0x7f, enter=@intFromEnum(C0.lf),

    zero='0', one='1', two='2', three='3', four='4',
    five='5', six='6', seven='7', eight='8', nine='9',
    minus='-', equals='=',

    exclamation_mark='!', at='@', hash='#', dollar='$', percent='%',
    caret='^', ampersand='&', asterisk='*', left_parenthesis='(', right_parenthesis=')',
    underscore='_', plus='+',

    f1=201, f2=202, f3=203, f4=204, f5=205, f6=206, f7=207, f8=208, f9=209, f10=210, f11=211, f12=212,

    insert=150, delete=151, page_up=152, page_down=153, home=154, end=155,
    up=160, down=161, left=162, right=163,
    // zig fmt: on
};

fn tokenizeInputSequence(string: []const u8) InputSequenceTokenizer {
    return .{
        .string = string,
        .pos = 0,
    };
}

const InputSequenceTokenizer = struct {
    string: []const u8,
    pos: usize,

    fn next(self: *InputSequenceTokenizer) ?Token {
        if (self.pos >= self.string.len) return null;

        if (self.string[self.pos] == @intFromEnum(C0.esc)) {
            self.pos += 1;
            if (self.string.len == self.pos) {
                return .{ .c0_control_code = .esc };
            }
            if (self.string[self.pos] == @intFromEnum(C1.csi)) {
                self.pos += 1;
                const params = params: {
                    const start = self.pos;
                    while (isInRange(self.string[self.pos], 0x30, 0x3f)) self.pos += 1;
                    break :params self.string[start..self.pos];
                };
                const intermediates = intermediates: {
                    const start = self.pos;
                    while (isInRange(self.string[self.pos], 0x10, 0x1f)) self.pos += 1;
                    break :intermediates self.string[start..self.pos];
                };
                const final_byte = self.string[self.pos];
                self.pos += 1;
                return .{ .control_sequence = .{
                    .params = params,
                    .intermediates = intermediates,
                    .final_byte = final_byte,
                } };
            }
            const c1_byte = self.string[self.pos];
            const maybe_c1 = std.enums.fromInt(C1, c1_byte);
            self.pos += 1;
            if (maybe_c1) |c1| {
                if (c1 == .ss3) {
                    const byte = self.string[self.pos];
                    self.pos += 1;
                    return .{ .ss3_control_code = byte };
                }
                return .{ .c1_control_code = c1 };
            } else {
                // possible by doing alt + <character>
                return .{ .ascii_char = c1_byte };
            }
        }

        if (self.string[self.pos] > 127) {
            const start = self.pos;
            const len = std.unicode.utf8ByteSequenceLength(self.string[self.pos]) catch {
                self.pos += 1;
                return null;
            };
            self.pos += len;
            if (self.pos > self.string.len) return null;
            const char = std.unicode.utf8Decode(self.string[start..self.pos]) catch return null;
            return .{ .unicode_char = char };
        }

        defer self.pos += 1;
        if (std.enums.fromInt(C0, self.string[self.pos])) |c0| {
            return .{ .c0_control_code = c0 };
        }
        return .{ .ascii_char = self.string[self.pos] };
    }
};

/// Range is inclusive
fn isInRange(byte: u8, min: u8, max: u8) bool {
    return byte >= min and byte <= max;
}

const Token = union(enum) {
    ascii_char: u8,
    unicode_char: u21,
    c0_control_code: C0,
    c1_control_code: C1,
    ss3_control_code: u8,
    control_sequence: struct {
        params: []const u8,
        intermediates: []const u8,
        final_byte: u8,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("params: \"{s}\", intermediates: \"{s}\", final byte: \"{c}\", ", self);
        }
    },
};

const C0 = enum(u8) {
    // zig fmt: off
    nul = 0x00, soh = 0x01, stx = 0x02, etx = 0x03,
    eot = 0x04, enq = 0x05, ack = 0x06, bel = 0x07,
    bs  = 0x08, ht  = 0x09, lf  = 0x0a, vt  = 0x0b,
    ff  = 0x0c, cr  = 0x0d, so  = 0x0e, si  = 0x0f,
    dle = 0x10, dc1 = 0x11, dc2 = 0x12, dc3 = 0x13,
    dc4 = 0x14, nak = 0x15, syn = 0x16, etb = 0x17,
    can = 0x18, em  = 0x19, sub = 0x1a, esc = 0x1b,
    is4 = 0x1c, is3 = 0x1d, is2 = 0x1e, is1 = 0x1f,
    // zig fmt: on
};

const C1 = enum(u8) {
    // zig fmt: off
                            bph = 0x42, nbh = 0x43,
                nel = 0x45, ssa = 0x46, esa = 0x47,
    hts = 0x48, htj = 0x49, vts = 0x4a, pld = 0x4b,
    plu = 0x4c, ri  = 0x4d, ss2 = 0x4e, ss3 = 0x4f,
    dcs = 0x50, pu1 = 0x51, pu2 = 0x52, sts = 0x53,
    cch = 0x54, mw  = 0x55, spa = 0x56, epa = 0x57,
    sos = 0x58,             sci = 0x5a, csi = 0x5b,
    st  = 0x5c, osc = 0x5d, pm  = 0x5e, apc = 0x5f,
    // zig fmt: off
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
