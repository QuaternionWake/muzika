const endian = @import("std").builtin.Endian.native;

/// Generic error that means something went wrong in SDL.
/// Use `getError()` to get more details.
const Error = error{SdlError};

/// Convenience function for straightforward audio init for the common case.
///
/// If all your app intends to do is provide a single source of PCM audio, this
/// function allows you to do all your audio setup in a single call.
///
/// This is also intended to be a clean means to migrate apps from SDL2.
///
/// This function will open an audio device, create a stream and bind it.
/// Unlike other methods of setup, the audio device will be closed when this
/// stream is destroyed, so the app can treat the returned SDL_AudioStream as
/// the only object needed to manage audio playback.
///
/// Also unlike other functions, the audio device begins paused. This is to map
/// more closely to SDL2-style behavior, since there is no extra step here to
/// bind a stream to begin audio flowing. The audio device should be resumed
/// with SDL_ResumeAudioStreamDevice().
///
/// This function works with both playback and recording devices.
///
/// The `spec` parameter represents the app's side of the audio stream. That
/// is, for recording audio, this will be the output format, and for playing
/// audio, this will be the input format. If spec is NULL, the system will
/// choose the format, and the app can use SDL_GetAudioStreamFormat() to obtain
/// this information later.
///
/// If you don't care about opening a specific audio device, you can (and
/// probably _should_), use SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK for playback and
/// SDL_AUDIO_DEVICE_DEFAULT_RECORDING for recording.
///
/// One can optionally provide a callback function; if NULL, the app is
/// expected to queue audio data for playback (or unqueue audio data if
/// capturing). Otherwise, the callback will begin to fire once the device is
/// unpaused.
///
/// Destroying the returned stream with SDL_DestroyAudioStream will also close
/// the audio device associated with this stream.
///
/// \param devid an audio device to open, or SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK
///              or SDL_AUDIO_DEVICE_DEFAULT_RECORDING.
/// \param spec the audio stream's data format. Can be NULL.
/// \param callback a callback where the app will provide new data for
///                 playback, or receive new data for recording. Can be NULL,
///                 in which case the app will need to call
///                 SDL_PutAudioStreamData or SDL_GetAudioStreamData as
///                 necessary.
/// \param userdata app-controlled pointer passed to callback. Can be NULL.
///                 Ignored if callback is NULL.
/// \returns an audio stream on success, ready to use, or NULL on failure; call
///          SDL_GetError() for more information. When done with this stream,
///          call SDL_DestroyAudioStream to free resources and close the
///          device.
///
/// \threadsafety It is safe to call this function from any thread.
///
/// \since This function is available since SDL 3.2.0.
///
/// \sa SDL_GetAudioStreamDevice
/// \sa SDL_ResumeAudioStreamDevice
pub fn openAudioDeviceStream(devid: AudioDeviceId, spec: *const AudioSpec, callback: ?*AudioStreamCallback, userdata: ?*anyopaque) !*AudioStream {
    return SDL_OpenAudioDeviceStream(devid, spec, callback, userdata) orelse Error.SdlError;
}
extern "SDL3" fn SDL_OpenAudioDeviceStream(AudioDeviceId, *const AudioSpec, ?*AudioStreamCallback, ?*anyopaque) ?*AudioStream;

/// Free an audio stream.
///
/// This will release all allocated data, including any audio that is still
/// queued. You do not need to manually clear the stream first.
///
/// If this stream was bound to an audio device, it is unbound during this
/// call. If this stream was created with SDL_OpenAudioDeviceStream, the audio
/// device that was opened alongside this stream's creation will be closed,
/// too.
///
/// \param stream the audio stream to destroy.
///
/// \threadsafety It is safe to call this function from any thread.
///
/// \since This function is available since SDL 3.2.0.
///
/// \sa SDL_CreateAudioStream
pub fn destroyAudioStream(stream: *AudioStream) void {
    SDL_DestroyAudioStream(stream);
}
extern "SDL3" fn SDL_DestroyAudioStream(*AudioStream) void;

/// Use this function to pause audio playback on the audio device associated
/// with an audio stream.
///
/// This function pauses audio processing for a given device. Any bound audio
/// streams will not progress, and no audio will be generated. Pausing one
/// device does not prevent other unpaused devices from running.
///
/// Pausing a device can be useful to halt all audio without unbinding all the
/// audio streams. This might be useful while a game is paused, or a level is
/// loading, etc.
///
/// \param stream the audio stream associated with the audio device to pause.
/// \returns true on success or false on failure; call SDL_GetError() for more
///          information.
///
/// \threadsafety It is safe to call this function from any thread.
///
/// \since This function is available since SDL 3.2.0.
///
/// \sa SDL_ResumeAudioStreamDevice
pub fn pauseAudioStreamDevice(stream: *AudioStream) Error!void {
    if (!SDL_PauseAudioStreamDevice(stream)) return Error.SdlError;
}
extern "SDL3" fn SDL_PauseAudioStreamDevice(stream: *AudioStream) bool;

