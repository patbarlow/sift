import Foundation

/// Thin client over Granola's public API (docs.granola.ai).
/// Auth: bearer token (`grn_…`), set per-request.
actor GranolaClient {
    enum GranolaError: LocalizedError {
        case missingKey
        case http(Int, String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: return "Granola API key not configured."
            case .http(let c, let body): return "Granola HTTP \(c): \(body.prefix(200))"
            case .decode(let s): return "Granola decode: \(s)"
            }
        }
    }

    private let apiKey: String
    private let base: URL

    init(apiKey: String, baseURL: URL = URL(string: "https://public-api.granola.ai")!) {
        self.apiKey = apiKey
        self.base = baseURL
    }

    // MARK: - Public types (consumed by SyncWorker)

    /// Summary returned from the list endpoint.
    struct Meeting: Hashable {
        let id: String
        let title: String?
        let createdAt: Date?
        let updatedAt: Date?
        let url: URL?      // populated after fetching detail
    }

    struct ActionItem: Hashable {
        let text: String
        let assignee: String?
        let completed: Bool
    }

    struct MeetingDetail {
        let id: String
        let title: String
        let endedAt: Date?  // best-effort: calendar end or updated_at
        let url: URL?
        let summary: String?
        let transcript: String?  // condensed speaker-labelled transcript for LLM
        let participantNames: [String]
    }

    // MARK: - Endpoints

    /// List notes updated since the given date. Max page_size is 30.
    func listMeetings(since: Date?) async throws -> [Meeting] {
        var params: [URLQueryItem] = [
            URLQueryItem(name: "page_size", value: "30"),
        ]
        if let since {
            let iso = ISO8601DateFormatter().string(from: since)
            params.append(URLQueryItem(name: "updated_after", value: iso))
        }

        struct NoteSummary: Decodable {
            let id: String
            let title: String?
            let created_at: Date?
            let updated_at: Date?
        }
        struct Resp: Decodable {
            let notes: [NoteSummary]
            let hasMore: Bool
            let cursor: String?
        }

        var all: [Meeting] = []
        var cursor: String? = nil
        var pages = 0

        repeat {
            var pageParams = params
            if let c = cursor { pageParams.append(URLQueryItem(name: "cursor", value: c)) }

            let resp: Resp = try await get("/v1/notes", params: pageParams)
            all.append(contentsOf: resp.notes.map { note in
                Meeting(
                    id: note.id,
                    title: note.title,
                    createdAt: note.created_at,
                    updatedAt: note.updated_at,
                    url: nil
                )
            })
            cursor = resp.hasMore ? resp.cursor : nil
            pages += 1
        } while cursor != nil && pages < 5

        return all
    }

    /// Fetch a single note with summary, transcript, and attendees.
    func meetingDetail(id: String) async throws -> MeetingDetail {
        struct UserDTO: Decodable {
            let name: String?
            let email: String?
        }
        struct CalendarEventDTO: Decodable {
            let scheduled_end_time: Date?
        }
        struct TranscriptDTO: Decodable {
            let speaker: Speaker?
            let text: String?
            let start_time: Date?
            struct Speaker: Decodable {
                let source: String?
                let diarization_label: String?
            }
        }
        struct Resp: Decodable {
            let id: String
            let title: String?
            let updated_at: Date?
            let web_url: String?
            let summary_text: String?
            let summary_markdown: String?
            let attendees: [UserDTO]?
            let calendar_event: CalendarEventDTO?
            let transcript: [TranscriptDTO]?
        }

        let params = [URLQueryItem(name: "include", value: "transcript")]
        let resp: Resp = try await get("/v1/notes/\(id)", params: params)

        let names = (resp.attendees ?? []).compactMap { u -> String? in
            if let n = u.name, !n.isEmpty { return n }
            return u.email
        }

        let endedAt = resp.calendar_event?.scheduled_end_time ?? resp.updated_at
        let webURL = resp.web_url.flatMap(URL.init(string:))

        // Build a condensed transcript string for LLM consumption.
        // Label speakers by source (microphone = you, speaker = others)
        // or diarization label when available.
        let transcriptText: String? = resp.transcript.flatMap { segments in
            guard !segments.isEmpty else { return nil }
            let lines = segments.prefix(200).compactMap { seg -> String? in
                guard let text = seg.text, !text.isEmpty else { return nil }
                let speaker = seg.speaker?.diarization_label
                    ?? (seg.speaker?.source == "microphone" ? "You" : "Other")
                return "\(speaker): \(text)"
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }

        return MeetingDetail(
            id: resp.id,
            title: resp.title ?? "(untitled meeting)",
            endedAt: endedAt,
            url: webURL,
            summary: resp.summary_text,
            transcript: transcriptText,
            participantNames: names
        )
    }

    // MARK: - HTTP plumbing

    private func get<T: Decodable>(_ path: String, params: [URLQueryItem]) async throws -> T {
        var comps = URLComponents(string: base.absoluteString + path)!
        if !params.isEmpty { comps.queryItems = params }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GranolaError.http(0, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw GranolaError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GranolaError.decode("\(error) — \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
    }
}
