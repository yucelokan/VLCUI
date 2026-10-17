#!/usr/bin/env ruby
# Pure Swift privacy/budget checks; optional local-only VLCKit HTTP fixture.
# No Xcode project, simulator, device or provider connection is used.
require 'open3'
require 'socket'

root = File.expand_path('..', __dir__)
policy = File.read(File.join(root, 'Sources/VLCUI/VLCStartupDiagnosticPolicy.swift'))
delivery = File.read(File.join(root, 'Sources/VLCUI/VLCPlaybackDiagnostics.swift'))
checks = <<'SWIFT'
let cases: [(String, String?)] = [
    ("outgoing request:\nGET /account/secret.mkv HTTP/1.1\r\nAuthorization: Bearer secret", "http_request_prepared"),
    ("incoming response:\nHTTP/1.1 503 Busy\r\nSet-Cookie: secret", "http_status_503"),
    ("incoming response:\r\nHTTP/1.1 206 Partial Content\r\nLocation: http://user:secret@example.test", "http_status_206"),
    ("HTTP answer code 302", "http_status_302"),
    ("HTTP answer code secret", nil),
    ("incoming response:\nHTTP/1.1 secret", nil),
    ("net: connecting to private-host port 80", "connection_attempt"),
    ("connection failed: secret-host", "connection_failed"),
    ("using demux module \"mkv\"", "demux_module_selected"),
    ("using audio output module \"audiounit_ios\"", "audio_output_selected"),
    ("Location: http://user:secret@example.test", nil),
    ("Authorization: Bearer secret", nil),
    ("unknown failure containing secret", nil),
    ("buffering done (1200 ms in 34 ms)", "buffering_complete"),
]
for (message, expected) in cases {
    let event = VLCStartupDiagnosticPolicy.event(for: message)
    precondition(event == expected)
    if let event {
        let projected = VLCPlaybackDiagnosticEvent.sharedLibrary(event: event, startupWindow: 1)
        precondition(projected?.event == expected && projected?.scope == .sharedLibrary && projected?.playerID == nil)
    }
}
var budget = VLCStartupDiagnosticBudget()
precondition(!budget.isRecording(now: 0))
budget.begin(now: 10)
for _ in 0..<3 { precondition(budget.accept(event: "connection_attempt", objectID: 1, now: 11)) }
precondition(!budget.accept(event: "connection_attempt", objectID: 1, now: 11))
precondition(!budget.accept(event: "new_event", objectID: 2, now: 40))
budget.begin(now: 50)
precondition(budget.epoch == 2)
for i in 0..<128 { precondition(budget.accept(event: "event", objectID: UInt(i), now: 51)) }
precondition(!budget.accept(event: "event", objectID: 999, now: 51))

var activity = VLCStartupNetworkActivityTracker()
activity.observe(event: "http_status_302", now: 99) // Late status without a request is ignored.
precondition(activity.snapshot(now: 100).responseCount == 0)
activity.observe(event: "http_request_prepared", now: 100)
precondition(activity.snapshot(now: 101).pendingRequestAge == 1)
precondition(!activity.snapshot(now: 101).pendingRequestFollowsRedirect)
activity.observe(event: "http_status_302", now: 101.5)
precondition(activity.snapshot(now: 102).lastHTTPStatusCode == 302)
activity.observe(event: "http_request_prepared", now: 102)
let redirected = activity.snapshot(now: 108)
precondition(redirected.pendingRequestAge == 6)
precondition(redirected.pendingRequestFollowsRedirect)
activity.observe(event: "http_status_200", now: 108)
let completed = activity.snapshot(now: 109)
precondition(completed.responseCount == 2)
precondition(completed.lastHTTPStatusCode == 200)
precondition(!completed.hasPendingRequest)

