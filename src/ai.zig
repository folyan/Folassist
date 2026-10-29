const std = @import("std");
const c = @import("c");

pub const Message = struct {
    role: []const u8,
    content: []const u8,
};

var history: std.ArrayListUnmanaged(Message) = .empty;
var last_timestamp: i64 = 0;
pub var proxy_url: ?[]const u8 = null;
var active_prompt: ?[]const u8 = null;

pub fn setProxy(p: []const u8) void {
    proxy_url = p;
}

fn capitalize(word: []const u8, buf: *[64]u8) []const u8 {
    if (word.len == 0) return word;
    if (word[0] < 128) {
        @memcpy(buf[0..word.len], word);
        buf[0] = std.ascii.toUpper(word[0]);
        return buf[0..word.len];
    }
    if (word.len >= 2) {
        @memcpy(buf[0..word.len], word);
        const b0 = word[0];
        const b1 = word[1];
        if (b0 == 0xD0 and b1 >= 0xB0 and b1 <= 0xBF) {
            buf[1] = b1 - 0x20;
        } else if (b0 == 0xD1 and b1 >= 0x80 and b1 <= 0x8F) {
            buf[0] = 0xD0;
            buf[1] = b1 + 0x20;
        } else if (b0 == 0xD1 and b1 == 0x91) {
            buf[0] = 0xD0;
            buf[1] = 0x81;
        }
        return buf[0..word.len];
    }
    return word;
}

pub fn initPrompt(allocator: std.mem.Allocator, wake_word: []const u8, custom_prompt_path: ?[]const u8) !void {
    if (active_prompt) |p| allocator.free(p);

    if (custom_prompt_path) |path| {
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);

        const f = c.fopen(path_z.ptr, "rb") orelse {
            try initDefaultPrompt(allocator, wake_word);
            return;
        };
        defer _ = c.fclose(f);

        _ = c.fseek(f, 0, c.SEEK_END);
        const size: usize = @intCast(c.ftell(f));
        _ = c.fseek(f, 0, c.SEEK_SET);

        const content = try allocator.alloc(u8, size);
        _ = c.fread(content.ptr, 1, size, f);

        active_prompt = std.mem.trim(u8, content, " \r\n\t");
        return;
    }

    try initDefaultPrompt(allocator, wake_word);
}

fn initDefaultPrompt(allocator: std.mem.Allocator, wake_word: []const u8) !void {
    var name_buf: [64]u8 = undefined;
    const name = capitalize(wake_word, &name_buf);

    active_prompt = try std.fmt.allocPrint(
        allocator,
        "Ты голосовой ассистент {s}, " ++
            "отвечай на русском языке кратко, одно или два предложения, " ++
            "по существу, без вступлений и воды, " ++
            "тон спокойный, вежливый, нейтрально дружелюбный, " ++
            "без фамильярности, сюсюканья, шуток и уменьшительно ласкательных слов, " ++
            "не используй обращения вроде дружок, малыш, солнышко, дорогой, " ++
            "на приветствие отвечай коротко и по делу, без лишних эмоций, " ++
            "твой ответ будет прочитан голосовым движком вслух, поэтому " ++
            "запрещены точки, вопросительные и восклицательные знаки, звёздочки, " ++
            "решётки, тире, скобки, кавычки, двоеточия, точки с запятой и эмодзи, " ++
            "разделяй предложения и мысли только запятыми, " ++
            "цифры пиши словами, используй исключительно кириллицу, английские слова пиши как должно произноситься",
        .{name},
    );
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (active_prompt) |p| allocator.free(p);
    clearHistory(allocator);
}

pub fn clearHistory(allocator: std.mem.Allocator) void {
    for (history.items) |m| {
        allocator.free(m.role);
        allocator.free(m.content);
    }
    history.clearAndFree(allocator);
}

fn checkTimeout(allocator: std.mem.Allocator) void {
    const now = c.time(null);
    if (last_timestamp != 0 and (now - last_timestamp) > 20 * 60) {
        clearHistory(allocator);
    }
    last_timestamp = now;
}

fn jsonEscape(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    var res: std.ArrayListUnmanaged(u8) = .empty;
    errdefer res.deinit(allocator);
    for (str) |b| {
        switch (b) {
            '"' => try res.appendSlice(allocator, "\\\""),
            '\\' => try res.appendSlice(allocator, "\\\\"),
            '\n' => try res.appendSlice(allocator, " "),
            '\r' => {},
            '\t' => try res.appendSlice(allocator, " "),
            else => try res.append(allocator, b),
        }
    }
    return res.toOwnedSlice(allocator);
}

