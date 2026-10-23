import Foundation
import os

// What the host hands the widget, and where. Both targets compile this one file.
enum Spike {
    static let group = "6R988MUU27.dev.orangedrink.widgetspike"
    static let kind = "SpikeLevel"
    static let subsystem = "dev.orangedrink.widgetspike"
}

struct Level: Codable {
    let sequence: Int
    let percent: Int
    let writtenAt: Date
}

enum ContainerError: Error, CustomStringConvertible {
    case noContainer(String)

    var description: String {
        switch self {
        case .noContainer(let group): "no group container for \(group)"
        }
    }
}

// The one file the host writes and the widget reads.
func levelFile() throws -> URL {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Spike.group) else {
        throw ContainerError.noContainer(Spike.group)
    }
    return container.appending(path: "level.json")
}
