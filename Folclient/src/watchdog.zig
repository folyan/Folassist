const std = @import("std");

extern "c" fn fork() c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn sleep(seconds: c_uint) c_uint;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn signal(sig: c_int, handler: ?*const fn (c_int) callconv(.c) void) ?*anyopaque;

const SIGINT: c_int = 2;
const SIGTERM: c_int = 15;
const WNOHANG: c_int = 1;

var child_pid: c_int = 0;
var stopping: bool = false;

fn onStop(_: c_int) callconv(.c) void {
    stopping = true;
    if (child_pid > 0) _ = kill(child_pid, SIGTERM);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: folwatchdog <путь к folclient> [аргументы folclient]\n", .{});
        return;
    }

    const argv_c = try init.arena.allocator().alloc(?[*:0]const u8, args.len);
    for (args[1..], 0..) |a, i| argv_c[i] = a.ptr;
    argv_c[args.len - 1] = null;
    const path = args[1].ptr;

    _ = signal(SIGINT, onStop);
    _ = signal(SIGTERM, onStop);

    while (!stopping) {
        if (child_pid == 0) {
            const pid = fork();
            if (pid == 0) {
                _ = execv(path, argv_c.ptr);
                _exit(127);
            }
            if (pid > 0) {
                child_pid = pid;
                std.debug.print("folwatchdog: запущен folclient (pid {d})\n", .{pid});
            }
        } else {
            var status: c_int = 0;
            const r = waitpid(child_pid, &status, WNOHANG);
            if (r == child_pid) {
                std.debug.print("folwatchdog: folclient завершился (статус {d}), запускаю заново\n", .{status});
                child_pid = 0;
            }
        }
        _ = sleep(1);
    }
}