pub fn cleanForTts(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var last_was_comma = false;
    var last_was_space = false;

    const view = std.unicode.Utf8View.init(text) catch return allocator.dupe(u8, text);
    var it = view.iterator();

    while (it.nextCodepoint()) |cp| {
        switch (cp) {
            '.', '!', '?', ';', '\n' => {
                if (!last_was_comma and result.items.len > 0) {
                    try result.appendSlice(allocator, ", ");
                    last_was_comma = true;
                    last_was_space = true;
                }
            },
            ',' => {
                if (!last_was_comma) {
                    try result.append(allocator, ',');
                    last_was_comma = true;
                }
            },
            '*', '#', '"', '\'', '`', '(', ')', '[', ']', '{', '}', '-', '—', '–', '«', '»', ':', '/' => {},
            ' ', '\t' => {
                if (!last_was_space and result.items.len > 0) {
                    try result.append(allocator, ' ');
                    last_was_space = true;
                }
            },
            else => {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch continue;
                try result.appendSlice(allocator, buf[0..len]);
                last_was_comma = false;
                last_was_space = false;
            },
        }
    }
    return result.toOwnedSlice(allocator);
}

const ApiResponse = struct {
    choices: ?[]const struct {
        message: struct {
            content: ?[]const u8 = null,
        },
    } = null,
    error_obj: ?struct {
        message: []const u8,
    } = null,
};

pub fn ask(allocator: std.mem.Allocator, user_query: []const u8) ![]const u8 {
    checkTimeout(allocator);

    const api_key = c.getenv("GROQ_API_KEY") orelse return error.ApiKeyMissing;

    var json_body: std.ArrayListUnmanaged(u8) = .empty;
    defer json_body.deinit(allocator);

    try json_body.appendSlice(allocator, "{\"model\":\"openai/gpt-oss-20b\",\"include_reasoning\":false,\"messages\":[");

    try json_body.appendSlice(allocator, "{\"role\":\"system\",\"content\":\"");
    const esc_prompt = try jsonEscape(allocator, active_prompt orelse "");
    defer allocator.free(esc_prompt);
    try json_body.appendSlice(allocator, esc_prompt);
    try json_body.appendSlice(allocator, "\"}");

    for (history.items) |m| {
        const esc_content = try jsonEscape(allocator, m.content);
        defer allocator.free(esc_content);

        try json_body.appendSlice(allocator, ",{\"role\":\"");
        try json_body.appendSlice(allocator, m.role);
        try json_body.appendSlice(allocator, "\",\"content\":\"");
        try json_body.appendSlice(allocator, esc_content);
        try json_body.appendSlice(allocator, "\"}");
    }

    const esc_user = try jsonEscape(allocator, user_query);
    defer allocator.free(esc_user);

    try json_body.appendSlice(allocator, ",{\"role\":\"user\",\"content\":\"");
    try json_body.appendSlice(allocator, esc_user);
    try json_body.appendSlice(allocator, "\"}]}");

    const req_file = c.fopen("/tmp/groq_req.json", "wb") orelse return error.TempFileError;
    _ = c.fwrite(json_body.items.ptr, 1, json_body.items.len, req_file);
    _ = c.fclose(req_file);

    var proxy_flag_buf: [300]u8 = undefined;
    var proxy_part: []const u8 = "";
    if (proxy_url) |p| {
        proxy_part = std.fmt.bufPrint(&proxy_flag_buf, "-x \"{s}\" ", .{p}) catch "";
    }

    var cmd_buf: [1536]u8 = undefined;
    const cmd_slice = try std.fmt.bufPrint(
        cmd_buf[0 .. cmd_buf.len - 1],
        "curl -s -m 15 {s}https://api.groq.com/openai/v1/chat/completions -H \"Authorization: Bearer {s}\" -H \"Content-Type: application/json\" --data-binary @/tmp/groq_req.json",
        .{ proxy_part, api_key },
    );
    cmd_buf[cmd_slice.len] = 0;

    const pipe = c.popen(&cmd_buf, "r") orelse return error.CurlFailed;
    defer _ = c.pclose(pipe);

    var resp_list: std.ArrayListUnmanaged(u8) = .empty;
    defer resp_list.deinit(allocator);

    var buf: [1024]u8 = undefined;
    while (true) {
        const bytes = c.fread(&buf, 1, buf.len, pipe);
        if (bytes == 0) break;
        try resp_list.appendSlice(allocator, buf[0..bytes]);
    }

    if (resp_list.items.len == 0) return error.EmptyResponse;

    const parsed = std.json.parseFromSlice(
        ApiResponse,
        allocator,
        resp_list.items,
        .{ .ignore_unknown_fields = true },
    ) catch return error.BadApiResponse;
    defer parsed.deinit();

    if (parsed.value.choices) |ch| {
        if (ch.len > 0 and ch[0].message.content != null) {
            const raw_answer = ch[0].message.content.?;
            const cleaned_answer = try cleanForTts(allocator, raw_answer);

            const saved_user = try allocator.dupe(u8, user_query);
            const saved_assistant = try allocator.dupe(u8, cleaned_answer);

            try history.append(allocator, .{ .role = "user", .content = saved_user });
            try history.append(allocator, .{ .role = "assistant", .content = saved_assistant });

            return cleaned_answer;
        }
    }

    return error.NoChoiceReturned;
}
