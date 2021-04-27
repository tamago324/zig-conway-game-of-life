const std = @import("std");
const time = std.time;

const c = @cImport({
    @cInclude("sys/ioctl.h");
});

// 状態
const STATE = enum { DEAD = 0, LIVE = 1 };

fn Grid() type {
    return struct {
        const Self = @This();

        height: usize,
        width: usize,

        grid: std.ArrayList(std.ArrayList(STATE)),

        // grid の初期化
        // 確保したメモリは呼び出し元が解放する
        pub fn init(allocator: *std.mem.Allocator, height: usize, width: usize) !Self {
            // 初期化
            var grid = std.ArrayList(std.ArrayList(STATE)).init(allocator);

            var i: u8 = 0;
            while (i < height) : (i += 1) {
                var line = std.ArrayList(STATE).init(allocator);
                var j: u8 = 0;
                while (j < width) : (j += 1) {
                    // ランダム
                    const num = std.crypto.random.uintLessThanBiased(u8, 10);
                    try line.append(if (num < 4) .LIVE else .DEAD);
                }
                try grid.append(line);
            }

            return Self{
                .height = height,
                .width = width,
                .grid = grid,
            };
        }

        // 指定のセルの状態を返す
        fn cellValue(self: Self, row: usize, col: usize) STATE {
            return self.grid.items[row].items[col];
        }

        fn isLive(self: Self, row: isize, col: isize) STATE {
            if ((row == -1 or row >= self.height) or (col == -1 or col >= self.width)) {
                // 範囲外なら、dead ってことにする
                return .DEAD;
            }
            return self.cellValue(@intCast(usize, row), @intCast(usize, col));
        }

        // 次の状態を求める
        fn nextState(self: Self, row: u8, col: u8) STATE {
            var live_cnt: u8 = 0;

            // overflow がおきてしまうため、ここで変換
            const irow = @intCast(isize, row);
            const icol = @intCast(isize, col);

            // 周りの生きているセルを確認する
            live_cnt += @enumToInt(self.isLive(irow - 1, icol - 1));
            live_cnt += @enumToInt(self.isLive(irow - 1, icol));
            live_cnt += @enumToInt(self.isLive(irow - 1, icol + 1));
            live_cnt += @enumToInt(self.isLive(irow, icol - 1));
            live_cnt += @enumToInt(self.isLive(irow, icol + 1));
            live_cnt += @enumToInt(self.isLive(irow + 1, icol - 1));
            live_cnt += @enumToInt(self.isLive(irow + 1, icol));
            live_cnt += @enumToInt(self.isLive(irow + 1, icol + 1));

            if (self.cellValue(row, col) == .DEAD) {
                // dead
                if (live_cnt == 3) {
                    // 誕生
                    return .LIVE;
                }
            } else {
                if (live_cnt == 2 or live_cnt == 3) {
                    // 維持
                    return .LIVE;
                } else if (live_cnt < 2) {
                    // 過疎
                    return .DEAD;
                } else if (live_cnt >= 4) { // 過密
                    return .DEAD;
                }
            }
            return .DEAD;
        }

        // 次の世代に移る
        // 確保したメモリは呼び出し元が解放する
        fn nextGeneration(self: *Self, allocator: *std.mem.Allocator) !void {
            var new_grid = std.ArrayList(std.ArrayList(STATE)).init(allocator);

            var i: u8 = 0;
            while (i < self.height) : (i += 1) {
                var line = std.ArrayList(STATE).init(allocator);
                var j: u8 = 0;
                while (j < self.width) : (j += 1) {
                    try line.append(self.nextState(i, j));
                }
                try new_grid.append(line);
            }

            self.grid = new_grid;
        }

        fn refresh(self: *Self, bfwriter: anytype) !void {
            // ESC は 16進数で \x1B となる
            // ESC[2J で画面クリア

            // 画面のクリア
            try bfwriter.writer().print("\x1B[2J\x1B[H", .{});
            try bfwriter.flush();
        }

        // 描画
        pub fn update(self: *Self, bfwriter: anytype) !void {
            try self.refresh(bfwriter);

            // TODO: 配列に入れて、１つ文字列を表示させる

            var row: u8 = 0;
            while (row < self.height) : (row += 1) {
                try bfwriter.writer().print("\n", .{});

                var col: u8 = 0;
                while (col < self.width) : (col += 1) {
                    const ch = switch (self.cellValue(row, col)) {
                        .DEAD => "  ",
                        // ESC[7m 背景色を反転させる
                        // ESC[0m 戻す
                        .LIVE => "\x1B[7m  \x1B[0m",
                    };
                    _ = try bfwriter.writer().write(ch);
                }
            }

            try bfwriter.flush();
        }
    };
}

const Size = struct {
    columns: usize,
    rows: usize,
};

// ターミナルのサイズを取得する
fn winsize() Size {
    var ws: c.winsize = undefined;
    var stdout = std.io.getStdOut();

    if (c.ioctl(stdout.handle, c.TIOCGWINSZ, &ws) != -1) {
        return .{
            .columns = ws.ws_col,
            .rows = ws.ws_row,
        };
    }
    unreachable;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    const args = try std.process.argsAlloc(allocator);
    if (args.len == 2 and std.mem.eql(u8, args[1], "-h")) {
        const help_text =
            \\Usage:
            \\  gameoflife [num]
            \\
            \\Options:
            \\  num         Forward generation in num milliseconds, instead of 200 milliseconds.
            \\  -h, --help  Show help.
            \\
        ;
        try std.io.getStdOut().writeAll(help_text);
        return;
    }

    // ミリ秒の間隔
    const ms: usize = blk: {
        if (args.len == 1) {
            break :blk 200;
        }

        break :blk std.fmt.parseInt(usize, args[1], 10) catch 200;
    };
    const ms_interval = ms * time.ns_per_ms;

    // 現在のターミナルのサイズを取得し、それに合わせて、設定する
    var size = winsize();
    var width = size.columns / 2;
    var grid = try Grid().init(allocator, size.rows, width);

    var bfwriter = std.io.bufferedWriter(std.io.getStdOut().writer());

    while (true) {
        try grid.update(&bfwriter);
        try grid.nextGeneration(allocator);
        time.sleep(ms_interval);
    }
}