final class CapturedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [VLCPlaybackDiagnosticEvent] = []
    let delivered = DispatchSemaphore(value: 0)
    func append(_ value: VLCPlaybackDiagnosticEvent) {
        lock.lock(); values.append(value); lock.unlock()
        delivered.signal()
    }
    var snapshot: [VLCPlaybackDiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }; return values
    }
}
let captured = CapturedEvents()
let boundedCapture = CapturedEvents()
let releaseDelivery = DispatchSemaphore(value: 0)
VLCPlaybackDiagnostics.install { event in
    releaseDelivery.wait()
    boundedCapture.append(event)
    releaseDelivery.signal()
}
for _ in 0..<1_000 {
    VLCPlaybackDiagnostics.emit(.init(scope: .sharedLibrary, kind: .connectionFailed, startupWindow: 1))
}
releaseDelivery.signal()
for _ in 0..<256 { precondition(boundedCapture.delivered.wait(timeout: .now() + 5) == .success) }
precondition(boundedCapture.delivered.wait(timeout: .now() + 0.1) == .timedOut)
precondition(boundedCapture.snapshot.count == 256)
VLCPlaybackDiagnostics.install { captured.append($0) }
let outgoingID = UUID(), incomingID = UUID()
var outgoing = VLCPlayerDiagnosticSession(playerID: outgoingID, now: 100)
var incoming = VLCPlayerDiagnosticSession(playerID: incomingID, now: 101)
outgoing.reportError(now: 102)
outgoing.reportError(now: 103) // Once per concrete player, even after a replacement.
incoming.reportError(now: 104)
let shared = VLCPlaybackDiagnosticEvent(scope: .sharedLibrary, kind: .httpStatus,
    httpStatusCode: 503, playerID: incomingID, startupWindow: 2)
precondition(shared.playerID == nil)
VLCPlaybackDiagnostics.emit(shared)
for _ in 0..<5 { precondition(captured.delivered.wait(timeout: .now() + 5) == .success) }
let events = captured.snapshot
precondition(events.count == 5)
precondition(events[2].playerID == outgoingID && events[3].playerID == incomingID)
precondition(events[2].elapsedMilliseconds == 2_000 && events[3].elapsedMilliseconds == 3_000)
precondition(shared.scope == .sharedLibrary && shared.playerID == nil && shared.startupWindow == 2)
precondition(shared.kind == .httpStatus && shared.httpStatusCode == 503 && shared.event == "http_status_503")
precondition(events[2].kind == .playerError && events[3].kind == .playerError)
for value in ["http_status_99", "http_status_600", "http_status_secret", "private.example", "Authorization: Bearer secret", "player_error"] {
    precondition(VLCPlaybackDiagnosticEvent.sharedLibrary(event: value, startupWindow: 2) == nil)
}
for value in [100, 599] {
    let event = VLCPlaybackDiagnosticEvent.sharedLibrary(event: "http_status_\(value)", startupWindow: 2)!
    precondition(event.kind == .httpStatus && event.httpStatusCode == value)
}
let invalidStatus = VLCPlaybackDiagnosticEvent(scope: .sharedLibrary, kind: .httpStatus, httpStatusCode: 600)
precondition(invalidStatus.httpStatusCode == nil && invalidStatus.event == "http_status_unavailable")
let unrelatedStatus = VLCPlaybackDiagnosticEvent(scope: .player, kind: .playerError, httpStatusCode: 401)
precondition(unrelatedStatus.httpStatusCode == nil)
precondition(events.allSatisfy { !$0.event.contains("secret") && !$0.event.contains("http://") })
VLCPlaybackDiagnostics.install(nil)
print("PASS \(cases.count) privacy cases, repeat/total/time limits and epoch reset")
print("PASS immutable player identity, shared ownership, closed event kinds, HTTP bounds, terminal deduplication and bounded host delivery")
SWIFT
stdout, stderr, status = Open3.capture3('xcrun', 'swift', '-', stdin_data: policy + delivery + checks)
print stdout
warn stderr unless stderr.empty?
exit(status.exitstatus || 1) unless status.success?
exit unless ARGV.include?('--with-vlckit-fixture')

