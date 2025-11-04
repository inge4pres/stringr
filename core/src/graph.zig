const std = @import("std");
const pipeline = @import("pipeline.zig");

/// Represents execution levels for parallel execution
pub const ExecutionPlan = struct {
    levels: [][]usize, // Each level contains indices of steps that can run in parallel
    allocator: std.mem.Allocator,

    pub fn deinit(self: ExecutionPlan) void {
        for (self.levels) |level| {
            self.allocator.free(level);
        }
        self.allocator.free(self.levels);
    }
};

/// Errors related to processing the build graph.
pub const GraphError = error{
    // A step has a dependency on a non-existent step
    InvalidDependency,
    // There is a circular dependency in the steps
    CircularDependency,
};

/// Compute execution levels from pipeline dependencies
/// Returns an error if there are circular dependencies
pub fn computeExecutionPlan(allocator: std.mem.Allocator, pipe: pipeline.Pipeline) !ExecutionPlan {
    const step_count = pipe.steps.len;

    // Build a dependency map: step_id -> step_index
    var step_indices = std.StringHashMap(usize).init(allocator);
    defer step_indices.deinit();

    for (pipe.steps, 0..) |step, i| {
        try step_indices.put(step.id, i);
    }

    // Compute in-degree for each step (number of dependencies)
    var in_degree = try allocator.alloc(usize, step_count);
    defer allocator.free(in_degree);
    @memset(in_degree, 0);

    for (pipe.steps, 0..) |step, i| {
        for (step.depends_on) |dep_id| {
            if (step_indices.get(dep_id)) |_| {
                in_degree[i] += 1;
            } else {
                // Dependency not found - invalid pipeline
                return GraphError.InvalidDependency;
            }
        }
    }

    // Topological sort with level assignment
    const LevelListManaged = std.array_list.AlignedManaged([]usize, null);
    var levels = LevelListManaged.init(allocator);
    errdefer {
        for (levels.items) |level| {
            allocator.free(level);
        }
        levels.deinit();
    }

    var processed = try allocator.alloc(bool, step_count);
    defer allocator.free(processed);
    @memset(processed, false);

    var total_processed: usize = 0;

    while (total_processed < step_count) {
        // Find all steps with in_degree == 0 that haven't been processed
        const StepListManaged = std.array_list.AlignedManaged(usize, null);
        var current_level = StepListManaged.init(allocator);
        errdefer current_level.deinit();

        for (pipe.steps, 0..) |_, i| {
            if (!processed[i] and in_degree[i] == 0) {
                try current_level.append(i);
            }
        }

        if (current_level.items.len == 0) {
            // No steps can be processed - circular dependency
            current_level.deinit();
            return GraphError.CircularDependency;
        }

        // Mark these steps as processed and reduce in_degree of dependents
        for (current_level.items) |step_idx| {
            processed[step_idx] = true;
            total_processed += 1;

            const step_id = pipe.steps[step_idx].id;

            // Reduce in_degree for all steps that depend on this one
            for (pipe.steps, 0..) |other_step, other_idx| {
                for (other_step.depends_on) |dep_id| {
                    if (std.mem.eql(u8, dep_id, step_id)) {
                        in_degree[other_idx] -= 1;
                    }
                }
            }
        }

        try levels.append(try current_level.toOwnedSlice());
    }

    return ExecutionPlan{
        .levels = try levels.toOwnedSlice(),
        .allocator = allocator,
    };
}

test "compute execution plan - simple linear" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var steps = try allocator.alloc(pipeline.Step, 2);

    var env1 = std.StringHashMap([]const u8).init(allocator);
    defer env1.deinit();
    var env2 = std.StringHashMap([]const u8).init(allocator);
    defer env2.deinit();

    steps[0] = pipeline.Step{
        .id = try allocator.dupe(u8, "step1"),
        .name = try allocator.dupe(u8, "Step 1"),
        .action = pipeline.Action{ .shell = .{ .command = try allocator.dupe(u8, "echo 1"), .working_dir = null } },
        .depends_on = &.{},
        .env = env1,
    };

    const dep = try allocator.dupe(u8, "step1");
    const deps = try allocator.alloc([]const u8, 1);
    deps[0] = dep;

    steps[1] = pipeline.Step{
        .id = try allocator.dupe(u8, "step2"),
        .name = try allocator.dupe(u8, "Step 2"),
        .action = pipeline.Action{ .shell = .{ .command = try allocator.dupe(u8, "echo 2"), .working_dir = null } },
        .depends_on = deps,
        .env = env2,
    };

    const pipe = pipeline.Pipeline{
        .name = try allocator.dupe(u8, "test"),
        .description = try allocator.dupe(u8, "test"),
        .steps = steps,
    };
    defer pipe.deinit(allocator);

    const plan = try computeExecutionPlan(allocator, pipe);
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 2), plan.levels.len);
    try testing.expectEqual(@as(usize, 1), plan.levels[0].len);
    try testing.expectEqual(@as(usize, 1), plan.levels[1].len);
    try testing.expectEqual(@as(usize, 0), plan.levels[0][0]);
    try testing.expectEqual(@as(usize, 1), plan.levels[1][0]);
}

