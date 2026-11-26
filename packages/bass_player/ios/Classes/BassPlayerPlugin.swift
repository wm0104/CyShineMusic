// CyShineMusic iOS —— BASS 播放引擎插件。
//
// 与 Android 端 packages/bass_player/android/.../BassPlayerPlugin.kt 保持完全相同的
// 对外契约：
//   MethodChannel  com.cyshine.music/bass_player/methods
//     initialize / load / prepareCrossfade / startCrossfade / cancelCrossfade
//     play / pause / stop / seek / setVolume / setEqualizer / dispose
//   EventChannel   com.cyshine.music/bass_player/events
//     {event:"snapshot"|"error", playing, processingState, positionMs,
//      bufferedPositionMs, durationMs, [errorCode, bassCode, errorMessage, operation]}
//   错误码格式 BASS_<int>（dart 侧 BassPlayerException 用正则 ^BASS_(-?\d+)$ 解析）

import Flutter
import Foundation
import UIKit
import CBass

public final class BassPlayerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

  // MARK: - 通道名

  private static let methodChannelName = "com.cyshine.music/bass_player/methods"
  private static let eventChannelName = "com.cyshine.music/bass_player/events"

  // MARK: - 状态常量（与 Android 端逐字对应）

  private enum PlaybackState: String {
    case idle, loading, buffering, ready, completed, error
  }

  /// load 被新的 load/stop/dispose 取代时使用。与 Android 端 CANCELLED 常量一致。
  /// 必须显式声明成 Int32：BassError.code 是 Int32，否则字面量会被推成 Int 而报类型错。
  private static let cancelledCode: Int32 = -1000

  // MARK: - 插件入口

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = BassPlayerPlugin()
    let messenger = registrar.messenger()
    let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak instance] call, result in
      instance?.handleCall(call, result: result)
    }
    events.setStreamHandler(instance)
    // 让 instance 活到 engine 卸载为止。
    registrar.publish(instance)
  }

  // MARK: - 内部状态

  /// Playback state is owned by engineQueue. Only opening a standby stream runs elsewhere.
  private let engineQueue = DispatchQueue(label: "com.cyshine.music.bass.engine")

  private let sinkLock = NSLock()
  private var eventSink: FlutterEventSink?

  private var initialized = false
  private var active: Output?
  private var stream: HSTREAM { active?.handle ?? 0 }
  private var remoteSource: Bool { active?.remote ?? false }

  private let preloadQueue = DispatchQueue(label: "com.cyshine.music.bass.preload")
  private var preparation: Preparation?
  private var outgoing: Output?
  private var fadeToken: Int?
  private var fadeDurationMs = 0
  private var fadeTimer: DispatchSourceTimer?
  private var playing = false
  private var completed = false
  private var processingState: PlaybackState = .idle
  private var durationMs: Int?
  private var channelVolume: Float = 1.0
  private var bassVersion = "unknown"
  private var fxVersion = "unknown"
  private var pluginVersions: [String: String] = [:]

  /// 用于取消进行中的 load（Android 端用 AtomicInteger 生成号做同一件事）。
  private var loadGeneration = 0

  private final class Filters {
    let chain: OpaquePointer
    let channels: UInt32

    init?(for handle: HSTREAM) {
      var info = BASS_CHANNELINFO()
      let known = BASS_ChannelGetInfo(handle, &info) != 0
      let rate = known && info.freq > 0 ? Double(info.freq) : 44_100
      guard let chain = cyshine_biquad_chain_create(rate) else { return nil }
      self.chain = chain
      channels = known ? max(info.chans, 1) : 2
    }

    deinit { cyshine_biquad_chain_destroy(chain) }
  }

  /// Each decoder owns its callbacks and filter history, including during overlap.
  private final class Output {
    let handle: HSTREAM
    let remote: Bool
    var endSync: HSYNC = 0
    var stallSync: HSYNC = 0
    var downloadSync: HSYNC = 0
    var deviceFailureSync: HSYNC = 0
    var filters: Filters?
    var eqDsp: HDSP = 0

    init(handle: HSTREAM, remote: Bool) {
      self.handle = handle
      self.remote = remote
    }

    func detachEqualizer() {
      if eqDsp != 0 { _ = BASS_ChannelRemoveDSP(handle, eqDsp) }
      eqDsp = 0
      filters = nil
    }

    deinit {
      detachEqualizer()
      for sync in [endSync, stallSync, downloadSync, deviceFailureSync] where sync != 0 {
        _ = BASS_ChannelRemoveSync(handle, sync)
      }
      _ = BASS_StreamFree(handle)
    }
  }

  /// The worker may finish after cancellation. Transfer ownership under the lock
  /// so a decoder is always freed before BASS_Free, even during engine teardown.
  private final class Preparation {
    let token: Int
    private let lock = NSLock()
    private var cancelled = false
    private var output: Output?

    init(token: Int) { self.token = token }

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }

    func store(_ opened: Output) {
      lock.lock()
      defer { lock.unlock() }
      if !cancelled { output = opened }
    }

    func take() -> Output? {
      lock.lock()
      defer { lock.unlock() }
      let opened = output
      output = nil
      return opened
    }

    func cancel() {
      lock.lock()
      cancelled = true
      output = nil
      lock.unlock()
      _ = BASS_StreamCancel(Unmanaged.passUnretained(self).toOpaque())
    }
  }

  private var currentEq: [String: Any]?

  private var tickTimer: DispatchSourceTimer?
  private let audioSessionQueue = DispatchQueue(label: "com.cyshine.music.bass.session")

  // MARK: - 通道回调

  /// 注意：不要把这个方法命名成 `handle(_:result:)`。
  /// Flutter 的 `FlutterPlugin` 协议里有一个可选要求就叫这个名字，撞名会被编译器
  /// 当成「实现了协议要求」，进而报出一串莫名其妙的错误。
  private func handleCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {

    case "initialize":
      engineQueue.async {
        do {
          let value = try self.initializeEngine()
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "load", "prepareCrossfade":
      guard let args = call.arguments as? [String: Any],
            let uri = args["uri"] as? String, !uri.isEmpty else {
        result(FlutterError(code: "BASS_ARGUMENT", message: "uri is required", details: nil))
        return
      }
      var headers: [String: String] = [:]
      if let raw = args["headers"] as? [String: Any] {
        for (key, value) in raw { headers[key] = String(describing: value) }
      }
      let formatHint = args["formatHint"] as? String
      let requestHeaders = headers
      if call.method == "prepareCrossfade" {
        guard let token = args["token"] as? Int else {
          result(["prepared": false])
          return
        }
        engineQueue.async {
          self.prepareCrossfade(uri, headers: requestHeaders, formatHint: formatHint,
                                token: token, result: result)
        }
        return
      }
      engineQueue.async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        do {
          let value = try self.load(uri, headers: requestHeaders, formatHint: formatHint,
                                    generation: generation)
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "startCrossfade":
      let args = call.arguments as? [String: Any]
      let token = args?["token"] as? Int
      let duration = args?["durationMs"] as? Int ?? 0
      engineQueue.async {
        let value = self.startCrossfade(token: token, duration: duration)
        DispatchQueue.main.async { result(value) }
      }

    case "cancelCrossfade":
      let token = (call.arguments as? [String: Any])?["token"] as? Int
      engineQueue.async {
        if let token {
          if self.preparation?.token == token { self.cancelPreparation() }
          if self.fadeToken == token { self.finishFade() }
        }
        DispatchQueue.main.async { result([String: Any]()) }
      }

    case "play":
      engineQueue.async {
        do {
          let value = try self.play()
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "pause":
      engineQueue.async {
        do {
          let value = try self.pause()
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "stop":
      engineQueue.async {
        self.loadGeneration += 1
        do {
          let value = try self.stop()
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "seek":
      let positionMs = (call.arguments as? [String: Any])?["positionMs"] as? Int ?? 0
      engineQueue.async {
        do {
          let value = try self.seek(positionMs)
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "setVolume":
      let volume = (call.arguments as? [String: Any])?["volume"] as? Double ?? 1.0
      engineQueue.async {
        do {
          let value = try self.setVolume(Float(volume))
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "setEqualizer":
      let configuration = call.arguments as? [String: Any] ?? [:]
      engineQueue.async {
        do {
          let value = try self.setEqualizer(configuration)
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "dispose":
      engineQueue.async {
        self.loadGeneration += 1
        self.disposeEngine()
        DispatchQueue.main.async { result([String: Any?]()) }
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 与 Android 的 postResult 对齐：BassError -> "BASS_<code>" + {operation, bassCode}；
  /// 其它错误 -> "BASS_NATIVE" + 当前 BASS_ErrorGetCode()。
  ///
  /// 刻意写成「调用点各自 do/catch」而不是「接 throwing 闭包的 helper」：
  /// Swift 在 DispatchQueue.async 嵌套里会把 throwing 尾随闭包误判成非 throwing，
  /// 报一串 "Call can throw, but it is not marked with 'try'"。
  static func flutterError(_ error: Error) -> FlutterError {
    if let failure = error as? BassError {
      return FlutterError(code: "BASS_\(failure.code)",
                          message: failure.message,
                          details: ["operation": failure.operation,
                                    "bassCode": failure.code])
    }
    let code = Int(BASS_ErrorGetCode())
    return FlutterError(code: "BASS_NATIVE",
                        message: "\(error)",
                        details: ["operation": "native", "bassCode": code])
  }

  // MARK: - EventChannel

  public func onListen(withArguments arguments: Any?,
                       eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sinkLock.lock()
    eventSink = events
    sinkLock.unlock()
    engineQueue.async { self.emitSnapshot() }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sinkLock.lock()
    eventSink = nil
    sinkLock.unlock()
    return nil
  }

  private func send(_ payload: [String: Any?]) {
    sinkLock.lock()
    let sink = eventSink
    sinkLock.unlock()
    guard let sink else { return }
    DispatchQueue.main.async { sink(payload) }
  }

  // MARK: - 引擎初始化

  private func initializeEngine() throws -> [String: Any?] {
    if initialized { return engineInfo() }

    let rawVersion = BASS_GetVersion()
    bassVersion = BassPlayerPlugin.versionString(rawVersion)
    if (rawVersion >> 16) != UInt32(BASSVERSION) {
      throw BassError(code: -1, operation: "initialize",
                      message: "BASS API 2.4 与原生库 \(bassVersion) 不匹配")
    }
    // iOS 上没有 BASS_FX：均衡器由内置 biquad DSP 实现，这里如实上报。
    fxVersion = "builtin-biquad"

    // audio_session configures the playback category and the user's mixing preference.
    // BASS otherwise enables mixing again when it initializes the output device.
    guard BASS_SetConfig(UInt32(BASS_CONFIG_IOS_SESSION), UInt32(BASS_IOS_SESSION_DISABLE)) != 0 else {
      throw BassError.fromLastError(operation: "configure iOS audio session management")
    }
    _ = BASS_SetConfig(UInt32(BASS_CONFIG_BUFFER), 500)
    _ = BASS_SetConfig(UInt32(BASS_CONFIG_UPDATEPERIOD), 50)
    _ = BASS_SetConfig(UInt32(BASS_CONFIG_NET_TIMEOUT), 15_000)
    _ = BASS_SetConfig(UInt32(BASS_CONFIG_NET_BUFFER), 60_000)
    _ = BASS_SetConfig(UInt32(BASS_CONFIG_NET_PREBUF), 20)
    _ = BASS_SetConfig(UInt32(BASS_CONFIG_FLOATDSP), 1)

    // device = -1 表示默认设备；Apple 平台不需要额外的 win/clsid。
    if BASS_Init(-1, 44_100, 0, nil, nil) == 0 {
      throw BassError.fromLastError(operation: "initialize output")
    }
    initialized = true

    // 这些附加库是以动态 framework 形式链接进来的，链接成功即代表可用。
    // 附加库本身没有独立的 GetVersion 入口（那是 BASS_FX 才有），这里上报核心版本。
    pluginVersions["flac"] = bassVersion
    pluginVersions["ape"] = bassVersion
    pluginVersions["wv"] = bassVersion
    pluginVersions["opus"] = bassVersion
    pluginVersions["dsd"] = bassVersion
    // ALAC / AAC 在 Apple 平台由 BASS 核心走系统解码器，没有独立版本号可读。
    pluginVersions["alac"] = "core (CoreAudio)"

    processingState = .idle
    emitSnapshot()
    return engineInfo()
  }

  private func engineInfo() -> [String: Any?] {
    ["version": bassVersion, "fxVersion": fxVersion, "plugins": pluginVersions]
  }

  // MARK: - 播放控制

  private func load(_ source: String,
                    headers: [String: String],
                    formatHint: String?,
                    generation: Int) throws -> [String: Any?] {
    _ = try initializeEngine()
    if generation != loadGeneration {
      throw BassError(code: BassPlayerPlugin.cancelledCode, operation: "load",
                      message: "load cancelled")
    }

    releaseStream()
    playing = false
    completed = false
    durationMs = nil
    processingState = .loading
    emitSnapshot()

    do {
      active = try openOutput(source, headers: headers, formatHint: formatHint)
    } catch {
      processingState = .error
      emitSnapshot()
      throw error
    }

    do {
      if BASS_ChannelSetAttribute(stream, UInt32(BASS_ATTRIB_VOL), channelVolume) == 0 {
        throw BassError.fromLastError(operation: "set volume")
      }
      if let active {
        try installSynchronizers(for: active)
        try applyEqualizer(currentEq, to: active)
      }
      durationMs = readDurationMs()
      processingState = .ready
      refreshPlaybackState()
    } catch {
      releaseStream()
      processingState = .error
      throw error
    }

    emitSnapshot()
    return snapshot()
  }

  private func openOutput(_ source: String, headers: [String: String],
                          formatHint: String?, request: Preparation? = nil) throws -> Output {
    let scheme = URL(string: source)?.scheme?.lowercased() ?? ""
    let format = BassPlayerPlugin.normalizedFormat(formatHint, source: source)
    let flags = UInt32(BASS_SAMPLE_FLOAT)
    let handle: HSTREAM
    let remote: Bool
    switch scheme {
    case "http", "https", "ftp":
      remote = true
      handle = createNetworkStream(format: format,
                                   request: BassPlayerPlugin.urlWithHeaders(source, headers),
                                   flags: flags, preparation: request)
    case "", "file":
      remote = false
      let path = scheme == "file" ? URL(string: source)?.path ?? source : source
      handle = createFileStream(format: format, path: path, flags: flags)
    default:
      throw BassError(code: Int32(BASS_ERROR_FILEOPEN), operation: "load",
                      message: "不支持的 URI scheme: \(scheme)")
    }
    if handle == 0 { throw BassError.fromLastError(operation: "load stream") }
    return Output(handle: handle, remote: remote)
  }

  private func prepareCrossfade(_ source: String, headers: [String: String],
                                formatHint: String?, token: Int, result: @escaping FlutterResult) {
    cancelPreparation()
    guard let active, initialized else {
      DispatchQueue.main.async { result(["prepared": false]) }
      return
    }
    let request = Preparation(token: token)
    preparation = request
    let device = BASS_ChannelGetDevice(active.handle)
    preloadQueue.async {
      var prepared = false
      if !request.isCancelled, BASS_SetDevice(device) != 0,
         let output = try? self.openOutput(source, headers: headers, formatHint: formatHint,
                                          request: request) {
        request.store(output)
        prepared = true
      }
      let opened = prepared
      self.engineQueue.async {
        let valid = opened && self.preparation === request
        DispatchQueue.main.async { result(["prepared": valid]) }
      }
    }
  }

  private func cancelPreparation() {
    preparation?.cancel()
    preparation = nil
  }

  private func startCrossfade(token: Int?, duration: Int) -> [String: Any?] {
    guard let token, let request = preparation, request.token == token, duration > 0,
          let previous = active, !completed,
          BASS_ChannelIsActive(previous.handle) == UInt32(BASS_ACTIVE_PLAYING),
          let next = request.take() else { return ["started": false] }
    preparation = nil
    do {
      try installSynchronizers(for: next)
      try applyEqualizer(currentEq, to: next)
    } catch {
      return ["started": false]
    }
    guard BASS_ChannelSetAttribute(next.handle, UInt32(BASS_ATTRIB_VOL), 0) != 0,
          BASS_ChannelPlay(next.handle, 0) != 0 else { return ["started": false] }

    finishFade()
    outgoing = previous
    active = next
    fadeToken = token
    fadeDurationMs = duration
    durationMs = readDurationMs()
    processingState = .ready
    refreshPlaybackState()
    let timer = DispatchSource.makeTimerSource(queue: engineQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(20))
    timer.setEventHandler { [weak self] in self?.updateFade() }
    fadeTimer = timer
    timer.resume()
    var value = snapshot()
    value["started"] = true
    return value
  }

  private func updateFade() {
    guard let outgoing else { return }
    // The incoming playback clock freezes on pause and while it is buffering.
    let progress = min(1, Double(readPositionMs()) / Double(fadeDurationMs))
    if progress >= 1 || BASS_ChannelIsActive(outgoing.handle) == UInt32(BASS_ACTIVE_STOPPED) {
      finishFade()
      return
    }
    let angle = progress * .pi / 2
    _ = BASS_ChannelSetAttribute(stream, UInt32(BASS_ATTRIB_VOL), channelVolume * Float(sin(angle)))
    _ = BASS_ChannelSetAttribute(outgoing.handle, UInt32(BASS_ATTRIB_VOL),
                                 channelVolume * Float(cos(angle)))
  }

  private func finishFade() {
    fadeTimer?.cancel()
    fadeTimer = nil
    guard outgoing != nil else { return }
    outgoing = nil
    fadeToken = nil
    _ = BASS_ChannelSetAttribute(stream, UInt32(BASS_ATTRIB_VOL), channelVolume)
  }

  private func play() throws -> [String: Any?] {
    _ = try initializeEngine()
    if stream == 0 { throw BassError(code: Int32(BASS_ERROR_HANDLE), operation: "play",
                                    message: "没有已加载的音频流") }
    if completed {
      // 播完后再点播放：回到起点重播，与 Android 行为一致。
      let position = BASS_ChannelSeconds2Bytes(stream, 0.0)
      if BASS_ChannelSetPosition(stream, position, UInt32(BASS_POS_BYTE)) == 0 {
        throw BassError.fromLastError(operation: "restart stream")
      }
      completed = false
    }
    if BASS_ChannelPlay(stream, 0) == 0 {
      throw BassError.fromLastError(operation: "play")
    }
    if let outgoing,
       BASS_ChannelIsActive(outgoing.handle) == UInt32(BASS_ACTIVE_PAUSED) {
      _ = BASS_ChannelPlay(outgoing.handle, 0)
    }
    fadeTimer?.schedule(deadline: .now(), repeating: .milliseconds(20))
    refreshPlaybackState()
    emitSnapshot()
    return snapshot()
  }

  private func pause() throws -> [String: Any?] {
    if stream == 0 { return snapshot() }
    if BASS_ChannelPause(stream) == 0 {
      throw BassError.fromLastError(operation: "pause")
    }
    if let outgoing { _ = BASS_ChannelPause(outgoing.handle) }
    fadeTimer?.schedule(deadline: .distantFuture)
    refreshPlaybackState()
    emitSnapshot()
    return snapshot()
  }

  private func stop() throws -> [String: Any?] {
    cancelPreparation()
    finishFade()
    if stream == 0 { return snapshot() }
    if BASS_ChannelStop(stream) == 0 {
      throw BassError.fromLastError(operation: "stop")
    }
    let position = BASS_ChannelSeconds2Bytes(stream, 0.0)
    _ = BASS_ChannelSetPosition(stream, position, UInt32(BASS_POS_BYTE))
    resetEqualizerState()
    completed = false
    playing = false
    processingState = .idle
    emitSnapshot()
    return snapshot()
  }

  private func seek(_ positionMs: Int) throws -> [String: Any?] {
    cancelPreparation()
    finishFade()
    if stream == 0 { return snapshot() }
    let seconds = max(0.0, Double(positionMs) / 1000.0)
    let position = BASS_ChannelSeconds2Bytes(stream, seconds)
    if BASS_ChannelSetPosition(stream, position, UInt32(BASS_POS_BYTE)) == 0 {
      throw BassError.fromLastError(operation: "seek")
    }
    // seek 后滤波器里残留的历史会造成爆音，清掉。
    resetEqualizerState()
    if completed {
      completed = false
    }
    refreshPlaybackState()
    emitSnapshot()
    return snapshot()
  }

  private func setVolume(_ volume: Float) throws -> [String: Any?] {
    channelVolume = min(max(volume, 0), 1)
    if outgoing != nil {
      updateFade()
    } else if stream != 0 {
      if BASS_ChannelSetAttribute(stream, UInt32(BASS_ATTRIB_VOL), channelVolume) == 0 {
        throw BassError.fromLastError(operation: "set volume")
      }
    }
    return snapshot()
  }

  // MARK: - 均衡器

  private func setEqualizer(_ configuration: [String: Any]) throws -> [String: Any?] {
    currentEq = configuration
    if let active { try applyEqualizer(configuration, to: active) }
    if let outgoing { try applyEqualizer(configuration, to: outgoing) }
    return snapshot()
  }

  private func applyEqualizer(_ configuration: [String: Any]?, to output: Output) throws {
    let enabled = configuration?["enabled"] as? Bool ?? false
    if !enabled {
      output.detachEqualizer()
      return
    }

    let inputGainDb = configuration?["inputGainDb"] as? Double ?? 0
    let outputGainDb = configuration?["outputGainDb"] as? Double ?? 0
    let rawBands = configuration?["bands"] as? [[String: Any]] ?? []
    let bands = rawBands.compactMap(BassPlayerPlugin.parseBand)
      .filter { $0.enabled }
      .prefix(Int(CYSHINE_MAX_BIQUAD_BANDS))

    if bands.isEmpty && abs(inputGainDb) < 0.001 && abs(outputGainDb) < 0.001 {
      output.detachEqualizer()
      return
    }

    if output.filters == nil {
      guard let filters = Filters(for: output.handle) else {
        throw BassError(code: -1, operation: "setEqualizer",
                        message: "无法创建均衡器处理链")
      }
      output.filters = filters
      output.eqDsp = BASS_ChannelSetDSP(
        output.handle,
        { (_, _, buffer, length, user) in
          guard let user, let buffer else { return }
          let owner = Unmanaged<Filters>.fromOpaque(user).takeUnretainedValue()
          let frames = length / (UInt32(MemoryLayout<Float>.size) * owner.channels)
          cyshine_biquad_chain_process(owner.chain, buffer.assumingMemoryBound(to: Float.self),
                                       UInt(frames), owner.channels)
        },
        Unmanaged.passUnretained(filters).toOpaque(), 0)
      if output.eqDsp == 0 {
        output.detachEqualizer()
        throw BassError.fromLastError(operation: "setEqualizer")
      }
    }

    guard let chain = output.filters?.chain else { return }

    var cBands = bands.map { band -> CyShineBiquadBand in
      CyShineBiquadBand(type: Int32(band.filterType.rawValue),
                        frequencyHz: band.frequencyHz,
                        gainDb: band.gainDb,
                        q: band.q)
    }
    // 全部段都关掉但仍要保留输入/输出增益时，用零段配置。
    cyshine_biquad_chain_configure(chain, inputGainDb, outputGainDb, &cBands, Int32(cBands.count))
  }

  private func resetEqualizerState() {
    guard let chain = active?.filters?.chain else { return }
    cyshine_biquad_chain_reset(chain)
  }

  // MARK: - 流创建

  private func createNetworkStream(format: String, request: String,
                                   flags: UInt32, preparation: Preparation?) -> HSTREAM {
    let user = preparation.map { Unmanaged.passUnretained($0).toOpaque() }
    func core() -> HSTREAM {
      guard preparation?.isCancelled != true else { return 0 }
      return request.withCString { BASS_StreamCreateURL($0, 0, flags, nil, user) }
    }
    func specialized(_ make: (UnsafePointer<CChar>) -> HSTREAM) -> HSTREAM {
      guard preparation?.isCancelled != true else { return 0 }
      let handle = request.withCString { make($0) }
      return handle != 0 ? handle : core()
    }

    switch format {
    case "flac":
      return specialized { BASS_FLAC_StreamCreateURL($0, 0, flags, nil, user) }
    case "ape":
      return specialized { BASS_APE_StreamCreateURL($0, 0, flags, nil, user) }
    case "wv":
      return specialized { BASS_WV_StreamCreateURL($0, 0, flags, nil, user) }
    case "opus":
      return specialized { BASS_OPUS_StreamCreateURL($0, 0, flags, nil, user) }
    case "dsd":
      // BASS_DSD_* 比其它附加库多一个 freq 参数（0 = 保持源采样率）。
      return specialized { BASS_DSD_StreamCreateURL($0, 0, flags, nil, user, 0) }
    case "m4a", "alac":
      // Apple 平台 BASS 核心直接走 CoreAudio 解 ALAC/AAC。
      return core()
    case "lossless":
      let generic = core()
      if generic != 0 { return generic }
      return specialized { BASS_FLAC_StreamCreateURL($0, 0, flags, nil, user) }
    default:
      // generic / null / 未知：先试核心，核心不认再按 FLAC 猜一次。
      let generic = core()
      if generic != 0 { return generic }
      return specialized { BASS_FLAC_StreamCreateURL($0, 0, flags, nil, user) }
    }
  }

  private func createFileStream(format: String, path: String, flags: UInt32) -> HSTREAM {
    func core() -> HSTREAM {
      path.withCString { BASS_StreamCreateFile(0, $0, 0, 0, flags) }
    }
    switch format {
    case "flac":
      let handle = path.withCString { BASS_FLAC_StreamCreateFile(0, $0, 0, 0, flags) }
      return handle != 0 ? handle : core()
    case "ape":
      let handle = path.withCString { BASS_APE_StreamCreateFile(0, $0, 0, 0, flags) }
      return handle != 0 ? handle : core()
    case "wv":
      let handle = path.withCString { BASS_WV_StreamCreateFile(0, $0, 0, 0, flags) }
      return handle != 0 ? handle : core()
    case "opus":
      let handle = path.withCString { BASS_OPUS_StreamCreateFile(0, $0, 0, 0, flags) }
      return handle != 0 ? handle : core()
    case "dsd":
      // 同 createNetworkStream：DSD 多一个 freq 参数。
      let handle = path.withCString { BASS_DSD_StreamCreateFile(0, $0, 0, 0, flags, 0) }
      return handle != 0 ? handle : core()
    default:
      return core()
    }
  }

  // MARK: - 同步点

  private func installSynchronizers(for output: Output) throws {
    let user = Unmanaged.passUnretained(self).toOpaque()

    output.endSync = BASS_ChannelSetSync(
      output.handle, UInt32(BASS_SYNC_END), 0,
      { handle, channel, _, user in
        guard let user else { return }
        let plugin = Unmanaged<BassPlayerPlugin>.fromOpaque(user).takeUnretainedValue()
        plugin.engineQueue.async {
          guard channel == plugin.stream, handle == plugin.active?.endSync else { return }
          plugin.handleStreamEnded()
        }
      }, user)

    output.stallSync = BASS_ChannelSetSync(
      output.handle, UInt32(BASS_SYNC_STALL), 0,
      { handle, channel, _, user in
        guard let user else { return }
        let plugin = Unmanaged<BassPlayerPlugin>.fromOpaque(user).takeUnretainedValue()
        plugin.engineQueue.async {
          guard channel == plugin.stream, handle == plugin.active?.stallSync else { return }
          plugin.refreshPlaybackState()
          plugin.emitSnapshot()
        }
      }, user)

    output.deviceFailureSync = BASS_ChannelSetSync(
      output.handle, UInt32(BASS_SYNC_DEV_FAIL), 0,
      { handle, channel, _, user in
        guard let user else { return }
        let plugin = Unmanaged<BassPlayerPlugin>.fromOpaque(user).takeUnretainedValue()
        plugin.engineQueue.async {
          guard channel == plugin.stream, handle == plugin.active?.deviceFailureSync else { return }
          plugin.finishFade()
          plugin.processingState = .error
          plugin.playing = false
          plugin.emitSnapshot()
          plugin.emitError(code: Int32(BASS_ERROR_DEVICE),
                           message: "音频设备失效",
                           operation: "device")
        }
      }, user)

    if output.endSync == 0 || output.stallSync == 0 || output.deviceFailureSync == 0 {
      throw BassError.fromLastError(operation: "install playback synchronizers")
    }

    // 下载进度同步点只对网络流有意义，失败不算错误。
    if output.remote {
      output.downloadSync = BASS_ChannelSetSync(
        output.handle, UInt32(BASS_SYNC_DOWNLOAD), 0,
        { handle, channel, _, user in
          guard let user else { return }
          let plugin = Unmanaged<BassPlayerPlugin>.fromOpaque(user).takeUnretainedValue()
          plugin.engineQueue.async {
            guard channel == plugin.stream, handle == plugin.active?.downloadSync else { return }
            plugin.emitSnapshot()
          }
        }, user)
    }
  }

  private func handleStreamEnded() {
    finishFade()
    processingState = .completed
    playing = false
    completed = true
    durationMs = readDurationMs() ?? durationMs
    emitSnapshot()
    stopTicking()
  }

  // MARK: - 状态

  private func refreshPlaybackState() {
    if stream == 0 || completed || processingState == .loading || processingState == .error {
      return
    }
    durationMs = readDurationMs() ?? durationMs
    switch BASS_ChannelIsActive(stream) {
    case UInt32(BASS_ACTIVE_PLAYING):
      playing = true
      processingState = .ready
    case UInt32(BASS_ACTIVE_STALLED):
      playing = true
      processingState = .buffering
    case UInt32(BASS_ACTIVE_PAUSED), UInt32(BASS_ACTIVE_PAUSED_DEVICE):
      playing = false
      processingState = .ready
    case UInt32(BASS_ACTIVE_STOPPED):
      playing = false
      processingState = .ready
    default:
      break
    }
    syncTicking()
  }

  private func snapshot() -> [String: Any?] {
    let position = readPositionMs()
    return [
      "event": "snapshot",
      "playing": playing,
      "processingState": processingState.rawValue,
      "positionMs": position,
      "bufferedPositionMs": readBufferedPositionMs(position),
      "durationMs": durationMs,
    ]
  }

  private func emitSnapshot() {
    send(snapshot())
  }

  private func emitError(code: Int32, message: String, operation: String) {
    var payload = snapshot()
    payload["event"] = "error"
    payload["errorCode"] = Int(code)
    payload["bassCode"] = Int(code)
    payload["errorMessage"] = message
    payload["operation"] = operation
    send(payload)
  }

  private func readPositionMs() -> Int {
    if stream == 0 { return 0 }
    let bytes = BASS_ChannelGetPosition(stream, UInt32(BASS_POS_BYTE))
    if bytes == UInt64.max { return 0 }
    let seconds = BASS_ChannelBytes2Seconds(stream, bytes)
    guard seconds.isFinite, seconds >= 0 else { return 0 }
    return Int(seconds * 1000)
  }

  private func readDurationMs() -> Int? {
    if stream == 0 { return nil }
    let bytes = BASS_ChannelGetLength(stream, UInt32(BASS_POS_BYTE))
    if bytes == 0 || bytes == UInt64.max { return nil }
    let seconds = BASS_ChannelBytes2Seconds(stream, bytes)
    guard seconds.isFinite, seconds > 0 else { return nil }
    return Int(seconds * 1000)
  }

  private func readBufferedPositionMs(_ positionMs: Int) -> Int {
    guard let duration = durationMs else { return positionMs }
    if !remoteSource { return duration }

    let fileEnd = BASS_StreamGetFilePosition(stream, UInt32(BASS_FILEPOS_END))
    let downloaded = BASS_StreamGetFilePosition(stream, UInt32(BASS_FILEPOS_DOWNLOAD))
    if fileEnd > 0, fileEnd != UInt64.max, downloaded != UInt64.max {
      let mapped = Int(Double(duration) * Double(downloaded) / Double(fileEnd))
      return min(max(mapped, positionMs), duration)
    }
    // 与 Android 一致：BASS_FILEPOS_BUFFERING 是预缓冲百分比，不能当已下载长度用。
    return positionMs
  }

  // MARK: - 周期快照

  private func syncTicking() {
    let shouldTick = playing || processingState == .buffering || processingState == .loading
    if shouldTick { startTicking() } else { stopTicking() }
  }

  private func startTicking() {
    guard tickTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: engineQueue)
    timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.refreshPlaybackStateQuietly()
      self.emitSnapshot()
    }
    tickTimer = timer
    timer.resume()
  }

  private func stopTicking() {
    tickTimer?.cancel()
    tickTimer = nil
  }

  private func refreshPlaybackStateQuietly() {
    if stream == 0 || completed { return }
    durationMs = readDurationMs() ?? durationMs
    switch BASS_ChannelIsActive(stream) {
    case UInt32(BASS_ACTIVE_PLAYING):
      playing = true
      processingState = .ready
    case UInt32(BASS_ACTIVE_STALLED):
      playing = true
      processingState = .buffering
    case UInt32(BASS_ACTIVE_PAUSED), UInt32(BASS_ACTIVE_PAUSED_DEVICE):
      playing = false
    case UInt32(BASS_ACTIVE_STOPPED):
      playing = false
    default:
      break
    }
  }

  // MARK: - 释放

  private func releaseStream() {
    stopTicking()
    cancelPreparation()
    finishFade()
    active = nil
  }

  private func disposeEngine() {
    releaseStream()
    // A cancelled URL decoder can still be returning on the worker.
    preloadQueue.sync {}
    if initialized {
      _ = BASS_Free()
    }
    initialized = false
    playing = false
    completed = false
    processingState = .idle
    durationMs = nil
  }

  deinit {
    releaseStream()
  }

  // MARK: - 工具

  /// BASS 的版本 DWORD -> "2.4.x.y"。
  static func versionString(_ version: UInt32) -> String {
    let major = (version >> 24) & 0xFF
    let minor = (version >> 16) & 0xFF
    let build = (version >> 8) & 0xFF
    let revision = version & 0xFF
    return "\(major).\(minor).\(build).\(revision)"
  }

  /// 与 Android 的 urlWithHeaders 完全一致：把请求头追加在 URL 之后，
  /// 用 \r\n 分隔并以空行结束，BASS 会把它当成 HTTP 请求头。
  static func urlWithHeaders(_ source: String, _ headers: [String: String]) -> String {
    if headers.isEmpty { return source }
    var result = source
    result += "\r\n"
    for (name, value) in headers {
      let safeName = name.replacingOccurrences(of: "\r", with: "")
        .replacingOccurrences(of: "\n", with: "")
      let safeValue = value.replacingOccurrences(of: "\r", with: "")
        .replacingOccurrences(of: "\n", with: "")
      result += "\(safeName): \(safeValue)\r\n"
    }
    result += "\r\n"
    return result
  }

  /// 与 Android 的 normalizedFormat 对齐。
  static func normalizedFormat(_ hint: String?, source: String) -> String {
    let trimmed = (hint ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    let path = URL(string: source)?.path ?? source
    let ext = (path as NSString).pathExtension.lowercased()

    if !trimmed.isEmpty {
      switch trimmed {
      case "flac", "ape", "alac", "m4a", "wv", "opus", "dsd", "ogg":
        return trimmed
      case "flac24bit", "hires", "master", "lossless":
        return "lossless"
      case "generic":
        return "generic"
      default:
        return "generic"
      }
    }

    switch ext {
    case "flac": return "flac"
    case "ape": return "ape"
    case "m4a", "mp4": return "m4a"
    case "wv": return "wv"
    case "opus", "ogg": return "opus"
    case "dsf", "dff": return "dsd"
    case "alac": return "alac"
    default: return "generic"
    }
  }

  struct ParsedBand {
    let filterType: CyShineFilterKind
    let frequencyHz: Double
    let gainDb: Double
    let q: Double
    let enabled: Bool
  }

  enum CyShineFilterKind: Int {
    case peaking = 0
    case lowShelf = 1
    case highShelf = 2
    case lowPass = 3
    case highPass = 4
  }

  static func parseBand(_ raw: [String: Any]) -> ParsedBand? {
    guard let name = raw["filter"] as? String else { return nil }
    let kind: CyShineFilterKind
    switch name {
    case "peaking", "peakingEq": kind = .peaking
    case "lowShelf": kind = .lowShelf
    case "highShelf": kind = .highShelf
    case "lowPass": kind = .lowPass
    case "highPass": kind = .highPass
    default: return nil
    }
    let frequency = (raw["frequencyHz"] as? NSNumber)?.doubleValue ?? 0
    let gain = (raw["gainDb"] as? NSNumber)?.doubleValue ?? 0
    let q = (raw["q"] as? NSNumber)?.doubleValue ?? 0.707
    return ParsedBand(filterType: kind, frequencyHz: frequency, gainDb: gain,
                      q: q, enabled: raw["enabled"] as? Bool ?? true)
  }
}

// MARK: - 错误类型

struct BassError: Error {
  let code: Int32
  let message: String
  let operation: String

  init(code: Int32, operation: String, message: String) {
    self.code = code
    self.operation = operation
    self.message = message
  }

  /// 读取 BASS_ErrorGetCode()，并翻译成与 Android 端 errorMessage 相同的中文/英文描述。
  static func fromLastError(operation: String) -> BassError {
    let code = BASS_ErrorGetCode()
    return BassError(code: code, operation: operation, message: message(for: code))
  }

  static func message(for code: Int32) -> String {
    switch code {
    case Int32(BASS_ERROR_MEM): return "out of memory"
    case Int32(BASS_ERROR_FILEOPEN): return "unable to open the source"
    case Int32(BASS_ERROR_DRIVER): return "can't find a free/valid driver"
    case Int32(BASS_ERROR_HANDLE): return "invalid handle"
    case Int32(BASS_ERROR_FORMAT): return "unsupported sample format"
    case Int32(BASS_ERROR_POSITION): return "invalid position"
    case Int32(BASS_ERROR_INIT): return "BASS_Init has not been successfully called"
    case Int32(BASS_ERROR_SSL): return "SSL/HTTPS support isn't available"
    case Int32(BASS_ERROR_ALREADY): return "already initialized"
    case Int32(BASS_ERROR_NOTAUDIO): return "file does not contain audio"
    case Int32(BASS_ERROR_NOCHAN): return "can't get a free channel"
    case Int32(BASS_ERROR_ILLTYPE): return "an illegal type was specified"
    case Int32(BASS_ERROR_ILLPARAM): return "an illegal parameter was specified"
    case Int32(BASS_ERROR_DEVICE): return "illegal device number"
    case Int32(BASS_ERROR_NOPLAY): return "not playing"
    case Int32(BASS_ERROR_FREQ): return "illegal sample rate"
    case Int32(BASS_ERROR_NONET): return "no internet connection could be opened"
    case Int32(BASS_ERROR_CREATE): return "couldn't create the file"
    case Int32(BASS_ERROR_NOFX): return "effects are not available"
    case Int32(BASS_ERROR_NOTAVAIL): return "requested data/action is not available"
    case Int32(BASS_ERROR_TIMEOUT): return "connection timed out"
    case Int32(BASS_ERROR_FILEFORM): return "unsupported file format"
    case Int32(BASS_ERROR_VERSION): return "invalid BASS version"
    case Int32(BASS_ERROR_CODEC): return "codec is not available/supported"
    case Int32(BASS_ERROR_ENDED): return "the channel/file has ended"
    case Int32(BASS_ERROR_BUSY): return "the device is busy"
    case Int32(BASS_ERROR_UNSTREAMABLE): return "unstreamable file"
    case Int32(BASS_ERROR_PROTOCOL): return "unsupported protocol"
    case Int32(BASS_ERROR_DENIED): return "access denied"
    case Int32(BASS_ERROR_FREEING): return "being freed"
    case Int32(BASS_ERROR_CANCEL): return "cancelled"
    default: return "unknown error (\(code))"
    }
  }
}
