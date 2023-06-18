const std = @import("std");

const a = @cImport({
    @cInclude("alsa/asoundlib.h");
});

pub fn open(name: []const u8, stream: Stream) Errors!Device {
    if (stream == Stream.capture) {
        return error.Capture;
    }

    var pcm: ?*a.snd_pcm_t = null;

    if (a.snd_pcm_open(&pcm, name.ptr, @intCast(c_uint, @enumToInt(stream)), a.SND_PCM_NONBLOCK) != 0) {
        return error.InvalidConfig;
    }
    _ = pcm orelse return error.InvalidConfig;
    errdefer _ = a.snd_pcm_close(pcm);

    return Device{
        .config = undefined,
        .runtime = Runtime{
            .buffer = undefined,
            .pcm = pcm,
        },
    };
}

pub fn configure(device: *Device, config: Config) Errors!void {
    var pcm = device.runtime.pcm orelse return error.Api;
    if (a.snd_pcm_state(pcm) != a.SND_PCM_STATE_OPEN) {
        return error.Api;
    }

    var hw_params: ?*a.snd_pcm_hw_params_t = null;
    if (a.snd_pcm_hw_params_malloc(&hw_params) != 0) {
        return error.InvalidConfig;
    }
    defer a.snd_pcm_hw_params_free(hw_params);
    _ = a.snd_pcm_hw_params_any(pcm, hw_params);

    if (a.snd_pcm_hw_params_set_access(pcm, hw_params, @intCast(c_uint, @enumToInt(config.access))) != 0) {
        return error.InvalidConfig;
    }
    if (a.snd_pcm_hw_params_set_channels(pcm, hw_params, config.channels) != 0) {
        return error.InvalidConfig;
    }
    if (a.snd_pcm_hw_params_set_format(pcm, hw_params, @enumToInt(config.format)) != 0) {
        return error.InvalidConfig;
    }
    if (a.snd_pcm_hw_params_set_period_size(pcm, hw_params, config.frames, 0) != 0) {
        return error.InvalidConfig;
    }
    if (a.snd_pcm_hw_params_set_periods(pcm, hw_params, config.periods, 0) != 0) {
        return error.InvalidConfig;
    }
    if (a.snd_pcm_hw_params_set_rate(pcm, hw_params, config.frequency, 0) != 0) {
        return error.InvalidConfig;
    }
    if (a.snd_pcm_hw_params_set_rate_resample(pcm, hw_params, 0) != 0) {
        return error.InvalidConfig;
    }
    if (a.snd_pcm_hw_params(pcm, hw_params) != 0) {
        return error.InvalidConfig;
    }

    var sw_params: ?*a.snd_pcm_sw_params_t = null;
    if (a.snd_pcm_sw_params_malloc(&sw_params) != 0) {
        return error.InvalidConfig;
    }
    defer a.snd_pcm_sw_params_free(sw_params);
    _ = a.snd_pcm_sw_params_current(pcm, sw_params);

    if (a.snd_pcm_sw_params_set_avail_min(pcm, sw_params, config.frames) != 0) {
        return error.InvalidConfig;
    }
    if (a.snd_pcm_sw_params_set_silence_threshold(pcm, sw_params, 0) != 0) {
        return error.InvalidConfig;
    }
    if (a.snd_pcm_sw_params_set_start_threshold(pcm, sw_params, 2 * (config.frames * config.periods)) != 0) {
        return error.InvalidConfig;
    }
    if (a.snd_pcm_sw_params_set_stop_threshold(pcm, sw_params, 0) != 0) {
        return error.InvalidConfig;
    }
    if (a.snd_pcm_sw_params_set_tstamp_mode(pcm, sw_params, a.SND_PCM_TSTAMP_NONE) != 0) {
        return error.InvalidConfig;
    }
    if (a.snd_pcm_sw_params_set_tstamp_type(pcm, sw_params, a.SND_PCM_TSTAMP_TYPE_MONOTONIC) != 0) {
        return error.InvalidConfig;
    }
    if (a.snd_pcm_sw_params(pcm, sw_params) != 0) {
        return error.InvalidConfig;
    }

    if (a.snd_pcm_avail_update(pcm) != (config.frames * config.periods)) {
        return error.InvalidConfig;
    }

    device.config = config;
    device.runtime.buffer = Buffer{
        .bytes = @intCast(u32, device.config.frames * device.config.channels * @divExact(a.snd_pcm_format_width(@enumToInt(device.config.format)), 8)),
        .channels = device.config.channels,
        .data = undefined,
        .format = device.config.format,
        .frames = device.config.frames,
        .frequency = device.config.frequency,
        .offset = undefined,
    };
}

pub fn start(device: *Device) Errors!void {
    var pcm: *a.snd_pcm_t = device.runtime.pcm orelse return error.Api;
    if (a.snd_pcm_state(pcm) != a.SND_PCM_STATE_PREPARED) {
        return error.Api;
    }

    if (a.snd_pcm_start(pcm) != 0) return error.Api;
}

