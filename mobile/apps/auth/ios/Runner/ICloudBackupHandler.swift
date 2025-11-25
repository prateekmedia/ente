import Flutter
import UIKit

/// Handler for iCloud backup operations using NSFileCoordinator for safe file access
class ICloudBackupHandler: NSObject, FlutterPlugin {
    private let fileCoordinator = NSFileCoordinator()

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "io.ente.auth/icloud_backup",
            binaryMessenger: registrar.messenger()
        )
        let instance = ICloudBackupHandler()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isICloudAvailable":
            isICloudAvailable(result: result)
        case "getICloudDocumentsPath":
            getICloudDocumentsPath(result: result)
        case "writeFile":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String,
                  let content = args["content"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENTS",
                                    message: "Missing path or content",
                                    details: nil))
                return
            }
            writeFile(path: path, content: content, result: result)
        case "readFile":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENTS",
                                    message: "Missing path",
                                    details: nil))
                return
            }
            readFile(path: path, result: result)
        case "deleteFile":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENTS",
                                    message: "Missing path",
                                    details: nil))
                return
            }
            deleteFile(path: path, result: result)
        case "listFiles":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENTS",
                                    message: "Missing path",
                                    details: nil))
                return
            }
            listFiles(path: path, result: result)
        case "createDirectory":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENTS",
                                    message: "Missing path",
                                    details: nil))
                return
            }
            createDirectory(path: path, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func isICloudAvailable(result: @escaping FlutterResult) {
        let available = FileManager.default.ubiquityIdentityToken != nil
        result(available)
    }

    private func getICloudDocumentsPath(result: @escaping FlutterResult) {
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            result(nil)
            return
        }
        let documentsURL = containerURL.appendingPathComponent("Documents")

        // Create Documents folder if it doesn't exist
        if !FileManager.default.fileExists(atPath: documentsURL.path) {
            do {
                try FileManager.default.createDirectory(at: documentsURL,
                                                        withIntermediateDirectories: true,
                                                        attributes: nil)
            } catch {
                result(FlutterError(code: "CREATE_DIR_ERROR",
                                    message: "Failed to create Documents folder: \(error.localizedDescription)",
                                    details: nil))
                return
            }
        }

        result(documentsURL.path)
    }

    private func writeFile(path: String, content: String, result: @escaping FlutterResult) {
        let url = URL(fileURLWithPath: path)

        // Ensure parent directory exists
        let parentDir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            do {
                try FileManager.default.createDirectory(at: parentDir,
                                                        withIntermediateDirectories: true,
                                                        attributes: nil)
            } catch {
                result(FlutterError(code: "CREATE_DIR_ERROR",
                                    message: "Failed to create directory: \(error.localizedDescription)",
                                    details: nil))
                return
            }
        }

        var coordinationError: NSError?
        fileCoordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writingURL in
            do {
                try content.write(to: writingURL, atomically: true, encoding: .utf8)
                result(true)
            } catch {
                result(FlutterError(code: "WRITE_ERROR",
                                    message: "Failed to write file: \(error.localizedDescription)",
                                    details: nil))
            }
        }

        if let error = coordinationError {
            result(FlutterError(code: "COORDINATION_ERROR",
                                message: "File coordination failed: \(error.localizedDescription)",
                                details: nil))
        }
    }

    private func readFile(path: String, result: @escaping FlutterResult) {
        let url = URL(fileURLWithPath: path)

        var coordinationError: NSError?
        fileCoordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readingURL in
            do {
                let content = try String(contentsOf: readingURL, encoding: .utf8)
                result(content)
            } catch {
                result(FlutterError(code: "READ_ERROR",
                                    message: "Failed to read file: \(error.localizedDescription)",
                                    details: nil))
            }
        }

        if let error = coordinationError {
            result(FlutterError(code: "COORDINATION_ERROR",
                                message: "File coordination failed: \(error.localizedDescription)",
                                details: nil))
        }
    }

    private func deleteFile(path: String, result: @escaping FlutterResult) {
        let url = URL(fileURLWithPath: path)

        var coordinationError: NSError?
        fileCoordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { deletingURL in
            do {
                try FileManager.default.removeItem(at: deletingURL)
                result(true)
            } catch {
                result(FlutterError(code: "DELETE_ERROR",
                                    message: "Failed to delete file: \(error.localizedDescription)",
                                    details: nil))
            }
        }

        if let error = coordinationError {
            result(FlutterError(code: "COORDINATION_ERROR",
                                message: "File coordination failed: \(error.localizedDescription)",
                                details: nil))
        }
    }

    private func listFiles(path: String, result: @escaping FlutterResult) {
        let url = URL(fileURLWithPath: path)

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            var files: [[String: Any]] = []
            for fileURL in contents {
                let resourceValues = try fileURL.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])

                // Skip directories
                if resourceValues.isRegularFile != true {
                    continue
                }

                let creationDate = resourceValues.creationDate ?? Date()
                files.append([
                    "name": fileURL.lastPathComponent,
                    "path": fileURL.path,
                    "creationDate": creationDate.timeIntervalSince1970
                ])
            }

            result(files)
        } catch {
            result(FlutterError(code: "LIST_ERROR",
                                message: "Failed to list files: \(error.localizedDescription)",
                                details: nil))
        }
    }

    private func createDirectory(path: String, result: @escaping FlutterResult) {
        let url = URL(fileURLWithPath: path)

        do {
            try FileManager.default.createDirectory(at: url,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
            result(true)
        } catch {
            result(FlutterError(code: "CREATE_DIR_ERROR",
                                message: "Failed to create directory: \(error.localizedDescription)",
                                details: nil))
        }
    }
}
