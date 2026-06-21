import Foundation

/// Commits a CV log CSV directly to the repo via the GitHub Contents API.
///
/// One PUT request per log session. Requires a GitHub personal access token
/// with `repo` write scope. The token is never logged or transmitted anywhere
/// other than the Authorization header of the upload request.
enum GitHubLogUploader {

    private static let owner  = "Sam-T-G"
    private static let repo   = "citrus-squad-x-berkeley-hackathon"
    private static let branch = "cole/computer-vision"
    private static let folder = "logs/cv"

    enum UploadError: Error, LocalizedError {
        case emptyToken
        case readFailed
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .emptyToken:       return "GitHub token not set"
            case .readFailed:       return "Could not read log file"
            case .httpError(let c): return "GitHub API returned \(c)"
            }
        }
    }

    /// Upload `fileURL` to `logs/cv/<filename>` on `cole/computer-vision`.
    /// Returns the HTML URL of the committed file on success.
    static func upload(fileURL: URL, token: String) async throws -> String {
        guard !token.isEmpty else { throw UploadError.emptyToken }

        guard let data = try? Data(contentsOf: fileURL) else { throw UploadError.readFailed }
        let encoded = data.base64EncodedString()
        let filename = fileURL.lastPathComponent

        let apiURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/\(folder)/\(filename)")!
        var request = URLRequest(url: apiURL)
        request.httpMethod = "PUT"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let body: [String: String] = [
            "message": "Add CV log \(filename)",
            "content": encoded,
            "branch": branch,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 || status == 200 else { throw UploadError.httpError(status) }

        // Pull the HTML URL out of the response so the caller can surface it.
        let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        let htmlURL = (json?["content"] as? [String: Any])?["html_url"] as? String
        return htmlURL ?? "https://github.com/\(owner)/\(repo)/blob/\(branch)/\(folder)/\(filename)"
    }
}
