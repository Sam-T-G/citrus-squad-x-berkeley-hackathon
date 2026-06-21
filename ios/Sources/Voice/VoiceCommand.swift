import Foundation

/// A request the wearer made by voice, normalized from a Deepgram function call into something the
/// app can act on. Pure and `Equatable`, so the mapping is unit-tested without a socket.
enum VoiceCommand: Sendable, Equatable {
    case setDestination(String)
    case routeStatus
    case whereAmI
    case describeSurroundings
    case recalibrate
    case connectBelt
    case disconnectBelt
    case stop
    /// A function the agent named that we cannot serve right now. The camera tools live here
    /// because the rear camera is exclusive with the ARKit LiDAR that runs the safety reflex
    /// (see `CameraService`), so they stay off while the belt is guiding.
    case unavailable(String)

    /// Map a Deepgram function name and its decoded string arguments to a command. An unknown name
    /// becomes `.unavailable`, so the agent always gets a clean spoken answer instead of an error.
    init(functionName: String, arguments: [String: String]) {
        switch functionName {
        case VoiceFunction.setDestination.name:
            self = .setDestination(arguments["place"] ?? "")
        case VoiceFunction.routeStatus.name:
            self = .routeStatus
        case VoiceFunction.whereAmI.name:
            self = .whereAmI
        case VoiceFunction.describeSurroundings.name:
            self = .describeSurroundings
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
    case whereAmI
    case describeSurroundings
    case recalibrate
    case connectBelt
    case disconnectBelt
    case stop

    var name: String {
        switch self {
        case .setDestination: return "set_destination"
        case .routeStatus: return "route_status"
        case .whereAmI: return "where_am_i"
        case .describeSurroundings: return "describe_surroundings"
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
        case .whereAmI: return "Report the wearer's current location as a nearby place or address."
        case .describeSurroundings: return "Describe what is ahead, prioritized for a walker."
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
