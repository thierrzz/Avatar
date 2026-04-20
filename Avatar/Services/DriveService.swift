import Foundation

/// Lightweight Google Drive REST API wrapper using URLSession.
/// Only implements the subset needed for workspace sync: folder CRUD,
/// file upload/download, and change tracking.
actor DriveService {

    private let authService: GoogleAuthService
    private let session = URLSession.shared
    private let baseURL = "https://www.googleapis.com/drive/v3"
    private let uploadURL = "https://www.googleapis.com/upload/drive/v3"

    init(authService: GoogleAuthService) {
        self.authService = authService
    }

    // MARK: - Folder operations

    /// Creates a folder on Google Drive. Returns the folder ID.
    func createFolder(name: String, parentID: String? = nil) async throws -> String {
        var metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder"
        ]
        if let parentID {
            metadata["parents"] = [parentID]
        }

        let data = try JSONSerialization.data(withJSONObject: metadata)
        var request = try await authorizedRequest(url: "\(baseURL)/files?fields=id,name", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let response: DriveFile = try await execute(request)
        return response.id
    }

    /// Lists files in a folder. Returns file metadata.
    func listFiles(inFolder folderID: String, mimeType: String? = nil) async throws -> [DriveFile] {
        var query = "'\(folderID)' in parents and trashed = false"
        if let mimeType {
            query += " and mimeType = '\(mimeType)'"
        }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = "\(baseURL)/files?q=\(encoded)&fields=files(id,name,md5Checksum,modifiedTime,size)&pageSize=1000"
        let request = try await authorizedRequest(url: url)

        let response: DriveFileList = try await execute(request)
        return response.files
    }

    // MARK: - File operations

    /// Uploads file data to Google Drive. Returns the created file metadata.
    func uploadFile(
        name: String,
        data: Data,
        mimeType: String = "application/octet-stream",
        parentFolderID: String
    ) async throws -> DriveFile {
        // Use multipart upload for simplicity (supports files up to 5 MB inline,
        // larger files use resumable upload automatically)
        let metadata: [String: Any] = [
            "name": name,
            "parents": [parentFolderID]
        ]
        return try await multipartUpload(metadata: metadata, data: data, mimeType: mimeType)
    }

    /// Updates an existing file's content on Google Drive.
    func updateFile(fileID: String, data: Data, mimeType: String = "application/octet-stream") async throws -> DriveFile {
        let url = "\(uploadURL)/files/\(fileID)?uploadType=media&fields=id,name,md5Checksum,modifiedTime,size"
        var request = try await authorizedRequest(url: url, method: "PATCH")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return try await execute(request)
    }

    /// Downloads a file's content from Google Drive.
    func downloadFile(fileID: String) async throws -> Data {
        let url = "\(baseURL)/files/\(fileID)?alt=media"
        let request = try await authorizedRequest(url: url)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DriveError.httpError(code)
        }
        return data
    }

    /// Deletes a file from Google Drive.
    func deleteFile(fileID: String) async throws {
        let url = "\(baseURL)/files/\(fileID)"
        let request = try await authorizedRequest(url: url, method: "DELETE")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300 ~= http.statusCode || http.statusCode == 404) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DriveError.httpError(code)
        }
    }

    // MARK: - Change tracking

    /// Gets a start page token for change tracking.
    func getStartPageToken() async throws -> String {
        let url = "\(baseURL)/changes/startPageToken"
        let request = try await authorizedRequest(url: url)
        let response: StartPageTokenResponse = try await execute(request)
        return response.startPageToken
    }

    /// Lists changes since the given page token. Returns changes and the next token.
    func listChanges(pageToken: String) async throws -> (changes: [DriveChange], nextToken: String?) {
        let url = "\(baseURL)/changes?pageToken=\(pageToken)&fields=changes(fileId,file(id,name,md5Checksum,modifiedTime,trashed)),newStartPageToken,nextPageToken&pageSize=100"
        let request = try await authorizedRequest(url: url)
        let response: DriveChangeList = try await execute(request)
        return (response.changes, response.newStartPageToken ?? response.nextPageToken)
    }

    // MARK: - Sharing

    /// Shares a file/folder with a user by email. Asks Drive to send the
    /// notification email with an optional custom message (used to embed
    /// the Avatar download link and `avatar://join` deep link).
    func shareWithUser(
        fileID: String,
        email: String,
        role: String = "writer",
        emailMessage: String? = nil
    ) async throws {
        var components = URLComponents(string: "\(baseURL)/files/\(fileID)/permissions")!
        var query: [URLQueryItem] = [URLQueryItem(name: "sendNotificationEmail", value: "true")]
        if let emailMessage {
            query.append(URLQueryItem(name: "emailMessage", value: emailMessage))
        }
        components.queryItems = query

        let body: [String: Any] = [
            "type": "user",
            "role": role,
            "emailAddress": email
        ]
        var request = try await authorizedRequest(url: components.url!.absoluteString, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DriveError.httpError(code)
        }
    }

    // MARK: - Folder browsing

    /// Lists folders inside a parent folder (or root if parentID is "root").
    /// Used by the Drive folder picker when creating a workspace.
    func listFolders(inParent parentID: String = "root") async throws -> [DriveFile] {
        let query = "'\(parentID)' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = "\(baseURL)/files?q=\(encoded)&fields=files(id,name)&orderBy=name&pageSize=100"
        let request = try await authorizedRequest(url: url)
        let response: DriveFileList = try await execute(request)
        return response.files
    }

    // MARK: - Move

    /// Moves a file/folder to a different parent on Drive.
    /// Pass `nil` for `newParentID` to move to "My Drive" root.
    func moveFile(fileID: String, to newParentID: String?) async throws {
        // 1. Fetch current parents
        let getURL = "\(baseURL)/files/\(fileID)?fields=parents"
        let getRequest = try await authorizedRequest(url: getURL)
        struct ParentsResponse: Decodable { let parents: [String]? }
        let current: ParentsResponse = try await execute(getRequest)
        let oldParents = (current.parents ?? []).joined(separator: ",")

        // 2. Determine new parent (root if nil)
        let newParent = newParentID ?? "root"

        // No-op if already in the same single-parent location
        if current.parents?.count == 1, current.parents?.first == newParent {
            return
        }

        // 3. PATCH with addParents/removeParents
        var components = URLComponents(string: "\(baseURL)/files/\(fileID)")!
        components.queryItems = [
            URLQueryItem(name: "addParents", value: newParent),
            URLQueryItem(name: "removeParents", value: oldParents),
            URLQueryItem(name: "fields", value: "id,parents")
        ]
        var request = try await authorizedRequest(url: components.url!.absoluteString, method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)
        struct MoveResponse: Decodable { let id: String; let parents: [String]? }
        let _: MoveResponse = try await execute(request)
    }

    // MARK: - Search

    /// Finds Avatar workspace folders (folders containing a workspace.json).
    func findWorkspaceFolders() async throws -> [DriveFile] {
        let query = "mimeType = 'application/vnd.google-apps.folder' and name contains 'Avatar Workspace' and trashed = false"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = "\(baseURL)/files?q=\(encoded)&fields=files(id,name,modifiedTime)&pageSize=50"
        let request = try await authorizedRequest(url: url)
        let response: DriveFileList = try await execute(request)
        return response.files
    }

    // MARK: - Helpers

    private func authorizedRequest(url: String, method: String = "GET") async throws -> URLRequest {
        let token = try await authService.validAccessToken()
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DriveError.httpError(code)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            // Google Drive returns dates with fractional seconds (e.g. "2026-04-18T10:30:45.123Z")
            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFrac.date(from: str) { return date }
            // Fallback without fractional seconds
            if let date = ISO8601DateFormatter().date(from: str) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(str)")
        }
        return try decoder.decode(T.self, from: data)
    }

    private func multipartUpload(metadata: [String: Any], data: Data, mimeType: String) async throws -> DriveFile {
        let boundary = UUID().uuidString
        let url = "\(uploadURL)/files?uploadType=multipart&fields=id,name,md5Checksum,modifiedTime,size"
        var request = try await authorizedRequest(url: url, method: "POST")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        return try await execute(request)
    }
}

// MARK: - API response models

struct DriveFile: Codable, Identifiable {
    let id: String
    let name: String
    var md5Checksum: String?
    var modifiedTime: Date?
    var size: String?
}

struct DriveFileList: Codable {
    let files: [DriveFile]
}

struct DriveChange: Codable {
    let fileId: String?
    let file: DriveFile?
}

struct DriveChangeList: Codable {
    let changes: [DriveChange]
    var newStartPageToken: String?
    var nextPageToken: String?
}

struct StartPageTokenResponse: Codable {
    let startPageToken: String
}

enum DriveError: LocalizedError {
    case httpError(Int)
    case notFound

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "Google Drive API error (HTTP \(code))."
        case .notFound: return "File not found on Google Drive."
        }
    }
}