debug = File.join(root, '.build/arm64-apple-macosx/debug')
abort 'Cached macOS VLCKit framework required for opt-in fixture' unless File.directory?(File.join(debug, 'VLCKit.framework'))
server = TCPServer.new('127.0.0.1', 0)
port = server.addr[1]
worker = Thread.new do
  loop do
    client = server.accept
    begin
      # A synthetic 503 with a deliberately sensitive-looking response header:
      # the classifier must expose only the status, never the header or URL.
      request = +''
      request << client.readpartial(4096) until request.include?("\r\n\r\n")
      client.write("HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\nSet-Cookie: PRIVATE_FIXTURE_SECRET\r\n\r\n")
    rescue IOError, SystemCallError
      # libVLC may cancel a fallback while the fixture is responding.
    ensure
      client.close
    end
  end
end
# Import the framework directly; a cached Swift re-export module can belong to
# the previous Xcode after an upgrade even though the binary framework is valid.
driver = File.read(File.join(root, 'Sources/VLCUI/VLCStartupDiagnostics.swift')).sub('import VLCKitSPM', 'import VLCKit')
driver += <<~SWIFT
  let fixturePlayer = VLCMediaPlayer()
  let fixtureURL = URL(string: "http://127.0.0.1:#{port}/PRIVATE_FIXTURE_SECRET.mkv")!
  VLCPlaybackDiagnostics.install { event in print("BUDGET_RECEIVED " + event.scope.rawValue + " " + event.event) }
  let budgetEpoch = MainActor.assumeIsolated {
      VLCStartupDiagnostics.begin(player: fixturePlayer, url: fixtureURL, emitsLogEvents: false)
  }
  let fixtureLogger = fixturePlayer.libraryInstance.loggers!.compactMap { $0 as? VLCStartupDiagnostics }.first!
  for _ in 0..<5 {
      fixtureLogger.handleMessage("outgoing request:\\nAuthorization: PRIVATE_FIXTURE_SECRET", logLevel: .debug, context: nil)
  }
  for code in 100..<300 {
      fixtureLogger.handleMessage("HTTP answer code \\(code)", logLevel: .debug, context: nil)
  }
  fixtureLogger.handleMessage("outgoing request:", logLevel: .debug, context: nil)
  precondition(VLCStartupDiagnostics.networkActivity(epoch: budgetEpoch)?.requestCount == 6)
  precondition(VLCStartupDiagnostics.networkActivity(epoch: budgetEpoch)?.hasPendingRequest == true)
  VLCPlaybackDiagnostics.install { event in print("HOST_RECEIVED " + event.scope.rawValue + " " + event.event) }
  _ = MainActor.assumeIsolated { VLCStartupDiagnostics.begin(player: fixturePlayer, url: fixtureURL, emitsLogEvents: false) }
  fixturePlayer.audio?.volume = 0
  fixturePlayer.media = VLCMedia(url: fixtureURL)
  fixturePlayer.play()
  RunLoop.current.run(until: Date().addingTimeInterval(2))
  fixturePlayer.stop()
  RunLoop.current.run(until: Date().addingTimeInterval(0.2))
  withExtendedLifetime(fixturePlayer) {}
SWIFT
begin
  stdout, stderr, status = Open3.capture3(
    { 'DYLD_FRAMEWORK_PATH' => debug },
    'xcrun', 'swift', '-I', File.join(debug, 'Modules'), '-F', debug, '-framework', 'VLCKit', '-',
    stdin_data: policy + delivery + driver
  )
  combined = stdout + stderr
  abort 'FAIL: private fixture data escaped the logger' if combined.include?('PRIVATE_FIXTURE_SECRET')
  abort 'FAIL: VLCKit fixture did not run' unless status.success?
  abort 'FAIL: startup observer event budget changed' unless combined.lines.count { |line| line.start_with?('BUDGET_RECEIVED ') } == 128
  abort 'FAIL: libVLC HTTP response did not reach the host sink in production mode' unless combined.include?('HOST_RECEIVED shared_library http_status_503')
  puts 'PASS real cached macOS VLCKit local HTTP 503 reaches host with console diagnostics off; budget 128; recovery tracker unchanged; URL/header private'
ensure
  worker.kill
  server.close
end
