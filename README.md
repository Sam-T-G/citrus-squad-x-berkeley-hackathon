# Citrus Squad × Berkeley AI Hackathon 2026

Citrus Squad's entry for the **Berkeley AI Hackathon 2026** at the MLK Jr. Building, UC Berkeley. Hack window opens Saturday June 20 at 11:00 AM and runs 24 hours, closing Sunday June 21 at 11:00 AM. Judging and closing ceremony follow.

Project direction is fluid until the alignment meeting locks scope. Current frontrunner is **Citrus Squad**, a haptic navigation belt for blind and low-vision wearers. Subject to change in the first hour of the hack if the team picks a different idea.

## Run it yourself

Every teammate runs their own instance on their own phone and Mac. See **[RUNNING.md](RUNNING.md)** for the ten-minute setup. The short version:

```sh
./ios/setup.sh           # installs XcodeGen, creates your local signing, generates the project
open ios/CitrusSquad.xcodeproj
# set your team + bundle id in ios/Local.xcconfig, pick your iPhone, press Cmd-R
```

You can run the full app with just a phone (the Navigation card's demo route + simulate mode needs no belt and no API key). The ESP32 belt and live Google Maps are optional add-ons covered in RUNNING.md.

## Team

Sam, Cole, Josh, Angelo.

## License

MIT.
