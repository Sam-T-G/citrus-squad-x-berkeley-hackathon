# Running CitrusSquad on your own phone and Mac

Every teammate runs their own instance: their Mac builds the app, their iPhone runs it, and (optionally) their own ESP32 belt receives the cues. Nothing here is tied to one person's machine. This takes about ten minutes the first time.

## What you need

- A **Mac with Xcode 16 or newer**.
- An **iPhone running iOS 17+**. A real device is required: the sensors, the radio, and the LiDAR depth all need real hardware (the simulator can't fake them). LiDAR depth needs a Pro model (14 Pro or newer); on a non-Pro iPhone everything else still works and the depth card just reports "not supported."
- An **Apple ID**. A free one is fine for installing on your own device.
- Optional: an **ESP32 + the belt hardware** if you're working on the physical side. You do not need it to run and develop the app.

## One-time setup

1. **Clone the repo** and open a terminal in it.
2. **Run the setup script:**
   ```sh
   ./ios/setup.sh
   ```
   It installs XcodeGen if you don't have it, creates your personal `ios/Local.xcconfig`, and generates the Xcode project.
3. **Set your signing** in `ios/Local.xcconfig` (it was just created from the template):
   ```
   DEVELOPMENT_TEAM = YOURTEAMID
   APP_BUNDLE_ID = com.yourname.CitrusSquad
   ```
   - `DEVELOPMENT_TEAM` is your 10-character Apple Team ID (Xcode → Settings → Accounts → your Apple ID shows it). You can also leave it blank and pick your team in Xcode's Signing tab.
   - `APP_BUNDLE_ID` should be unique to you (use your name) so it never clashes with a teammate's signing.

   This file is gitignored, so your settings are yours alone and never get committed.
4. **Re-generate** so your settings take effect, then open the project:
   ```sh
   ./ios/setup.sh
   open ios/CitrusSquad.xcodeproj
   ```

## Run it

1. Plug in your iPhone, unlock it, and trust the Mac if prompted.
2. In Xcode, pick your iPhone as the run destination (top toolbar) and press **⌘R**.
3. First launch only:
   - On the phone, **Settings → Privacy & Security → Developer Mode → On** (it'll ask you to restart).
   - If the app won't open, **Settings → General → VPN & Device Management → trust your developer certificate**.
   - Grant the location, motion, and camera prompts.

Prefer the terminal? `./ios/run-on-device.sh` builds, installs, and launches on the first connected iPhone. Xcode's ⌘R does the same with a nicer signing UI.

## Try it with no hardware and no API key

You can exercise the whole navigation-to-cue path with just your phone:

1. Open the **Diagnostics** tab → **Navigation** card.
2. Tap **Load demo route**, switch the mode to **Simulate**, tap **Run sim**.
3. Watch **Resolved cue** change as the virtual walk hits each turn. Flip **Speak cues** to hear them.

The **Operate** tab is the clean demo screen: one big cue display plus connect / calibrate / run.

## Optional: connect a belt (ESP32)

1. Flash the firmware in [`firmware/citrus_squad_belt`](firmware/citrus_squad_belt) following [`firmware/README.md`](firmware/README.md).
2. If several people run belts in the same room, give yours a unique Wi-Fi name: change `AP_SSID` in `firmware/citrus_squad_belt/config.h` before flashing (for example `CitrusSquad-BELT-sam`).
3. In the app's **Belt link** card, set the host to the belt's address (`192.168.4.1` in the default access-point mode) and tap **Start link**, then **Send test cue**.

## Optional: live Google Maps

The demo and simulator need no key. For live routing, each person uses their **own** Directions API key:

1. Create and restrict a key as described in [`ios/README.md`](ios/README.md) under "Cost control."
2. Restrict it to **your** bundle id (`com.yourname.CitrusSquad`), set a **daily quota** and a **billing budget alert**.
3. Paste it into the app: **Diagnostics → Navigation → Live Google Maps → Directions API key**. It's stored on your device only.

Don't share one key across teammates: the bundle-id restriction is per person, and shared keys make spend impossible to attribute.

## Troubleshooting

- **"Signing requires a development team."** Set `DEVELOPMENT_TEAM` in `ios/Local.xcconfig` (then re-run `./ios/setup.sh`), or pick your team in Xcode → target → Signing & Capabilities.
- **"Failed to register bundle identifier."** Your `APP_BUNDLE_ID` is taken under another team. Change it to something unique to you.
- **The phone shows as unavailable / the app won't launch from the CLI.** Unlock the phone; a locked device refuses installs and launches.
- **`xcodegen: command not found`.** Run `brew install xcodegen` (install Homebrew first from https://brew.sh).
- **Depth card says "not supported."** Your iPhone has no LiDAR; everything else still runs.
