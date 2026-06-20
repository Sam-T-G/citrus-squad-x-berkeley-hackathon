// Citrus Squad belt firmware (ESP32)
//
// The receiving half of the link. The phone sends 4-byte LC2 packets over UDP at 10 Hz;
// this firmware drives the four tap servos to match. The wire format is docs/03-protocol.md:
//
//   byte 0  event     (0x00 idle, 0x20 turn-slight, 0x21 turn-now, 0x22 turn-around,
//                      0x23 arrived, 0x24 forward, 0x10 vision-danger, 0x40 obstacle-near)
//   byte 1  mask      bit0 Front (forward), bit1 Left (rotate), bit2 Right (rotate), bit3 Back (proximity)
//   byte 2  intensity 0..255, scales tap travel
//   byte 3  sequence  rolling counter, for drop detection
//
// This is the clean reference Angelo can adapt for the real belt. It is non-blocking: it
// services UDP every loop and animates servos off millis(), so a long pattern never stalls
// packet reception. Network mode and pins are in config.h.
//
// Library: install "ESP32Servo" via the Arduino Library Manager. Board: an ESP32 dev board.

#include <WiFi.h>
#include <WiFiUdp.h>
#include <ESP32Servo.h>
#include "config.h"

// LC2 event codes.
static const uint8_t EV_IDLE          = 0x00;
static const uint8_t EV_VISION_DANGER = 0x10;
static const uint8_t EV_TURN_SLIGHT   = 0x20;
static const uint8_t EV_TURN_NOW      = 0x21;
static const uint8_t EV_TURN_AROUND   = 0x22;
static const uint8_t EV_ARRIVED       = 0x23;
static const uint8_t EV_FORWARD       = 0x24;
static const uint8_t EV_OBSTACLE_NEAR = 0x40;

Servo servos[4];
// Index matches the LC2 mask bits: 0 = front, 1 = left, 2 = right, 3 = back.
const int servoPins[4] = { PIN_FRONT, PIN_LEFT, PIN_RIGHT, PIN_BACK };

WiFiUDP udp;
uint8_t packet[8];

// Current commanded state, updated from the latest packet.
uint8_t curEvent = EV_IDLE;
uint8_t curMask = 0;
uint8_t curIntensity = 192;
uint8_t lastSeq = 0;
bool haveSeq = false;
unsigned long lastPacketMs = 0;

// The pattern currently animating. A new cue (event or mask change) restarts it.
uint8_t animEvent = 0xFF;
uint8_t animMask = 0;
uint8_t animIntensity = 192;
unsigned long animStartMs = 0;

void setup() {
  Serial.begin(115200);
  delay(200);

  pinMode(PIN_STATUS_LED, OUTPUT);
  digitalWrite(PIN_STATUS_LED, LOW);

  for (int i = 0; i < 4; i++) {
    servos[i].setPeriodHertz(50);
    servos[i].attach(servoPins[i], 500, 2400);
    servos[i].write(SERVO_NEUTRAL_DEG);
  }

  startNetwork();
  udp.begin(LC2_PORT);
  Serial.printf("LC2 listening on UDP %d\n", LC2_PORT);
}

void loop() {
  pollPackets();

  // Link health: if the phone goes silent, fall back to idle so no stale cue lingers.
  if (millis() - lastPacketMs > SILENCE_TIMEOUT_MS) {
    curEvent = EV_IDLE;
    curMask = 0;
  }
  digitalWrite(PIN_STATUS_LED, (millis() - lastPacketMs < SILENCE_TIMEOUT_MS) ? HIGH : LOW);

  // Restart the animation when the cue changes. Repeated identical packets (the phone
  // restages the same cue every heartbeat) do not re-trigger a one-shot pattern.
  if (curEvent != animEvent || curMask != animMask) {
    animEvent = curEvent;
    animMask = curMask;
    animIntensity = curIntensity;
    animStartMs = millis();
  }

  animate();
}

// ---------------------------------------------------------------------------
// Networking
// ---------------------------------------------------------------------------
void startNetwork() {
#if AP_MODE
  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, strlen(AP_PASS) >= 8 ? AP_PASS : nullptr);
  Serial.print("AP up. Join \"");
  Serial.print(AP_SSID);
  Serial.print("\", then point the app at ");
  Serial.println(WiFi.softAPIP());