test "compute execution plan - parallel steps" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var steps = try allocator.alloc(pipeline.Step, 3);

    var env1 = std.StringHashMap([]const u8).init(allocator);
    defer env1.deinit();
    var env2 = std.StringHashMap([]const u8).init(allocator);
    defer env2.deinit();
    var env3 = std.StringHashMap([]const u8).init(allocator);
    defer env3.deinit();

    // Step 1: no dependencies
    steps[0] = pipeline.Step{
        .id = try allocator.dupe(u8, "step1"),
        .name = try allocator.dupe(u8, "Step 1"),
        .action = pipeline.Action{ .shell = .{ .command = try allocator.dupe(u8, "echo 1"), .working_dir = null } },
        .depends_on = &.{},
        .env = env1,
    };

    // Step 2: depends on step1
    const dep1 = try allocator.dupe(u8, "step1");
    const deps1 = try allocator.alloc([]const u8, 1);
    deps1[0] = dep1;

    steps[1] = pipeline.Step{
        .id = try allocator.dupe(u8, "step2"),
        .name = try allocator.dupe(u8, "Step 2"),
        .action = pipeline.Action{ .shell = .{ .command = try allocator.dupe(u8, "echo 2"), .working_dir = null } },
        .depends_on = deps1,
        .env = env2,
    };

    // Step 3: also depends on step1 (can run in parallel with step2)
    const dep2 = try allocator.dupe(u8, "step1");
    const deps2 = try allocator.alloc([]const u8, 1);
    deps2[0] = dep2;

    steps[2] = pipeline.Step{
        .id = try allocator.dupe(u8, "step3"),
        .name = try allocator.dupe(u8, "Step 3"),
        .action = pipeline.Action{ .shell = .{ .command = try allocator.dupe(u8, "echo 3"), .working_dir = null } },
        .depends_on = deps2,
        .env = env3,
    };

    const pipe = pipeline.Pipeline{
        .name = try allocator.dupe(u8, "test"),
        .description = try allocator.dupe(u8, "test"),
        .steps = steps,
    };
    defer pipe.deinit(allocator);

    const plan = try computeExecutionPlan(allocator, pipe);
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 2), plan.levels.len);
    try testing.expectEqual(@as(usize, 1), plan.levels[0].len); // step1
    try testing.expectEqual(@as(usize, 2), plan.levels[1].len); // step2 and step3 in parallel
}

test "compute execution plan - missing dependency error" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var steps = try allocator.alloc(pipeline.Step, 2);

    var env1 = std.StringHashMap([]const u8).init(allocator);
    defer env1.deinit();
    var env2 = std.StringHashMap([]const u8).init(allocator);
    defer env2.deinit();

    // Step 1: no dependencies
    steps[0] = pipeline.Step{
        .id = try allocator.dupe(u8, "step1"),
        .name = try allocator.dupe(u8, "Step 1"),
        .action = pipeline.Action{ .shell = .{ .command = try allocator.dupe(u8, "echo 1"), .working_dir = null } },
        .depends_on = &.{},
        .env = env1,
    };

    // Step 2: depends on non-existent step
    const dep = try allocator.dupe(u8, "nonexistent_step");
    const deps = try allocator.alloc([]const u8, 1);
    deps[0] = dep;

    steps[1] = pipeline.Step{
        .id = try allocator.dupe(u8, "step2"),
        .name = try allocator.dupe(u8, "Step 2"),
        .action = pipeline.Action{ .shell = .{ .command = try allocator.dupe(u8, "echo 2"), .working_dir = null } },
        .depends_on = deps,
        .env = env2,
    };

    const pipe = pipeline.Pipeline{
        .name = try allocator.dupe(u8, "test"),
        .description = try allocator.dupe(u8, "test"),
        .steps = steps,
    };
    defer pipe.deinit(allocator);

    const result = computeExecutionPlan(allocator, pipe);
    try testing.expectError(GraphError.InvalidDependency, result);
}

test "compute execution plan - circular dependency error" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var steps = try allocator.alloc(pipeline.Step, 3);

    var env1 = std.StringHashMap([]const u8).init(allocator);
    defer env1.deinit();
    var env2 = std.StringHashMap([]const u8).init(allocator);
    defer env2.deinit();
    var env3 = std.StringHashMap([]const u8).init(allocator);
    defer env3.deinit();

    // Step 1: depends on step3 (creates circular dependency)
    const dep1 = try allocator.dupe(u8, "step3");
    const deps1 = try allocator.alloc([]const u8, 1);
    deps1[0] = dep1;

    steps[0] = pipeline.Step{
        .id = try allocator.dupe(u8, "step1"),
        .name = try allocator.dupe(u8, "Step 1"),
        .action = pipeline.Action{ .shell = .{ .command = try allocator.dupe(u8, "echo 1"), .working_dir = null } },
        .depends_on = deps1,
        .env = env1,
    };

    // Step 2: depends on step1
    const dep2 = try allocator.dupe(u8, "step1");
    const deps2 = try allocator.alloc([]const u8, 1);
    deps2[0] = dep2;

    steps[1] = pipeline.Step{
        .id = try allocator.dupe(u8, "step2"),
        .name = try allocator.dupe(u8, "Step 2"),
        .action = pipeline.Action{ .shell = .{ .command = try allocator.dupe(u8, "echo 2"), .working_dir = null } },
        .depends_on = deps2,
        .env = env2,
    };

    // Step 3: depends on step2 (completes the circular dependency: step1 -> step3 -> step2 -> step1)
    const dep3 = try allocator.dupe(u8, "step2");
    const deps3 = try allocator.alloc([]const u8, 1);
    deps3[0] = dep3;

    steps[2] = pipeline.Step{
        .id = try allocator.dupe(u8, "step3"),
        .name = try allocator.dupe(u8, "Step 3"),
        .action = pipeline.Action{ .shell = .{ .command = try allocator.dupe(u8, "echo 3"), .working_dir = null } },
        .depends_on = deps3,
        .env = env3,
    };

    const pipe = pipeline.Pipeline{
        .name = try allocator.dupe(u8, "test"),
        .description = try allocator.dupe(u8, "test"),
        .steps = steps,
    };
    defer pipe.deinit(allocator);

    const result = computeExecutionPlan(allocator, pipe);
    try testing.expectError(GraphError.CircularDependency, result);
}
