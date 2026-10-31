import Foundation

struct PortFavorite: Identifiable, Codable, Equatable {
    var id: String { "\(transport):\(port)" }
    let port: Int
    let transport: String
    var name: String
    var title: String { name.isEmpty ? "\(transport) · \(port)" : name }
    var isValid: Bool { (1...65535).contains(port) && ["TCP", "UDP"].contains(transport) }
}
