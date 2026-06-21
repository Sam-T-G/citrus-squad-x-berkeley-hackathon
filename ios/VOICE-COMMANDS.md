# Voice Commands

What the wearer can say, what it does, and what they hear back. The voice layer is a Deepgram Voice
Agent backed by Claude: the wearer speaks naturally and the agent decides which function to call, so
the phrasings below are examples, not rigid commands. Anything the agent cannot serve comes back as a
calm spoken "I cannot do that yet" rather than an error.

Source of truth: `Sources/Voice/VoiceCommand.swift` declares the functions, `AppModel.handleVoice`
runs them and writes the spoken reply. This file is the human-readable index of that. It pairs with
[`../docs/14-voice-and-reasoning-plan.md`](../docs/14-voice-and-reasoning-plan.md), which is the design.

## How to talk to it

- **Talk button** on the Demo screen: tap it to start listening, tap again to stop. The button shows
  the live state (Talk, Listening, Thinking, Speaking).
- **Volume button**: press and hold either hardware volume button to start a turn without looking at
  the screen. A hold fires it; a single tap is ignored. The system volume is parked back to the middle
  so nothing actually changes.

When it is listening you hear a ready chime; when your turn ends it plays a short processing tone, then
speaks the answer.

## The commands

| Say something like | What it does | You hear |
|---|---|---|
| "Take me to the library", "Navigate to 5th and Main" | Starts walking navigation to a place you name. Resolves known presets first, then a free map search. | "Heading to the library." Or, if it is unsure, "I found a few. Did you mean A, or B?" |
| "What's my route status?" | Distance to the next turn and how many turns remain. | "About 40 meters to the next turn. 2 turns left." |
| "What's my next turn?", "Which way do I turn?" | A heads-up on the upcoming turn: direction and how far ahead, in feet. | "You'll make a left turn in about 100 feet." |
| "How far to my destination?", "How much longer?" | Distance left to the destination and a rough walking time, in feet or miles. | "You're about a quarter mile from your destination, around 5 minutes away." |
| "Where am I?" | Your current location as a nearby place or address. | "You are near Sproul Plaza, in Berkeley." |
| "What's around me?", "What's ahead?" | Describes what is in front, prioritized for a walker. | "The path ahead looks clear." Or "Caution, a person about 3 meters ahead." |
| "Is the way clear?", "Is something in front of me?", "How do I get around this?" | Checks whether a person or object is in your path and which side is open, using the LiDAR-confirmed clear side, then tells you to step left, step right, or stop. | "Step left, a bench is just ahead on your right." Or "Stop. A wall is close and both sides are tight. Hold still, then turn slowly." |
| "Recalibrate", "Reset my heading" | Recaptures the forward-facing heading reference. | "Recalibrated. Face forward and start walking." |
| "Connect the belt" | Connects to the haptic belt so it can tap cues. | "Connecting to the belt." Or "The belt is already connected." |
| "Disconnect the belt" | Disconnects from the belt. | "Disconnected from the belt." Or "The belt is not connected." |
| "Stop" | Stops navigation and guidance. | "Stopped." |

## Function names (for the agent and for debugging)

Each row above maps to one declared function. The names show up in the Deepgram logs and in
`VoiceFunction`:

| Function | Spoken intent it serves |
|---|---|
| `set_destination` | Start navigation to a named place. Takes a `place` argument. |
| `route_status` | Distance to the next turn plus turns remaining. |
| `next_turn` | The next turn's direction and distance ahead, in feet. |
| `trip_summary` | Distance and walking time to the destination. |
| `where_am_i` | Current location as a place or address. |
| `describe_surroundings` | What is ahead, walker-first. |
| `check_path` | Is the path blocked, and which side is open. |
| `recalibrate` | Recapture the heading reference. |
| `connect_belt` | Connect the haptic belt. |
| `disconnect_belt` | Disconnect the haptic belt. |
| `stop` | Stop navigation and guidance. |

## What it will not do yet

- **Camera reading and entrance-finding** (`read_text`, `locate_entrance`) are intentionally absent.
  The rear camera is exclusive with the ARKit LiDAR that runs the collision-avoidance reflex, so those
  stay off while the belt is guiding rather than steal the camera from the safety layer.
- Any other function the agent invents resolves to **unavailable**, and the wearer hears "I cannot do
  that yet" instead of a failure.

## Notes for the demo

- `check_path` needs the camera running. If it is off, the reply is "Turn the camera on so I can check
  for obstacles," so bring the camera up before relying on it.
- `set_destination` needs a GPS fix to actually guide. If it resolves a place but has no fix yet, it
  says so rather than guiding you blind.
- The agent's safety reply for `check_path` always carries the open side from LiDAR, so it never sends
  the wearer toward a blocked direction.
