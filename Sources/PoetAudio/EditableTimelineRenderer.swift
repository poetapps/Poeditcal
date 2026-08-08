import Foundation

struct EditableTimelineRequest: Sendable {
    let name: String
    let videoURL: URL
    let polishedAudioURL: URL
    let originalAudioURL: URL?
    let keptRanges: [AudioTimeRange]
    let sourceDuration: TimeInterval
    let frameRate: Double
    let width: Int
    let height: Int
}

enum EditableTimelineRenderer {
    static func render(_ request: EditableTimelineRequest, to folder: URL) throws {
        guard !request.keptRanges.isEmpty else { throw AudioRenderError.emptyEdit }
        let safeName = request.name.replacingOccurrences(of: "/", with: "-")
        try finalCutPro7XML(request).write(
            to: folder.appendingPathComponent("\(safeName)-Premiere.xml"),
            atomically: true,
            encoding: .utf8
        )
        let data = try JSONSerialization.data(
            withJSONObject: openTimelineIO(request),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: folder.appendingPathComponent("\(safeName)-Resolve.otio"), options: .atomic)
    }

    static func finalCutPro7XML(_ request: EditableTimelineRequest) -> String {
        let fps = normalizedFrameRate(request.frameRate)
        let timebase = max(1, Int(fps.rounded()))
        let ntsc = abs(fps - fps.rounded()) > 0.001
        let sourceFrames = frames(request.sourceDuration, rate: fps)
        let sequenceFrames = request.keptRanges.reduce(0) { $0 + frames($1.end - $1.start, rate: fps) }
        let rateXML = "<rate><timebase>\(timebase)</timebase><ntsc>\(ntsc ? "TRUE" : "FALSE")</ntsc></rate>"
        let videoPath = xmlEscape(request.videoURL.absoluteString)
        let polishedPath = xmlEscape(request.polishedAudioURL.absoluteString)
        let originalPath = request.originalAudioURL.map { xmlEscape($0.absoluteString) }

        var timelineCursor = 0
        var videoClips = ""
        var originalClips = ""
        var polishedClips = ""
        for (index, range) in request.keptRanges.enumerated() {
            let sourceIn = frames(range.start, rate: fps)
            let clipDuration = frames(range.end - range.start, rate: fps)
            let timelineEnd = timelineCursor + clipDuration
            videoClips += clipItem(
                id: "video-\(index + 1)", name: request.videoURL.lastPathComponent,
                start: timelineCursor, end: timelineEnd, sourceIn: sourceIn,
                sourceOut: sourceIn + clipDuration, fileID: "source-video", filePath: videoPath,
                sourceFrames: sourceFrames, rateXML: rateXML, mediaType: "video",
                width: request.width, height: request.height, includeFile: index == 0
            )
            if let originalPath {
                originalClips += clipItem(
                    id: "original-audio-\(index + 1)", name: request.originalAudioURL!.lastPathComponent,
                    start: timelineCursor, end: timelineEnd, sourceIn: sourceIn,
                    sourceOut: sourceIn + clipDuration, fileID: "original-audio", filePath: originalPath,
                    sourceFrames: sourceFrames, rateXML: rateXML, mediaType: "audio",
                    width: request.width, height: request.height, includeFile: index == 0
                )
            } else {
                originalClips += clipItem(
                    id: "camera-audio-\(index + 1)", name: request.videoURL.lastPathComponent,
                    start: timelineCursor, end: timelineEnd, sourceIn: sourceIn,
                    sourceOut: sourceIn + clipDuration, fileID: "source-video", filePath: videoPath,
                    sourceFrames: sourceFrames, rateXML: rateXML, mediaType: "audio",
                    width: request.width, height: request.height, includeFile: false
                )
            }
            polishedClips += clipItem(
                id: "polished-audio-\(index + 1)", name: request.polishedAudioURL.lastPathComponent,
                start: timelineCursor, end: timelineEnd, sourceIn: sourceIn,
                sourceOut: sourceIn + clipDuration, fileID: "polished-audio", filePath: polishedPath,
                sourceFrames: sourceFrames, rateXML: rateXML, mediaType: "audio",
                width: request.width, height: request.height, includeFile: index == 0
            )
            timelineCursor = timelineEnd
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE xmeml>
        <xmeml version="5"><sequence id="poet-sequence"><name>\(xmlEscape(request.name))</name>
        <duration>\(sequenceFrames)</duration>\(rateXML)<timecode><string>00:00:00:00</string>\(rateXML)</timecode>
        <media><video><format><samplecharacteristics>\(rateXML)<width>\(request.width)</width><height>\(request.height)</height></samplecharacteristics></format><track>\(videoClips)</track></video>
        <audio><format><samplecharacteristics><depth>24</depth><samplerate>48000</samplerate></samplecharacteristics></format>
        <track><name>Original audio</name>\(originalClips)</track>
        <track><name>Poet polished audio</name>\(polishedClips)</track></audio></media></sequence></xmeml>
        """
    }

    static func openTimelineIO(_ request: EditableTimelineRequest) -> [String: Any] {
        let rate = normalizedFrameRate(request.frameRate)
        let videoChildren = request.keptRanges.enumerated().map { index, range in
            otioClip(name: "Camera \(index + 1)", url: request.videoURL, range: range, rate: rate, duration: request.sourceDuration)
        }
        let originalURL = request.originalAudioURL ?? request.videoURL
        let originalChildren = request.keptRanges.enumerated().map { index, range in
            otioClip(name: "Original audio \(index + 1)", url: originalURL, range: range, rate: rate, duration: request.sourceDuration)
        }
        let polishedChildren = request.keptRanges.enumerated().map { index, range in
            otioClip(name: "Poet polished audio \(index + 1)", url: request.polishedAudioURL, range: range, rate: rate, duration: request.sourceDuration)
        }
        return [
            "OTIO_SCHEMA": "Timeline.1",
            "name": request.name,
            "metadata": [:],
            "global_start_time": rationalTime(0, rate: rate),
            "tracks": [
                "OTIO_SCHEMA": "Stack.1", "name": "tracks", "metadata": [:], "effects": [], "markers": [],
                "enabled": true, "source_range": NSNull(),
                "children": [
                    otioTrack(name: "Video", kind: "Video", children: videoChildren),
                    otioTrack(name: "Original audio", kind: "Audio", children: originalChildren),
                    otioTrack(name: "Poet polished audio", kind: "Audio", children: polishedChildren)
                ]
            ]
        ]
    }

    private static func otioTrack(name: String, kind: String, children: [[String: Any]]) -> [String: Any] {
        ["OTIO_SCHEMA": "Track.1", "name": name, "kind": kind, "children": children,
         "metadata": [:], "effects": [], "markers": [], "enabled": true, "source_range": NSNull()]
    }

    private static func otioClip(name: String, url: URL, range: AudioTimeRange, rate: Double, duration: TimeInterval) -> [String: Any] {
        let reference: [String: Any] = [
            "OTIO_SCHEMA": "ExternalReference.1", "name": url.lastPathComponent,
            "target_url": url.absoluteString, "metadata": [:], "available_image_bounds": NSNull(),
            "available_range": timeRange(start: 0, duration: duration, rate: rate)
        ]
        return [
            "OTIO_SCHEMA": "Clip.2", "name": name, "metadata": [:], "effects": [], "markers": [],
            "enabled": true,
            "source_range": timeRange(start: range.start, duration: range.end - range.start, rate: rate),
            "media_references": ["DEFAULT_MEDIA": reference],
            "active_media_reference_key": "DEFAULT_MEDIA"
        ]
    }

    private static func timeRange(start: TimeInterval, duration: TimeInterval, rate: Double) -> [String: Any] {
        ["OTIO_SCHEMA": "TimeRange.1", "start_time": rationalTime(start * rate, rate: rate),
         "duration": rationalTime(duration * rate, rate: rate)]
    }

    private static func rationalTime(_ value: Double, rate: Double) -> [String: Any] {
        ["OTIO_SCHEMA": "RationalTime.1", "value": value, "rate": rate]
    }

    private static func clipItem(
        id: String, name: String, start: Int, end: Int, sourceIn: Int, sourceOut: Int,
        fileID: String, filePath: String, sourceFrames: Int, rateXML: String,
        mediaType: String, width: Int, height: Int, includeFile: Bool
    ) -> String {
        let file: String
        if includeFile {
            let characteristics = mediaType == "video"
                ? "<video><samplecharacteristics>\(rateXML)<width>\(width)</width><height>\(height)</height></samplecharacteristics></video><audio><samplecharacteristics><depth>24</depth><samplerate>48000</samplerate></samplecharacteristics></audio>"
                : "<audio><samplecharacteristics><depth>24</depth><samplerate>48000</samplerate></samplecharacteristics></audio>"
            file = "<file id=\"\(fileID)\"><name>\(xmlEscape(name))</name><pathurl>\(filePath)</pathurl><duration>\(sourceFrames)</duration>\(rateXML)<media>\(characteristics)</media></file>"
        } else {
            file = "<file id=\"\(fileID)\"/>"
        }
        let sourceTrack = mediaType == "audio" ? "<sourcetrack><mediatype>audio</mediatype><trackindex>1</trackindex></sourcetrack>" : ""
        return "<clipitem id=\"\(id)\"><name>\(xmlEscape(name))</name><duration>\(sourceFrames)</duration>\(rateXML)<start>\(start)</start><end>\(end)</end><in>\(sourceIn)</in><out>\(sourceOut)</out>\(file)\(sourceTrack)</clipitem>"
    }

    private static func normalizedFrameRate(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 30 }
        let common = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
        return common.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }

    private static func frames(_ seconds: TimeInterval, rate: Double) -> Int {
        max(0, Int((seconds * rate).rounded()))
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
