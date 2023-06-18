const std = @import("std");
const sound = @import("sound.zig");
const testing = std.testing;

test "basic operation" {
    var device = try sound.open(
        "default",
        sound.Stream.playback,
    );
    try testing.expectEqual(sound.state(&device), sound.State.open);

    try sound.configure(&device, sound.Config{
        .access = sound.Access.interleaved,
        .channels = 2,
        .format = sound.Format.signed_32_le,
        .frames = 512,
        .frequency = 48_000,
        .periods = 2,
    });
    try testing.expectEqual(sound.state(&device), sound.State.prepared);

    var frame_counter: u32 = 0;
    const buf = try sound.aquire(&device);
    _ = try fill_silence(&frame_counter, buf);
    _ = try sound.submit(&device, buf);
    try testing.expectEqual(sound.state(&device), sound.State.prepared);

    try sound.start(&device);
    try testing.expectEqual(sound.state(&device), sound.State.running);

    try sound.stop(&device);
    try testing.expectEqual(sound.state(&device), sound.State.prepared);

    try sound.close(&device);
    try testing.expectEqual(sound.state(&device), sound.State.disconnected);
}

test "capture" {
    _ = sound.open("default", sound.Stream.capture) catch |e| {
        try testing.expectEqual(e, sound.MissingFeatures.Capture);
    };
}

test "playback on fly" {
    var device = try sound.open(
        "default",
        sound.Stream.playback,
    );
    defer _ = sound.close(&device) catch {};

    _ = try sound.configure(&device, sound.Config{
        .access = sound.Access.interleaved,
        .channels = 2,
        .format = sound.Format.signed_32_le,
        .frames = 480,
        .frequency = 48_000,
        .periods = 2,
    });

    var frame_counter: u32 = 0;

    const buf = try sound.aquire(&device);
    _ = try play_2khz_sine_on_48khz(&frame_counter, buf);
    _ = try sound.submit(&device, buf);

    _ = try sound.start(&device);
    defer _ = sound.stop(&device) catch {};

    while (frame_counter < 48_000) {
        const buffer = try sound.aquire(&device);
        _ = try play_2khz_sine_on_48khz(&frame_counter, buffer);
        _ = try sound.submit(&device, buffer);
    }
}

fn rerange(value: anytype, from_min: @TypeOf(value), from_max: @TypeOf(value), to_min: @TypeOf(value), to_max: @TypeOf(value)) @TypeOf(value) {
    return ((value - from_min) * (to_max - to_min) / (from_max - from_min)) + to_min;
}

fn sine_sample_type(comptime format: type, sine_hz: u32, sample_hz: u32) type {
    return [@divExact(sample_hz, sine_hz)]format;
}

fn gen_sine(comptime sample_format: type, sine_hz: u32, sample_hz: u32) sine_sample_type(sample_format, sine_hz, sample_hz) {
    var samples: sine_sample_type(sample_format, sine_hz, sample_hz) = undefined;

    var i: u32 = 0;
    for (samples) |*sample| {
        var s: f64 = (2 * std.math.pi * @intToFloat(f32, sine_hz) * @intToFloat(f32, @rem(i, sample_hz))) / @intToFloat(f64, sample_hz);
        i += 1;
        var sin: f64 = std.math.sin(s);
        var value: f64 = @round(rerange(sin, -1, 1, std.math.minInt(sample_format), std.math.maxInt(sample_format)));
        sample.* = @floatToInt(sample_format, value);
    }

    return samples;
}

fn play_2khz_sine_on_48khz(user: ?*anyopaque, buffer: sound.Buffer) sound.Errors!void {
    const sine_samples = comptime gen_sine(i32, 2000, 48_000);
    var output_samples = std.mem.bytesAsSlice(i32, buffer.data);

    const frame_counter = @ptrCast(*u32, @alignCast(4, user));

    var sample_counter: u32 = 0;
    while (sample_counter < output_samples.len) : (sample_counter += buffer.channels) {
        var channel_counter: u32 = 0;
        while (channel_counter < buffer.channels) : (channel_counter += 1) {
            output_samples[sample_counter + channel_counter] = sine_samples[@rem(frame_counter.*, sine_samples.len)];
        }
        frame_counter.* +%= 1;
    }
}

fn fill_silence(user: ?*anyopaque, buffer: sound.Buffer) sound.Errors!void {
    var output_samples = std.mem.bytesAsSlice(i32, buffer.data);

    const frame_counter = @ptrCast(*u32, @alignCast(4, user));

    var sample_counter: u32 = 0;
    while (sample_counter < output_samples.len) : (sample_counter += buffer.channels) {
        var channel_counter: u32 = 0;
        while (channel_counter < buffer.channels) : (channel_counter += 1) {
            output_samples[sample_counter + channel_counter] = 0;
        }
        frame_counter.* +%= 1;
    }
}