#else
  WiFi.mode(WIFI_STA);
  WiFi.begin(STA_SSID, STA_PASS);
  Serial.print("Joining ");
  Serial.print(STA_SSID);
  while (WiFi.status() != WL_CONNECTED) {
    delay(300);
    Serial.print(".");
  }
  Serial.print("\nJoined. Point the app at ");
  Serial.println(WiFi.localIP());
#endif
}

void pollPackets() {
  int size = udp.parsePacket();
  while (size > 0) {
    int n = udp.read(packet, sizeof(packet));
    if (n >= 4) {
      uint8_t event = packet[0];
      uint8_t mask = packet[1];
      uint8_t intensity = packet[2];
      uint8_t seq = packet[3];

      // Drop detection: a jump greater than 1 (outside the 255->0 wrap) means lost packets.
      if (haveSeq) {
        uint8_t expected = (uint8_t)(lastSeq + 1);
        if (seq != expected) {
          Serial.printf("seq gap: got %u expected %u\n", seq, expected);
        }
      }
      lastSeq = seq;
      haveSeq = true;

      curEvent = event;
      curMask = mask;
      curIntensity = intensity;
      lastPacketMs = millis();
    }
    size = udp.parsePacket();
  }
}

// ---------------------------------------------------------------------------
// Servo animation. All patterns are built from a "tap": move to the tapped angle for
// TAP_DOWN_MS, return to neutral for TAP_UP_MS. Intensity scales the tapped angle.
// ---------------------------------------------------------------------------
int tappedAngle() {
  int travel = SERVO_TAP_DEG - SERVO_NEUTRAL_DEG;
  return SERVO_NEUTRAL_DEG + (travel * animIntensity) / 255;
}

// Whether a tap cycle is in its "down" phase at the given elapsed time within the cycle.
bool tapDown(unsigned long phase) {
  return phase < (unsigned long)TAP_DOWN_MS;
}

void setServo(int i, bool down) {
  servos[i].write(down ? tappedAngle() : SERVO_NEUTRAL_DEG);
}

void allNeutral() {
  for (int i = 0; i < 4; i++) servos[i].write(SERVO_NEUTRAL_DEG);
}

void animate() {
  unsigned long elapsed = millis() - animStartMs;
  const unsigned long cycle = TAP_DOWN_MS + TAP_UP_MS;

  switch (animEvent) {
    case EV_FORWARD:
    case EV_TURN_SLIGHT:
      // Single tap, then hold neutral. Front for forward, Left/Right for a gentle rotate.
      drivePulses(1, elapsed, cycle);
      break;

    case EV_TURN_NOW:
    case EV_TURN_AROUND:
      // Triple tap, then hold neutral. Mask selects the side(s).
      drivePulses(3, elapsed, cycle);
      break;

    case EV_VISION_DANGER:
    case EV_OBSTACLE_NEAR:
      // Sustained tap-train on Back while the hazard is active.
      driveTrain(elapsed, cycle);
      break;

    case EV_ARRIVED:
      // Sweep front -> left -> right -> back, once, ignoring the mask.
      driveSweep(elapsed);
      break;

    case EV_IDLE:
    default:
      allNeutral();
      break;
  }
}

// Fire `count` taps on the masked servos, then hold neutral.
void drivePulses(int count, unsigned long elapsed, unsigned long cycle) {
  unsigned long total = cycle * count;
  for (int i = 0; i < 4; i++) {
    bool masked = (animMask >> i) & 0x1;
    if (!masked) { servos[i].write(SERVO_NEUTRAL_DEG); continue; }
    if (elapsed >= total) { servos[i].write(SERVO_NEUTRAL_DEG); continue; }
    setServo(i, tapDown(elapsed % cycle));
  }
}

// Continuous taps on the masked servos for as long as the event holds.
void driveTrain(unsigned long elapsed, unsigned long cycle) {
  for (int i = 0; i < 4; i++) {
    bool masked = (animMask >> i) & 0x1;
    if (!masked) { servos[i].write(SERVO_NEUTRAL_DEG); continue; }
    setServo(i, tapDown(elapsed % cycle));
  }
}

// One pass across the four servos in order, each tapped for SWEEP_STEP_MS.
void driveSweep(unsigned long elapsed) {
  int step = elapsed / SWEEP_STEP_MS;  // 0..3 active, >=4 done
  for (int i = 0; i < 4; i++) {
    servos[i].write((i == step) ? tappedAngle() : SERVO_NEUTRAL_DEG);
  }
}
