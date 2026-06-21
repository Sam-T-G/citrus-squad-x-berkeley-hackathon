# Citrus Squad × Berkeley AI Hackathon 2026

Citrus Squad's entry for the Berkeley AI Hackathon 2026 at the MLK Jr. Building, UC Berkeley. The hack window ran 24 hours, from Saturday June 20 at 11:00 AM to Sunday June 21 at 11:00 AM.

Citrus Squad is a haptic navigation belt for blind and low-vision wearers. A chest-mounted iPhone reads compass heading and Google Maps turn cues, watches for obstacles with LiDAR, names what is in the path with on-device computer vision, and answers spoken questions through a voice agent. It taps four servos on a belt to point the wearer which way to turn or move. The phone is the brain; an ESP32 drives the belt. Continuous guidance rides on the belt so the ears stay free for the street, and voice is there when the wearer asks for it.

## What the phone does

The app runs a 10 Hz decide loop that turns every sensor into one belt cue, with safety winning over direction on every heartbeat. Four tiers feed a single arbiter, highest priority first:

- **Person and object in path** (built). On-device YOLOv8n through CoreML on the live ARKit camera frame, fused with the LiDAR depth at the box. Recognizes 21 pedestrian-relevant classes (person, bicycle, car, bench, fixtures like poles and meters, and more). Highest-priority cue.
- **LiDAR obstacle avoidance** (built). Three-band depth sampling decides clear, steer, or stop as a pure function of the geometry. No model, no network, instant.
- **Early warning** (built). A looming-object check fires a soft front tap before the LiDAR band returns, so a centered approach is felt early.
- **Navigation turn** (built). GPS and compass plus a Google Maps route map to four-quadrant turn cues. There is a live-GPS walk mode and a replay mode that needs no GPS or Wi-Fi.

The arbiter sends one LC2 packet every 100 ms over UDP. A hazard preempts a turn cue on the same heartbeat. The belt goes quiet on its own after 500 ms of silence.

## Voice (built, runs on the phone)

A Deepgram Voice Agent is the hands-free, eyes-free interface. The wearer taps to talk (or uses a hardware volume button), speaks, and the agent calls a device function and speaks the answer back. The setup:

- **Listen**: Deepgram `nova-3`.
- **Think**: Deepgram-managed `gpt-4o-mini`. Claude was the plan, but the managed Claude model is not provisioned on our Deepgram account (`claude-4-5-haiku-latest` comes back `model not available`), so the think tier runs on the managed OpenAI model, which needs no key of ours.
- **Speak**: Deepgram `aura-2`.

Functions wired to real device actions: set a destination (a spoken place name becomes a real route and a live walk), where am I, route status, next turn, trip summary, check the path, describe surroundings, read a sign, find an entrance, recalibrate, connect or disconnect the belt, and stop. Each function returns one short spoken sentence, and the agent speaks it word for word so a sensor-grounded line stays intact.

## Claude reasoning (built, off the safety path)

Claude does the judgment and vision work that earns its latency, never the obstacle reflex. It runs through the Anthropic Messages API with our own key:

- **Describe surroundings**: a Haiku draft over a structured scene snapshot, a Sonnet verify pass, and a local `SpokenLineGuard` that refuses a "clear path" line the LiDAR contradicts. Any miss falls back to the sensor-grounded sentence.
- **Read a sign and find an entrance**: one frame from the running ARSession to Claude vision under a tight timeout, with an honest spoken reason on a blank read.

Every Claude call can fail or time out without touching the belt. The LiDAR-to-haptic reflex is deterministic, local, and never waits on a network call. That is the one rule the whole design protects.

## The belt

`firmware/citrus_squad_belt/` is the ESP32 sketch. It parses the 4-byte LC2 packet, drives four servos (Far Left, Left, Right, Far Right), renders each event as a tap pattern (single, triple, sweep, sustained), tracks the sequence byte to spot dropped packets, and falls back to idle after 500 ms of silence. A laptop bridge under `server/` is the fallback if the ESP32 is not ready: it relays the phone's LC2 packets to an Arduino over USB serial, with an internet relay for when the phone and laptop cannot share Wi-Fi.

