import Foundation

/// A request the wearer made by voice, normalized from a Deepgram function call into something the
/// app can act on. Pure and `Equatable`, so the mapping is unit-tested without a socket.
enum VoiceCommand: Sendable, Equatable {
    case setDestination(String)
    case routeStatus
    case nextTurn
    case tripSummary
    case whereAmI
    case describeSurroundings
    case checkPath
    case readSign
    case recalibrate
    case connectBelt
    case disconnectBelt
    case stop
    /// A function the agent named that we cannot serve right now. `locate_entrance` still lives here;
    /// `read_sign` moved out, because the Claude vision read shares the one ARSession frame and never
    /// needs a second camera session away from the LiDAR reflex.
    case unavailable(String)

    /// Map a Deepgram function name and its decoded string arguments to a command. An unknown name
    /// becomes `.unavailable`, so the agent always gets a clean spoken answer instead of an error.
    init(functionName: String, arguments: [String: String]) {
        switch functionName {
        case VoiceFunction.setDestination.name:
            self = .setDestination(arguments["place"] ?? "")
        case VoiceFunction.routeStatus.name:
            self = .routeStatus
        case VoiceFunction.nextTurn.name:
            self = .nextTurn
        case VoiceFunction.tripSummary.name:
            self = .tripSummary
        case VoiceFunction.whereAmI.name:
            self = .whereAmI
        case VoiceFunction.describeSurroundings.name:
            self = .describeSurroundings
        case VoiceFunction.checkPath.name:
            self = .checkPath
        case VoiceFunction.readSign.name:
            self = .readSign
        case VoiceFunction.recalibrate.name:
            self = .recalibrate
        case VoiceFunction.connectBelt.name:
            self = .connectBelt
        case VoiceFunction.disconnectBelt.name:
            self = .disconnectBelt
        case VoiceFunction.stop.name:
            self = .stop
        default:
            self = .unavailable(functionName)
        }
    }
}

/// The functions we declare to the Deepgram Voice Agent. One list, so the name used to *declare* a
/// function and the name used to *dispatch* it can never drift apart. `read_text` and
/// `locate_entrance` are intentionally absent until the vision tier can run without stealing the
/// camera from the LiDAR safety reflex.
enum VoiceFunction: String, CaseIterable, Sendable {
    case setDestination
    case routeStatus
    case nextTurn
    case tripSummary
    case whereAmI
    case describeSurroundings
    case checkPath
    case readSign
    case recalibrate
    case connectBelt
    case disconnectBelt
    case stop

    var name: String {
        switch self {
        case .setDestination: return "set_destination"
        case .routeStatus: return "route_status"
        case .nextTurn: return "next_turn"
        case .tripSummary: return "trip_summary"
        case .whereAmI: return "where_am_i"
        case .describeSurroundings: return "describe_surroundings"
        case .checkPath: return "check_path"
        case .readSign: return "read_sign"
        case .recalibrate: return "recalibrate"
        case .connectBelt: return "connect_belt"
        case .disconnectBelt: return "disconnect_belt"
        case .stop: return "stop"
        }
    }

    var purpose: String {
        switch self {
        case .setDestination: return "Start walking navigation to a place the wearer names."
        case .routeStatus: return "Report distance to the next turn and how many turns remain."
        case .nextTurn: return "Give a heads-up about the next turn: which way it is and how far ahead in feet, like \"you'll make a left turn in about 100 feet.\" Use when the wearer asks what's coming up or which way to turn."
        case .tripSummary: return "Report how far the wearer still has to the destination and a rough walking time, in feet or miles."
        case .whereAmI: return "Report the wearer's current location as a nearby place or address."
        case .describeSurroundings: return "Describe what is ahead, prioritized for a walker."
        case .checkPath: return "Check whether a person or object is in the wearer's walking path and which side is open. The result already includes the safe direction (the LiDAR-confirmed open side) so you never send the wearer into a blocked side. Use it to warn of a likely collision and tell the wearer to step left, step right, or stop. Call it when the wearer asks if the way is clear, if something is in front of them, or how to get around an obstacle, and lean on it whenever a collision seems likely."
        case .readSign: return "Read a sign, label, number, or other printed text the wearer points the camera at, and say it back. Call it when the wearer asks you to read something, what a sign says, a store name, a bus number, a street name, or an address. It grabs one camera frame and reads it; it is informational only and never a navigation instruction."
        case .recalibrate: return "Recapture the forward-facing heading offset."
        case .connectBelt: return "Connect to the haptic belt so it can start tapping cues."
        case .disconnectBelt: return "Disconnect from the haptic belt."
        case .stop: return "Stop navigation and guidance now."
        }
    }

    /// The JSON spec Deepgram expects in the agent `think.functions` array. Built from this one
    /// list so a rename cannot desync the declaration from the dispatch.
    /// VERIFY ON DEVICE: confirm the exact key names against the current Voice Agent docs.
    var spec: [String: Any] {
        var parameters: [String: Any] = [
            "type": "object",
            "properties": [String: Any](),
            "required": [String](),
        ]
        if self == .setDestination {
            parameters = [
                "type": "object",
                "properties": ["place": ["type": "string", "description": "The place the wearer named."]],
                "required": ["place"],
            ]
        }
        // A function with no `endpoint` runs client-side: Deepgram sends a FunctionCallRequest and we
        // answer with a FunctionCallResponse. There is no `client_side` flag in the schema.
        return [
            "name": name,
            "description": purpose,
            "parameters": parameters,
        ]
    }

    static var allSpecs: [[String: Any]] { allCases.map(\.spec) }
}