/// Use this function to unpause audio playback on the audio device associated
/// with an audio stream.
///
/// This function unpauses audio processing for a given device that has
/// previously been paused. Once unpaused, any bound audio streams will begin
/// to progress again, and audio can be generated.
///
/// SDL_OpenAudioDeviceStream opens audio devices in a paused state, so this
/// function call is required for audio playback to begin on such devices.
///
/// \param stream the audio stream associated with the audio device to resume.
/// \returns true on success or false on failure; call SDL_GetError() for more
///          information.
///
/// \threadsafety It is safe to call this function from any thread.
///
/// \since This function is available since SDL 3.2.0.
///
/// \sa SDL_PauseAudioStreamDevice
pub fn resumeAudioStreamDevice(stream: *AudioStream) Error!void {
    if (!SDL_ResumeAudioStreamDevice(stream)) return Error.SdlError;
}
extern "SDL3" fn SDL_ResumeAudioStreamDevice(stream: *AudioStream) bool;

/// Get the number of bytes currently queued.
///
/// This is the number of bytes put into a stream as input, not the number that
/// can be retrieved as output. Because of several details, it's not possible
/// to calculate one number directly from the other. If you need to know how
/// much usable data can be retrieved right now, you should use
/// SDL_GetAudioStreamAvailable() and not this function.
///
/// Note that audio streams can change their input format at any time, even if
/// there is still data queued in a different format, so the returned byte
/// count will not necessarily match the number of _sample frames_ available.
/// Users of this API should be aware of format changes they make when feeding
/// a stream and plan accordingly.
///
/// Queued data is not converted until it is consumed by
/// SDL_GetAudioStreamData, so this value should be representative of the exact
/// data that was put into the stream.
///
/// If the stream has so much data that it would overflow an int, the return
/// value is clamped to a maximum value, but no queued data is lost; if there
/// are gigabytes of data queued, the app might need to read some of it with
/// SDL_GetAudioStreamData before this function's return value is no longer
/// clamped.
///
/// \param stream the audio stream to query.
/// \returns the number of bytes queued or -1 on failure; call SDL_GetError()
///          for more information.
///
/// \threadsafety It is safe to call this function from any thread.
///
/// \since This function is available since SDL 3.2.0.
///
/// \sa SDL_PutAudioStreamData
/// \sa SDL_ClearAudioStream
pub fn getAudioStreamQueued(stream: *AudioStream) Error!c_int {
    const result = SDL_GetAudioStreamQueued(stream);
    if (result == -1) return Error.SdlError;
    return result;
}
extern "SDL3" fn SDL_GetAudioStreamQueued(*AudioStream) c_int;

/// Add data to the stream.
///
/// This data must match the format/channels/samplerate specified in the latest
/// call to SDL_SetAudioStreamFormat, or the format specified when creating the
/// stream if it hasn't been changed.
///
/// Note that this call simply copies the unconverted data for later. This is
/// different than SDL2, where data was converted during the Put call and the
/// Get call would just dequeue the previously-converted data.
///
/// \param stream the stream the audio data is being added to.
/// \param buf a pointer to the audio data to add.
/// \param len the number of bytes to write to the stream.
/// \returns true on success or false on failure; call SDL_GetError() for more
///          information.
///
/// \threadsafety It is safe to call this function from any thread, but if the
///               stream has a callback set, the caller might need to manage
///               extra locking.
///
/// \since This function is available since SDL 3.2.0.
///
/// \sa SDL_ClearAudioStream
/// \sa SDL_FlushAudioStream
/// \sa SDL_GetAudioStreamData
/// \sa SDL_GetAudioStreamQueued
pub fn putAudioStreamData(stream: *AudioStream, T: type, buf: []T) Error!void {
    if (!SDL_PutAudioStreamData(stream, buf.ptr, @intCast(buf.len * @sizeOf(T)))) return Error.SdlError;
}
extern "SDL3" fn SDL_PutAudioStreamData(*AudioStream, buf: *anyopaque, len: c_int) bool;