## Laptop computer-vision server (prototyping and fallback)

The on-device CoreML path above is the primary one. The Python pipeline in `cv/` is the prototyping ground and a Wi-Fi fallback: YOLOv8n inference fused with LiDAR depth (`cv/pipeline.py`), a FastAPI WebSocket that takes frame pairs from the phone (`cv/ingest.py`), and a webcam smoke test that needs no phone (`cv/webcam_test.py`). The iOS class filter mirrors `cv/detection.py`, so the phone and the server recognize the same 21 classes. 17 unit tests cover the depth-fusion math and the wire parser.

```sh
pip3 install -r requirements.txt
python3 server.py                 # CV detections out to haptic clients
python3 -m cv.webcam_test         # local smoke test, no phone needed
python3 -m pytest tests/ -v       # 17 tests
```

## Run the app

Every teammate runs their own instance on their own phone and Mac. See [RUNNING.md](RUNNING.md) for the ten-minute setup. The short version:

```sh
./ios/setup.sh        # installs XcodeGen, sets up local signing, generates the project
open ios/CitrusSquad.xcodeproj
# set your team + bundle id in ios/Local.xcconfig, pick your iPhone, press Cmd-R
```

A baseline demo needs only a phone: the replay route and simulate mode run with no belt, no Wi-Fi, and no API keys. The ESP32 belt, live Google Maps, voice, and Claude reasoning are add-ons. Voice needs a Deepgram key in `ios/Local.xcconfig`, and the Claude tier needs an Anthropic key. Both degrade to "unavailable" when their key is missing, and the rest of the app keeps running.

## System architecture

```
iPhone (Citrus Squad app)                         ESP32 (belt)
  Maps directions + compass  -> turn cue            receives one LC2 packet
  LiDAR scene depth          -> obstacle cue        per 100 ms heartbeat and
  YOLOv8n CoreML on-device   -> object ID + cue     renders it as a servo
  Deepgram voice + Claude    -> spoken answers      tap pattern
        |
        v  arbitrate (safety > direction), 10 Hz
  one LC2 packet / 100 ms  --UDP over Wi-Fi-->  4 servos: Far L, L, R, Far R
```

## What is not proven yet

These are the demo-day risks, stated plainly:

- **Belt hardware round-trip.** The firmware and the laptop bridge are written, but the phone to ESP32 to servo path has not been run on real hardware.
- **Thermal soak.** Continuous LiDAR, GPS, camera, and screen are instrumented for a soak that has not been run on the phone.
- **Claude on device.** The reasoning and vision tiers compile and are wired, but have not been exercised on the phone against a live key.
- **Blind co-design.** The wearer in testing is a teammate. Co-design with blind users is noted in [`ios/BLIND-NAVIGATION-NORTH-STAR.md`](ios/BLIND-NAVIGATION-NORTH-STAR.md) and is future work.

## Team

- **Sam** — iOS app, sensing, LiDAR, arbitration, navigation.
- **Cole** — computer vision and the Python pipeline.
- **Josh** — audio.
- **Angelo** — belt firmware and the ESP32.

## Key docs

- [STATUS.md](STATUS.md) — current state and session log. Read first.
- [RUNNING.md](RUNNING.md) — setup and run.
- [IOS-APP-PLAN.md](IOS-APP-PLAN.md) — phone-side architecture.
- [ios/VOICE-AI-PIPELINE.md](ios/VOICE-AI-PIPELINE.md) — how a spoken request becomes a spoken answer.
- `docs/11` phone-app build contract, `docs/12` perception and safety, `docs/14` voice and reasoning.
- [ios/BLIND-NAVIGATION-NORTH-STAR.md](ios/BLIND-NAVIGATION-NORTH-STAR.md) — the ethics and the critical review.

## License

MIT.
