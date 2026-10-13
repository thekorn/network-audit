const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .link_libc = true,
    });
    const exe = b.addExecutable(.{ .name = "network-audit-zig", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the experimental audit CLI").dependOn(&run.step);
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = module }));
    b.step("test", "Test reports, configuration and owned processes").dependOn(&tests.step);
}
