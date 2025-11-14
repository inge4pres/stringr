const std = @import("std");

/// Represents a condition that determines whether a step should execute
pub const Condition = union(enum) {
    /// Always execute (default behavior)
    always: void,

    /// Never execute (useful for disabling steps)
    never: void,

    /// Check if an environment variable equals a specific value
    env_equals: EnvEqualsCondition,

    /// Check if an environment variable exists (is defined)
    env_exists: EnvExistsCondition,

    /// Check if a file or directory exists
    file_exists: FileExistsCondition,

    pub fn deinit(self: Condition, allocator: std.mem.Allocator) void {
        switch (self) {
            .env_equals => |c| c.deinit(allocator),
            .env_exists => |c| c.deinit(allocator),
            .file_exists => |c| c.deinit(allocator),
            .always, .never => {},
        }
    }

    /// Generate Zig code that evaluates this condition
    /// Returns a string representing a boolean expression
    pub fn generateCode(self: Condition, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .always => try allocator.dupe(u8, "true"),
            .never => try allocator.dupe(u8, "false"),
            .env_equals => |c| try std.fmt.allocPrint(
                allocator,
                "checkEnvEquals(\"{s}\", \"{s}\")",
                .{ c.variable, c.value }
            ),
            .env_exists => |c| try std.fmt.allocPrint(
                allocator,
                "checkEnvExists(\"{s}\")",
                .{c.variable}
            ),
            .file_exists => |c| try std.fmt.allocPrint(
                allocator,
                "checkFileExists(\"{s}\")",
                .{c.path}
            ),
        };
    }
};

pub const EnvEqualsCondition = struct {
    variable: []const u8,
    value: []const u8,

    pub fn deinit(self: EnvEqualsCondition, allocator: std.mem.Allocator) void {
        allocator.free(self.variable);
        allocator.free(self.value);
    }
};

pub const EnvExistsCondition = struct {
    variable: []const u8,

    pub fn deinit(self: EnvExistsCondition, allocator: std.mem.Allocator) void {
        allocator.free(self.variable);
    }
};

pub const FileExistsCondition = struct {
    path: []const u8,

    pub fn deinit(self: FileExistsCondition, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

// Tests
test "condition always generates correct code" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cond = Condition{ .always = {} };
    const code = try cond.generateCode(allocator);
    defer allocator.free(code);

    try testing.expectEqualStrings("true", code);
}

test "condition never generates correct code" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cond = Condition{ .never = {} };
    const code = try cond.generateCode(allocator);
    defer allocator.free(code);

    try testing.expectEqualStrings("false", code);
}

test "env_equals generates correct code" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cond = Condition{
        .env_equals = .{
            .variable = try allocator.dupe(u8, "BUILD_ENV"),
            .value = try allocator.dupe(u8, "production"),
        }
    };
    defer cond.deinit(allocator);

    const code = try cond.generateCode(allocator);
    defer allocator.free(code);

    try testing.expectEqualStrings("checkEnvEquals(\"BUILD_ENV\", \"production\")", code);
}

test "env_exists generates correct code" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cond = Condition{
        .env_exists = .{
            .variable = try allocator.dupe(u8, "CI"),
        }
    };
    defer cond.deinit(allocator);

    const code = try cond.generateCode(allocator);
    defer allocator.free(code);

    try testing.expectEqualStrings("checkEnvExists(\"CI\")", code);
}

test "file_exists generates correct code" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cond = Condition{
        .file_exists = .{
            .path = try allocator.dupe(u8, ".git/config"),
        }
    };
    defer cond.deinit(allocator);

    const code = try cond.generateCode(allocator);
    defer allocator.free(code);

    try testing.expectEqualStrings("checkFileExists(\".git/config\")", code);
}