/// A callback that fires when data passes through an SDL_AudioStream.
///
/// Apps can (optionally) register a callback with an audio stream that is
/// called when data is added with SDL_PutAudioStreamData, or requested with
/// SDL_GetAudioStreamData.
///
/// Two values are offered here: one is the amount of additional data needed to
/// satisfy the immediate request (which might be zero if the stream already
/// has enough data queued) and the other is the total amount being requested.
/// In a Get call triggering a Put callback, these values can be different. In
/// a Put call triggering a Get callback, these values are always the same.
///
/// Byte counts might be slightly overestimated due to buffering or resampling,
/// and may change from call to call.
///
/// This callback is not required to do anything. Generally this is useful for
/// adding/reading data on demand, and the app will often put/get data as
/// appropriate, but the system goes on with the data currently available to it
/// if this callback does nothing.
///
/// \param stream the SDL audio stream associated with this callback.
/// \param additional_amount the amount of data, in bytes, that is needed right
///                          now.
/// \param total_amount the total amount of data requested, in bytes, that is
///                     requested or available.
/// \param userdata an opaque pointer provided by the app for their personal
///                 use.
///
/// \threadsafety This callbacks may run from any thread, so if you need to
///               protect shared data, you should use SDL_LockAudioStream to
///               serialize access; this lock will be held before your callback
///               is called, so your callback does not need to manage the lock
///               explicitly.
///
/// \since This datatype is available since SDL 3.2.0.
///
/// \sa SDL_SetAudioStreamGetCallback
/// \sa SDL_SetAudioStreamPutCallback
pub const AudioStreamCallback = fn (userdata: ?*anyopaque, stream: *AudioStream, additional_amount: c_int, total_amount: c_int) callconv(.c) void;

/// The opaque handle that represents an audio stream.
///
/// SDL_AudioStream is an audio conversion interface.
///
/// - It can handle resampling data in chunks without generating artifacts,
///   when it doesn't have the complete buffer available.
/// - It can handle incoming data in any variable size.
/// - It can handle input/output format changes on the fly.
/// - It can remap audio channels between inputs and outputs.
/// - You push data as you have it, and pull it when you need it
/// - It can also function as a basic audio data queue even if you just have
///   sound that needs to pass from one place to another.
/// - You can hook callbacks up to them when more data is added or requested,
///   to manage data on-the-fly.
///
/// Audio streams are the core of the SDL3 audio interface. You create one or
/// more of them, bind them to an opened audio device, and feed data to them
/// (or for recording, consume data from them).
///
/// \since This struct is available since SDL 3.2.0.
///
/// \sa SDL_CreateAudioStream
pub const AudioStream = opaque {};

/// SDL Audio Device instance IDs.
///
/// Zero is used to signify an invalid/null device.
///
/// \since This datatype is available since SDL 3.2.0.
pub const AudioDeviceId = enum(u32) {
    default_recording = 0xfffffffe,
    default_playback = 0xffffffff,
    invalid_device = 0,
    _,
};

/// Format specifier for audio data.
///
/// \since This struct is available since SDL 3.2.0.
///
/// \sa SDL_AudioFormat
pub const AudioSpec = extern struct {
    /// Audio data format
    format: AudioFormat,
    /// Number of channels: 1 mono, 2 stereo, etc
    channels: c_int,
    /// sample rate: sample frames per second
    freq: c_int,
};

/// Audio format.
///
/// \since This enum is available since SDL 3.2.0.
///
/// \sa SDL_AUDIO_BITSIZE
/// \sa SDL_AUDIO_BYTESIZE
/// \sa SDL_AUDIO_ISINT
/// \sa SDL_AUDIO_ISFLOAT
/// \sa SDL_AUDIO_ISBIGENDIAN
/// \sa SDL_AUDIO_ISLITTLEENDIAN
/// \sa SDL_AUDIO_ISSIGNED
/// \sa SDL_AUDIO_ISUNSIGNED
pub const AudioFormat = enum(c_int) {
    /// Unspecified audio format
    unknown = 0,
    /// Unsigned 8-bit samples
    u8 = 8,
    /// Signed 8-bit samples
    s8 = 32776,
    /// Signed 16-bit samples
    s16le = 32784,
    /// As above, but big-endian byte order
    s16be = 36880,
    /// 32-bit integer samples
    s32le = 32800,
    /// As above, but big-endian byte order
    s32be = 36896,
    /// 32-bit floating point samples
    f32le = 33056,
    /// As above, but big-endian byte order
    f32be = 37152,
    pub const s16: AudioFormat = if (endian == .little) .s16le else .s16be;
    pub const s32: AudioFormat = if (endian == .little) .s32le else .s32be;
    pub const @"f32": AudioFormat = if (endian == .little) .f32le else .f32be;
};

