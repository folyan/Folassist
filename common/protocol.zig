const std = @import("std");

pub const MAGIC: u8 = 0xFA;
pub const VERSION: u8 = 7;
pub const HEADER_LEN: usize = 7;
pub const TYPE_BITS: u3 = 0b111;
pub const MAX_PAYLOAD: u32 = 16 * 1024 * 1024;
pub const MAX_MODEL: u32 = 512 * 1024 * 1024;
pub const REPLY_MORE: u8 = 0b0000_0001;

pub const Op = enum(u2) {
    model_req = 0b00,
    weather = 0b01,
    ai = 0b10,
    music = 0b11,
};

pub const MsgType = enum(u8) {
    hello = 1,
    cmd = 2,
    reply = 3,
    model = 4,
    play = 5,
    prompt = 6,
    cache = 7,
    _,
};

pub const Header = struct {
    msg_type: MsgType,
    flags: u8,
    len: u32,
};

pub fn encodeHeader(t: MsgType, flags: u8, len: u32) [HEADER_LEN]u8 {
    var b: [HEADER_LEN]u8 = undefined;
    b[0] = MAGIC;
    b[1] = VERSION;
    b[2] = (@intFromEnum(t) & TYPE_BITS) | ((flags & 0x1f) << 3);
    std.mem.writeInt(u32, b[3..7], len, .little);
    return b;
}

pub fn decodeHeader(b: [HEADER_LEN]u8) !Header {
    if (b[0] != MAGIC) return error.BadMagic;
    if (b[1] != VERSION) return error.BadVersion;
    const t: MsgType = @enumFromInt(b[2] & TYPE_BITS);
    const flags = b[2] >> 3;
    const len = std.mem.readInt(u32, b[3..7], .little);
    const limit: u32 = if (t == .model) MAX_MODEL else MAX_PAYLOAD;
    if (len > limit) return error.FrameTooLarge;
    return .{ .msg_type = t, .flags = flags, .len = len };
}

pub fn Net(comptime C: type) type {
    return struct {
        pub const Frame = struct {
            msg_type: MsgType,
            flags: u8,
            payload: []u8,

            pub fn deinit(self: Frame, alloc: std.mem.Allocator) void {
                alloc.free(self.payload);
            }
        };

        pub fn readAll(fd: c_int, buf: []u8) !void {
            var got: usize = 0;
            while (got < buf.len) {
                const n = C.recv(fd, buf.ptr + got, buf.len - got, 0);
                if (n == 0) return error.Closed;
                if (n < 0) {
                    const e = C.__errno_location().*;
                    if (e == C.EINTR) continue;
                    if (e == C.EAGAIN) return error.Timeout;
                    return error.RecvFailed;
                }
                got += @intCast(n);
            }
        }

        pub fn writeAll(fd: c_int, buf: []const u8) !void {
            const flags: c_int = @intCast(C.MSG_NOSIGNAL);
            var sent: usize = 0;
            while (sent < buf.len) {
                const n = C.send(fd, buf.ptr + sent, buf.len - sent, flags);
                if (n < 0) {
                    if (C.__errno_location().* == C.EINTR) continue;
                    return error.SendFailed;
                }
                sent += @intCast(n);
            }
        }

        pub fn sendFrame(alloc: std.mem.Allocator, fd: c_int, t: MsgType, parts: []const []const u8) !void {
            return sendFrameF(alloc, fd, t, 0, parts);
        }

        pub fn sendFrameF(alloc: std.mem.Allocator, fd: c_int, t: MsgType, flags: u8, parts: []const []const u8) !void {
            var total: usize = 0;
            for (parts) |p| total += p.len;
            if (total > MAX_PAYLOAD) return error.FrameTooLarge;

            const buf = try alloc.alloc(u8, HEADER_LEN + total);
            defer alloc.free(buf);
            buf[0..HEADER_LEN].* = encodeHeader(t, flags, @intCast(total));
            var off: usize = HEADER_LEN;
            for (parts) |p| {
                @memcpy(buf[off..][0..p.len], p);
                off += p.len;
            }
            try writeAll(fd, buf);
        }

        pub fn recvHeader(fd: c_int) !Header {
            var hb: [HEADER_LEN]u8 = undefined;
            try readAll(fd, &hb);
            return decodeHeader(hb);
        }

        pub fn recvFrame(alloc: std.mem.Allocator, fd: c_int) !Frame {
            const h = try recvHeader(fd);
            if (h.len > MAX_PAYLOAD) return error.FrameTooLarge;
            const payload = try alloc.alloc(u8, h.len);
            errdefer alloc.free(payload);
            try readAll(fd, payload);
            return .{ .msg_type = h.msg_type, .flags = h.flags, .payload = payload };
        }

        pub fn sendFile(fd: c_int, path: [:0]const u8, t: MsgType) !void {
            const f = C.open(path.ptr, C.O_RDONLY);
            if (f < 0) return error.OpenFailed;
            defer _ = C.close(f);

            const end = C.lseek(f, 0, C.SEEK_END);
            if (end < 0) return error.StatFailed;
            if (C.lseek(f, 0, C.SEEK_SET) < 0) return error.StatFailed;
            const size: u64 = @intCast(end);
            if (size > MAX_MODEL) return error.FrameTooLarge;

            const hdr = encodeHeader(t, 0, @intCast(size));
            try writeAll(fd, &hdr);

            var chunk: [64 * 1024]u8 = undefined;
            var left: u64 = size;
            while (left > 0) {
                const want: usize = @intCast(@min(left, chunk.len));
                const n = C.read(f, &chunk, want);
                if (n <= 0) return error.ReadFailed;
                const got: usize = @intCast(n);
                try writeAll(fd, chunk[0..got]);
                left -= got;
            }
        }

        pub fn recvToFile(fd: c_int, len: u32, path: [:0]const u8) !void {
            const f = C.open(path.ptr, C.O_WRONLY | C.O_CREAT | C.O_TRUNC, @as(c_uint, 0o600));
            if (f < 0) return error.OpenFailed;
            defer _ = C.close(f);

            var chunk: [64 * 1024]u8 = undefined;
            var left: usize = len;
            while (left > 0) {
                const want = @min(left, chunk.len);
                try readAll(fd, chunk[0..want]);
                var off: usize = 0;
                while (off < want) {
                    const n = C.write(f, &chunk[off], want - off);
                    if (n <= 0) return error.WriteFailed;
                    off += @intCast(n);
                }
                left -= want;
            }
        }
    };
}
