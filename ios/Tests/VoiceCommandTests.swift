import Testing
@testable import CitrusSquad

/// The function-name to command mapping is pure, so it is the part worth testing. The socket and
/// audio are verified by hand on the device.
struct VoiceCommandTests {
    @Test func mapsKnownFunctionsToCommands() {
        #expect(VoiceCommand(functionName: "route_status", arguments: [:]) == .routeStatus)
        #expect(VoiceCommand(functionName: "describe_surroundings", arguments: [:]) == .describeSurroundings)
        #expect(VoiceCommand(functionName: "recalibrate", arguments: [:]) == .recalibrate)
        #expect(VoiceCommand(functionName: "stop", arguments: [:]) == .stop)
    }

    @Test func extractsTheDestinationArgument() {
        #expect(VoiceCommand(functionName: "set_destination", arguments: ["place": "the library"])
                == .setDestination("the library"))
    }

    @Test func missingPlaceArgumentIsEmpty() {
        #expect(VoiceCommand(functionName: "set_destination", arguments: [:]) == .setDestination(""))
    }

    @Test func unknownFunctionBecomesUnavailable() {
        #expect(VoiceCommand(functionName: "read_text", arguments: [:]) == .unavailable("read_text"))
    }

    @Test func everyDeclaredFunctionRoundTrips() {
        // A name we declare to Deepgram must never map to .unavailable, or the agent would call a
        // function we then refuse.
        for function in VoiceFunction.allCases {
            let command = VoiceCommand(functionName: function.name, arguments: ["place": "x"])
            #expect(command != .unavailable(function.name))
        }
    }
}
