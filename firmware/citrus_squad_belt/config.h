// Citrus Squad belt firmware configuration.
//
// Edit this file to match how the phone and the belt find each other on Wi-Fi.
// Everything the rest of the firmware needs is here.

#pragma once

// ---------------------------------------------------------------------------
// Network mode
//
// AP_MODE = 1  -> the ESP32 hosts its own Wi-Fi network. The phone joins it.
//                The ESP32 is always at 192.168.4.1. No router, no venue Wi-Fi.
//                This is the bulletproof demo mode and matches the app default.
//                Cost: the phone has no internet while joined (no live Maps).
//
// AP_MODE = 0  -> the ESP32 joins an existing Wi-Fi network (router or phone
//                hotspot). Set STA_SSID and STA_PASS below. The ESP32 gets an
//                IP from that network; read it off the Serial monitor at boot
//                and type it into the app's host field. Keeps phone internet.
// ---------------------------------------------------------------------------
#define AP_MODE 1

// Access-point mode settings (used when AP_MODE == 1)
#define AP_SSID "CitrusSquad-BELT"
#define AP_PASS "citrussquad"   // 8+ chars; "" for an open network

// Station mode settings (used when AP_MODE == 0)
#define STA_SSID "your-network"
#define STA_PASS "your-password"

// UDP port the belt listens on. Must match the app (default 9999).
#define LC2_PORT 9999

// ---------------------------------------------------------------------------
// Servo wiring. Pins from docs/02-hardware.md. Signal lines only; servo power
// comes from the 5 V rail, not the ESP32.
// ---------------------------------------------------------------------------
// Four motors around the torso: front (forward), left (rotate left), right (rotate right),
// back (proximity). Order matches the LC2 mask bits 0..3.
#define PIN_FRONT 25
#define PIN_LEFT  26
#define PIN_RIGHT 32
#define PIN_BACK  33
#define PIN_STATUS_LED 18

// Servo travel. NEUTRAL is the resting angle, TAP is the fully-extended tap.
#define SERVO_NEUTRAL_DEG 0
#define SERVO_TAP_DEG     30

// Pattern timing in milliseconds.
#define TAP_DOWN_MS 80   // time at the tapped position
#define TAP_UP_MS   80    // time back at neutral between taps in a train
#define SWEEP_STEP_MS 140 // dwell per servo in the arrived sweep

// Link health. If no packet arrives for this long, go quiet. Matches docs/03.
#define SILENCE_TIMEOUT_MS 500
