import XCTest
import CoreGraphics
import FoundationModels
import SQLite3

@testable import Dayflow

private struct SpikePromptSupport: ChatGPTTimelinePromptSupporting {}

private var spikeOutput = ""

private func spikeLog(_ message: String) {
  let line = "SPIKE " + message + "\n"
  spikeOutput += line
  FileHandle.standardOutput.write(Data(line.utf8))
  FileHandle.standardError.write(Data(line.utf8))
}

private func spikeOpenReadOnlyDB() -> OpaquePointer? {
  let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Dayflow", isDirectory: true)
    .appendingPathComponent("chunks.sqlite")
    .path
  var db: OpaquePointer?
  guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
    if let db { sqlite3_close(db) }
    return nil
  }
  return db
}

private func spikeQuery(_ db: OpaquePointer, _ sql: String) -> [[String]] {
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
  defer { sqlite3_finalize(statement) }

  var rows: [[String]] = []
  while sqlite3_step(statement) == SQLITE_ROW {
    var row: [String] = []
    for index in 0..<sqlite3_column_count(statement) {
      if let value = sqlite3_column_text(statement, index) {
        row.append(String(cString: value))
      } else {
        row.append("")
      }
    }
    rows.append(row)
  }
  return rows
}

private func spikeBatchSQL() throws -> String {
  var selection = ""
  if let raw = ProcessInfo.processInfo.environment["DAYFLOW_FM_SPIKE_BATCH_ID"] {
    guard let id = Int64(raw), id > 0 else {
      throw NSError(domain: "FoundationModelsSpike", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "DAYFLOW_FM_SPIKE_BATCH_ID must be a positive batch ID"])
    }
    selection = "id = \(id) AND "
  }
  return "SELECT id, batch_start_ts, batch_end_ts FROM analysis_batches WHERE "
    + selection + "status IN ('completed','analyzed') ORDER BY batch_start_ts DESC LIMIT 1"
}