/// Compatibility function to initialize the SDL library.
///
/// This function and SDL_Init() are interchangeable.
///
/// \param flags any of the flags used by SDL_Init(); see SDL_Init for details.
/// \returns true on success or false on failure; call SDL_GetError() for more
///          information.
///
/// \threadsafety This function should only be called on the main thread.
///
/// \since This function is available since SDL 3.2.0.
///
/// \sa SDL_Init
/// \sa SDL_Quit
/// \sa SDL_QuitSubSystem
pub fn initSubSystem(flags: InitFlags) Error!void {
    if (!SDL_InitSubSystem(flags)) return Error.SdlError;
}
extern "SDL3" fn SDL_InitSubSystem(flags: InitFlags) bool;

/// Clean up all initialized subsystems.
///
/// You should call this function even if you have already shutdown each
/// initialized subsystem with SDL_QuitSubSystem(). It is safe to call this
/// function even in the case of errors in initialization.
///
/// You can use this function with atexit() to ensure that it is run when your
/// application is shutdown, but it is not wise to do this from a library or
/// other dynamically loaded code.
///
/// \threadsafety This function should only be called on the main thread.
///
/// \since This function is available since SDL 3.2.0.
///
/// \sa SDL_Init
/// \sa SDL_QuitSubSystem
pub fn quit() void {
    SDL_Quit();
}
extern "SDL3" fn SDL_Quit() void;

/// Specify metadata about your app through a set of properties.
///
/// You can optionally provide metadata about your app to SDL. This is not
/// required, but strongly encouraged.
///
/// There are several locations where SDL can make use of metadata (an "About"
/// box in the macOS menu bar, the name of the app can be shown on some audio
/// mixers, etc). Any piece of metadata can be left out, if a specific detail
/// doesn't make sense for the app.
///
/// This function should be called as early as possible, before SDL_Init.
/// Multiple calls to this function are allowed, but various state might not
/// change once it has been set up with a previous call to this function.
///
/// Once set, this metadata can be read using SDL_GetAppMetadataProperty().
///
/// These are the supported properties:
///
/// - `SDL_PROP_APP_METADATA_NAME_STRING`: The human-readable name of the
///   application, like "My Game 2: Bad Guy's Revenge!". This will show up
///   anywhere the OS shows the name of the application separately from window
///   titles, such as volume control applets, etc. This defaults to "SDL
///   Application".
/// - `SDL_PROP_APP_METADATA_VERSION_STRING`: The version of the app that is
///   running; there are no rules on format, so "1.0.3beta2" and "April 22nd,
///   2024" and a git hash are all valid options. This has no default.
/// - `SDL_PROP_APP_METADATA_IDENTIFIER_STRING`: A unique string that
///   identifies this app. This must be in reverse-domain format, like
///   "com.example.mygame2". This string is used by desktop compositors to
///   identify and group windows together, as well as match applications with
///   associated desktop settings and icons. If you plan to package your
///   application in a container such as Flatpak, the app ID should match the
///   name of your Flatpak container as well. This has no default.
/// - `SDL_PROP_APP_METADATA_CREATOR_STRING`: The human-readable name of the
///   creator/developer/maker of this app, like "MojoWorkshop, LLC"
/// - `SDL_PROP_APP_METADATA_COPYRIGHT_STRING`: The human-readable copyright
///   notice, like "Copyright (c) 2024 MojoWorkshop, LLC" or whatnot. Keep this
///   to one line, don't paste a copy of a whole software license in here. This
///   has no default.
/// - `SDL_PROP_APP_METADATA_URL_STRING`: A URL to the app on the web. Maybe a
///   product page, or a storefront, or even a GitHub repository, for user's
///   further information This has no default.
/// - `SDL_PROP_APP_METADATA_TYPE_STRING`: The type of application this is.
///   Currently this string can be "game" for a video game, "mediaplayer" for a
///   media player, or generically "application" if nothing else applies.
///   Future versions of SDL might add new types. This defaults to
///   "application".
///
/// \param name the name of the metadata property to set.
/// \param value the value of the property, or NULL to remove that property.
/// \returns true on success or false on failure; call SDL_GetError() for more
///          information.
///
/// \threadsafety It is safe to call this function from any thread.
///
/// \since This function is available since SDL 3.2.0.
///
/// \sa SDL_GetAppMetadataProperty
/// \sa SDL_SetAppMetadata
pub fn setAppMetadataProperty(property: AppMetadataProperty, value: [*:0]const u8) !void {
    if (!SDL_SetAppMetadataProperty(property.string(), value)) return Error.SdlError;
}
extern "SDL3" fn SDL_SetAppMetadataProperty(name: [*:0]const u8, value: [*:0]const u8) bool;

