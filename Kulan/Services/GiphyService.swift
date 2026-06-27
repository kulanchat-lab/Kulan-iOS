import Foundation
import FirebaseFunctions

// Custom (lightweight) Giphy client — calls Giphy's REST API directly. The API key is fetched
// once from the `giphyKey` Cloud Function (kept out of this public repo), then cached.
@MainActor
final class GiphyService {
    static let shared = GiphyService()
    private init() {}

    struct Gif: Identifiable, Hashable {
        let id: String
        let url: String       // animated GIF url (fixed_width)
        let width: Double
        let height: Double
    }

    private var apiKey: String?

    private func key() async -> String? {
        if let apiKey { return apiKey }
        let res = try? await Functions.functions(region: "me-central1").httpsCallable("giphyKey").call()
        apiKey = (res?.data as? [String: Any])?["key"] as? String
        return apiKey
    }

    func search(_ q: String) async -> [Gif] {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        return await fetch(path: trimmed.isEmpty ? "trending" : "search", query: trimmed.isEmpty ? nil : trimmed)
    }

    private func fetch(path: String, query: String?) async -> [Gif] {
        guard let key = await key(), var c = URLComponents(string: "https://api.giphy.com/v1/gifs/\(path)") else { return [] }
        var items = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "rating", value: "pg-13"),
        ]
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        c.queryItems = items
        guard let url = c.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { g in
            guard let id = g["id"] as? String,
                  let images = g["images"] as? [String: Any],
                  let fixed = images["fixed_width"] as? [String: Any],
                  let gurl = fixed["url"] as? String else { return nil }
            let w = Double(fixed["width"] as? String ?? "200") ?? 200
            let h = Double(fixed["height"] as? String ?? "200") ?? 200
            return Gif(id: id, url: gurl, width: w, height: h)
        }
    }
}
