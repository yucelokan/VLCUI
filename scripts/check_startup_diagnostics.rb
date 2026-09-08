#!/usr/bin/env ruby
# Pure Swift privacy/budget checks; optional local-only VLCKit HTTP fixture.
# No Xcode project, simulator, device or provider connection is used.
require 'open3'
require 'socket'

root = File.expand_path('..', __dir__)
policy = File.read(File.join(root, 'Sources/VLCUI/VLCStartupDiagnosticPolicy.swift'))
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
    precondition(VLCStartupDiagnosticPolicy.event(for: message) == expected)
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
print("PASS \(cases.count) privacy cases, repeat/total/time limits and epoch reset")
SWIFT
stdout, stderr, status = Open3.capture3('xcrun', 'swift', '-', stdin_data: policy + checks)
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
driver = File.read(File.join(root, 'Sources/VLCUI/VLCStartupDiagnostics.swift'))
driver += <<~SWIFT
  let fixturePlayer = VLCMediaPlayer()
  let fixtureURL = URL(string: "http://127.0.0.1:#{port}/PRIVATE_FIXTURE_SECRET.mkv")!
  MainActor.assumeIsolated { VLCStartupDiagnostics.begin(player: fixturePlayer, url: fixtureURL) }
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
    stdin_data: policy + driver
  )
  combined = stdout + stderr
  abort 'FAIL: private fixture data escaped the logger' if combined.include?('PRIVATE_FIXTURE_SECRET')
  abort 'FAIL: VLCKit fixture did not run' unless status.success?
  abort 'FAIL: libVLC HTTP response was not observed' unless combined.include?('event=http_status_503')
  puts 'PASS real cached macOS VLCKit local HTTP 503 fixture; URL/header remain private'
ensure
  worker.kill
  server.close
end