/// Initialization flags for SDL_Init and/or SDL_InitSubSystem
///
/// These are the flags which may be passed to SDL_Init(). You should specify
/// the subsystems which you will be using in your application.
///
/// \since This datatype is available since SDL 3.2.0.
///
/// \sa SDL_Init
/// \sa SDL_Quit
/// \sa SDL_InitSubSystem
/// \sa SDL_QuitSubSystem
/// \sa SDL_WasInit
pub const InitFlags = packed struct(u32) {
    _padding0: u4 = 0,
    /// `SDL_INIT_AUDIO` implies `SDL_INIT_EVENTS`
    audio: bool = false,
    /// `SDL_INIT_VIDEO` implies `SDL_INIT_EVENTS`, should be initialized on the main thread
    video: bool = false,
    _padding1: u3 = 0,
    /// `SDL_INIT_JOYSTICK` implies `SDL_INIT_EVENTS`
    joystick: bool = false,
    _padding2: u2 = 0,
    haptic: bool = false,
    /// `SDL_INIT_GAMEPAD` implies `SDL_INIT_JOYSTICK`
    gamepad: bool = false,
    events: bool = false,
    /// `SDL_INIT_SENSOR` implies `SDL_INIT_EVENTS`
    sensor: bool = false,
    /// `SDL_INIT_CAMERA` implies `SDL_INIT_EVENTS`
    camera: bool = false,
    _padding3: u15 = 0,
};

comptime {
    const assert = @import("std").debug.assert;
    assert(0x00000010 == @as(u32, @bitCast(InitFlags{ .audio = true })));
    assert(0x00000020 == @as(u32, @bitCast(InitFlags{ .video = true })));
    assert(0x00000200 == @as(u32, @bitCast(InitFlags{ .joystick = true })));
    assert(0x00001000 == @as(u32, @bitCast(InitFlags{ .haptic = true })));
    assert(0x00002000 == @as(u32, @bitCast(InitFlags{ .gamepad = true })));
    assert(0x00004000 == @as(u32, @bitCast(InitFlags{ .events = true })));
    assert(0x00008000 == @as(u32, @bitCast(InitFlags{ .sensor = true })));
    assert(0x00010000 == @as(u32, @bitCast(InitFlags{ .camera = true })));
}

pub const AppMetadataProperty = enum {
    name,
    version,
    identifier,
    creator,
    copyright,
    url,
    type,

    fn string(self: AppMetadataProperty) [:0]const u8 {
        return switch (self) {
            // zig fmt: off
            .name =>       "SDL.app.metadata.name",
            .version =>    "SDL.app.metadata.version",
            .identifier => "SDL.app.metadata.identifier",
            .creator =>    "SDL.app.metadata.creator",
            .copyright =>  "SDL.app.metadata.copyright",
            .url =>        "SDL.app.metadata.url",
            .type =>       "SDL.app.metadata.type",
            // zig fmt: on
        };
    }
};

/// Retrieve a message about the last error that occurred on the current
/// thread.
///
/// It is possible for multiple errors to occur before calling SDL_GetError().
/// Only the last error is returned.
///
/// The message is only applicable when an SDL function has signaled an error.
/// You must check the return values of SDL function calls to determine when to
/// appropriately call SDL_GetError(). You should *not* use the results of
/// SDL_GetError() to decide if an error has occurred! Sometimes SDL will set
/// an error string even when reporting success.
///
/// SDL will *not* clear the error string for successful API calls. You *must*
/// check return values for failure cases before you can assume the error
/// string applies.
///
/// Error strings are set per-thread, so an error set in a different thread
/// will not interfere with the current thread's operation.
///
/// The returned value is a thread-local string which will remain valid until
/// the current thread's error string is changed. The caller should make a copy
/// if the value is needed after the next SDL API call.
///
/// \returns a message with information about the specific error that occurred,
///          or an empty string if there hasn't been an error message set since
///          the last call to SDL_ClearError().
///
/// \threadsafety It is safe to call this function from any thread.
///
/// \since This function is available since SDL 3.2.0.
///
/// \sa SDL_ClearError
/// \sa SDL_SetError
pub fn getError() [*:0]const u8 {
    return SDL_GetError();
}
extern "SDL3" fn SDL_GetError() [*:0]const u8;