pub fn aquire(device: *Device) Errors!Buffer {
    var pcm: *a.snd_pcm_t = device.runtime.pcm orelse return error.Api;

    if (a.snd_pcm_state(pcm) == a.SND_PCM_STATE_RUNNING) {
        if (a.snd_pcm_wait(pcm, a.SND_PCM_WAIT_INFINITE) < 0) {
            return error.Xrun;
        }
    }

    _ = a.snd_pcm_avail_update(pcm);

    var area: ?*a.snd_pcm_channel_area_t = null;
    var frames: a.snd_pcm_uframes_t = @intCast(c_ulong, device.config.frames);
    var offset: a.snd_pcm_uframes_t = @intCast(c_ulong, 0);

    if (a.snd_pcm_mmap_begin(pcm, &area, &offset, &frames) != 0) {
        return error.Xrun;
    }

    if (frames != device.config.frames) {
        return error.BufferFragmentation;
    }

    device.runtime.buffer.data = (@ptrCast([*]u8, area.?.addr) + @intCast(u32, (area.?.first + area.?.step * offset) / 8))[0..(@intCast(usize, device.runtime.buffer.bytes))];
    device.runtime.buffer.offset = @intCast(u32, offset);

    return device.runtime.buffer;
}

pub fn submit(device: *Device, buffer: Buffer) Errors!void {
    var pcm: *a.snd_pcm_t = device.runtime.pcm orelse return error.Api;

    if (a.snd_pcm_mmap_commit(pcm, buffer.offset, buffer.frames) != buffer.frames) {
        return error.Xrun;
    }
}

pub fn stop(device: *Device) Errors!void {
    var pcm: *a.snd_pcm_t = device.runtime.pcm orelse return error.Api;

    if (a.snd_pcm_state(pcm) == a.SND_PCM_STATE_RUNNING) {
        _ = a.snd_pcm_drain(pcm);
    } else {
        _ = a.snd_pcm_drop(pcm);
    }

    _ = a.snd_pcm_prepare(pcm);
}

pub fn close(device: *Device) Errors!void {
    _ = stop(device) catch {};
    if (device.runtime.pcm) |pcm| _ = a.snd_pcm_close(pcm);
    device.runtime.pcm = null;
}

pub fn state(device: *Device) State {
    var pcm: *a.snd_pcm_t = device.runtime.pcm orelse return State.disconnected;
    return @intToEnum(State, a.snd_pcm_state(pcm));
}

pub const Access = enum(i32) {
    interleaved = a.SND_PCM_ACCESS_MMAP_INTERLEAVED,
    noninterleaved = a.SND_PCM_ACCESS_MMAP_NONINTERLEAVED,
};

pub const Format = enum(i32) {
    float_32_be = a.SND_PCM_FORMAT_FLOAT_BE,
    float_32_le = a.SND_PCM_FORMAT_FLOAT_LE,
    float_64_be = a.SND_PCM_FORMAT_FLOAT64_BE,
    float_64_le = a.SND_PCM_FORMAT_FLOAT64_LE,
    signed_16_be = a.SND_PCM_FORMAT_S16_BE,
    signed_16_le = a.SND_PCM_FORMAT_S16_LE,
    signed_24_be = a.SND_PCM_FORMAT_S24_BE,
    signed_24_le = a.SND_PCM_FORMAT_S24_LE,
    signed_32_be = a.SND_PCM_FORMAT_S32_BE,
    signed_32_le = a.SND_PCM_FORMAT_S32_LE,
    signed_8 = a.SND_PCM_FORMAT_S8,
    unsigned_16_be = a.SND_PCM_FORMAT_U16_BE,
    unsigned_16_le = a.SND_PCM_FORMAT_U16_LE,
    unsigned_24_be = a.SND_PCM_FORMAT_U24_BE,
    unsigned_24_le = a.SND_PCM_FORMAT_U24_LE,
    unsigned_32_be = a.SND_PCM_FORMAT_U32_BE,
    unsigned_32_le = a.SND_PCM_FORMAT_U32_LE,
    unsigned_8 = a.SND_PCM_FORMAT_U8,
};

pub const State = enum(i32) {
    open = a.SND_PCM_STATE_OPEN,
    setup = a.SND_PCM_STATE_SETUP,
    prepared = a.SND_PCM_STATE_PREPARED,
    running = a.SND_PCM_STATE_RUNNING,
    xrun = a.SND_PCM_STATE_XRUN,
    draining = a.SND_PCM_STATE_DRAINING,
    paused = a.SND_PCM_STATE_PAUSED,
    suspended = a.SND_PCM_STATE_SUSPENDED,
    disconnected = a.SND_PCM_STATE_DISCONNECTED,
};

pub const Stream = enum(i32) {
    capture = a.SND_PCM_STREAM_CAPTURE,
    playback = a.SND_PCM_STREAM_PLAYBACK,
};

pub const Config = struct {
    access: Access,
    channels: u8,
    format: Format,
    frames: u16,
    frequency: u32,
    periods: u8,
};

pub const Runtime = struct {
    buffer: Buffer,
    pcm: ?*a.snd_pcm_t,
};

pub const Device = struct {
    config: Config,
    runtime: Runtime,
};

pub const Buffer = struct {
    bytes: u32,
    channels: u32,
    data: []u8,
    format: Format,
    frames: u32,
    frequency: u32,
    offset: u32,
};

pub const MissingFeatures = error{
    AutoConfigure,
    BufferFragmentation,
    Capture,
    MultipleDevices,
    NotSupported,
};

pub const FatalErrors = error{
    Api,
    InvalidConfig,
    Processing,
    Xrun,
};

pub const Errors = FatalErrors || MissingFeatures;