@available(macOS 27.0, *)
final class FoundationModelsSpikeTests: XCTestCase {
  private func attachSpikeOutput(named name: String) {
    let attachment = XCTAttachment(string: spikeOutput)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testFrameDescriptionLatencyAndQuality() async throws {
    guard ProcessInfo.processInfo.environment["DAYFLOW_FM_SPIKE"] == "1" else {
      throw XCTSkip("Set DAYFLOW_FM_SPIKE=1 to run the Foundation Models spike.")
    }
    guard #available(macOS 27.0, *) else {
      throw XCTSkip("Foundation Models image + Generable path needs macOS 27.")
    }
    spikeOutput = ""
    guard SystemLanguageModel.default.availability == .available else {
      XCTFail("availability=\(SystemLanguageModel.default.availability)")
      return
    }

    guard let db = spikeOpenReadOnlyDB() else {
      XCTFail("Could not open the Dayflow database read-only.")
      return
    }
    defer { sqlite3_close(db) }

    let batchRows = spikeQuery(
      db,
      try spikeBatchSQL()
    )
    guard let batch = batchRows.first,
      batch.count >= 3,
      let batchId = Int64(batch[0])
    else {
      XCTFail("No completed or analyzed batch was found.")
      return
    }
    let screenshotRows = spikeQuery(
      db,
      "SELECT s.id, s.captured_at, s.file_path, s.file_size, s.idle_seconds_at_capture, "
        + "s.is_deleted, s.frame_index FROM batch_screenshots bs JOIN screenshots s "
        + "ON s.id = bs.screenshot_id WHERE bs.batch_id = \(batchId) AND s.is_deleted = 0 "
        + "ORDER BY s.captured_at ASC"
    )
    guard screenshotRows.count >= 12 else {
      XCTFail("Need at least 12 screenshots in the selected batch.")
      return
    }

    let screenshots = screenshotRows.compactMap { row -> Screenshot? in
      guard row.count >= 7,
        let id = Int64(row[0]),
        let capturedAt = Int(row[1])
      else { return nil }
      return Screenshot(
        id: id,
        capturedAt: capturedAt,
        filePath: row[2],
        fileSize: row[3].isEmpty ? nil : Int64(row[3]),
        idleSecondsAtCapture: row[4].isEmpty ? nil : Int(row[4]),
        isDeleted: row[5] == "1",
        frameIndex: row[6].isEmpty ? nil : Int(row[6])
      )
    }
    guard screenshots.count >= 12 else {
      XCTFail("Could not decode the selected screenshot rows.")
      return
    }
    let sampled = (0..<12).map { index in
      let offset = Int((Double(index) * Double(screenshots.count - 1) / 11.0).rounded())
      return screenshots[offset]
    }
    for (index, screenshot) in sampled.enumerated() {
      spikeLog("frame_path i=\(index) id=\(screenshot.id) \(screenshot.filePath)")
    }

    let instructions = FoundationModelsProvider(logsCalls: false).screenshotInstructions()
    if let full = sampled[0].loadCGImage(), let image = FrameStore.downscaled(full, maxPixelSize: 1280) {
      do {
        _ = try await FoundationModelsProvider.describeFrame(image: image,
          headerImage: ScreenshotHeaderOCR.crop(from: full), headerText: ScreenshotHeaderOCR.text(in: full),
          instructions: instructions)
      } catch {
        spikeLog("warmup_error type=\(String(describing: type(of: error)))")
      }
    }

    for size in [720, 1280, 1920] {
      var latencies: [Double] = []
      var decodeFailures = 0
      for (index, screenshot) in sampled.enumerated() {
        guard let full = screenshot.loadCGImage(), let image = FrameStore.downscaled(full, maxPixelSize: size) else {
          decodeFailures += 1
          spikeLog("frame_decode_failed id=\(screenshot.id)")
          continue
        }
        let headerImage = ScreenshotHeaderOCR.crop(from: full)
        let headerText = ScreenshotHeaderOCR.text(in: full)
        let started = DispatchTime.now()
        do {
          let content = try await FoundationModelsProvider.describeFrame(image: image,
            headerImage: headerImage, headerText: headerText, instructions: instructions)
          let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds)
            / 1_000_000
          latencies.append(elapsed)
          spikeLog(
            String(
              format: "frame size=%d i=%d id=%lld ms=%.1f app=%@ | activity=%@",
              size,
              index,
              screenshot.id,
              elapsed,
              content.app,
              content.activity
            )
          )
          XCTAssertFalse(content.app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } catch {
          let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds)
            / 1_000_000
          latencies.append(elapsed)
          spikeLog(
            String(
              format: "frame size=%d i=%d id=%lld ms=%.1f app=%@ | activity=%@",
              size,
              index,
              screenshot.id,
              elapsed,
              "[refused]",
              "[refused]"
            )
          )
        }
      }
      XCTAssertEqual(latencies.count, sampled.count - decodeFailures)
      spikeLog("quality_block size=\(size) frames=12")
      let sorted = latencies.sorted()
      let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
      spikeLog(String(format: "p50 size=%d ms=%.1f", size, p50))
    }
    attachSpikeOutput(named: "Foundation Models frame spike")
  }

  func testCardPromptTokenBudget() async throws {
    guard ProcessInfo.processInfo.environment["DAYFLOW_FM_SPIKE"] == "1" else {
      throw XCTSkip("Set DAYFLOW_FM_SPIKE=1 to run the Foundation Models spike.")
    }
    guard #available(macOS 27.0, *) else {
      throw XCTSkip("Foundation Models image + Generable path needs macOS 27.")
    }
    spikeOutput = ""

    guard let db = spikeOpenReadOnlyDB() else {
      XCTFail("Could not open the Dayflow database read-only.")
      return
    }
    defer { sqlite3_close(db) }
    guard let batch = spikeQuery(
      db,
      try spikeBatchSQL()
    ).first,
      batch.count >= 3,
      let endTs = Int(batch[2])
    else {
      XCTFail("No completed or analyzed batch was found.")
      return
    }
    let fromTs = endTs - 2700
    let observationRows = spikeQuery(
      db,
      "SELECT start_ts, end_ts, observation FROM observations WHERE "
        + "(start_ts < \(endTs) AND end_ts > \(fromTs)) OR "
        + "(start_ts >= \(fromTs) AND start_ts < \(endTs)) ORDER BY start_ts ASC"
    )
    let cardRows = spikeQuery(
      db,
      "SELECT start_ts, end_ts, category, title, summary FROM timeline_cards WHERE "
        + "((start_ts < \(endTs) AND end_ts > \(fromTs)) OR "
        + "(start_ts >= \(fromTs) AND start_ts < \(endTs))) AND is_deleted = 0 "
        + "AND category != 'System' ORDER BY start_ts ASC"
    )
    let categories = SpikePromptSupport().categoriesSection(from: CategoryStore.descriptorsForLLM())
    var parts: [String] = [categories, "", "OBSERVATIONS:"]
    parts.append(
      contentsOf: observationRows.compactMap { row in
        guard row.count >= 3, let start = Int(row[0]), let end = Int(row[1]) else { return nil }
        return "[\(spikeTimeString(start)) - \(spikeTimeString(end))] "
          + String(row[2].prefix(280))
      }
    )
    parts.append("")
    parts.append("EXISTING CARDS:")
    parts.append(
      contentsOf: cardRows.compactMap { row in
        guard row.count >= 5, let start = Int(row[0]), let end = Int(row[1]) else { return nil }
        return "EXISTING CARD [\(spikeTimeString(start)) - \(spikeTimeString(end))] "
          + row[2] + " | " + row[3] + " | " + row[4]
      }
    )
    let promptText = parts.joined(separator: "\n")
    let tokens = try await SystemLanguageModel.default.tokenCount(for: promptText)
    let contextSize = SystemLanguageModel.default.contextSize
    spikeLog("cards_prompt_inputs observations=\(observationRows.count) existing_cards=\(cardRows.count)")
    spikeLog("cards_prompt_tokens_45min=\(tokens)")
    spikeLog("context_size=\(contextSize)")
    XCTAssertGreaterThan(tokens, 0)
    attachSpikeOutput(named: "Foundation Models card prompt budget")
  }

  func testTwoSessionsSequentialSanity() async throws {
    guard ProcessInfo.processInfo.environment["DAYFLOW_FM_SPIKE"] == "1" else {
      throw XCTSkip("Set DAYFLOW_FM_SPIKE=1 to run the Foundation Models spike.")
    }
    guard #available(macOS 27.0, *) else {
      throw XCTSkip("Foundation Models image + Generable path needs macOS 27.")
    }
    spikeOutput = ""
    guard SystemLanguageModel.default.availability == .available else {
      XCTFail("availability=\(SystemLanguageModel.default.availability)")
      return
    }

    let first = try await LanguageModelSession(instructions: "Answer in one word.")
      .respond(to: "Name the capital of France.").content
    let second = try await LanguageModelSession(instructions: "Answer in one word.")
      .respond(to: "Name the largest ocean.").content
    XCTAssertFalse(first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    XCTAssertFalse(second.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    spikeLog("sanity a_len=\(first.count) b_len=\(second.count)")
    attachSpikeOutput(named: "Foundation Models session sanity")
  }
}

private func spikeTimeString(_ unixTime: Int) -> String {
  let formatter = DateFormatter()
  formatter.dateFormat = "h:mm a"
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone.current
  return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixTime)))
}
