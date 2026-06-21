// Citrus Squad belt firmware (Arduino + Adafruit PCA9685), USB-tethered fallback path.
//
// Original sketch by Angelo (the `arduino` branch). This is the firmware the belt-bridge
// server (`server/app.py`) drives over USB serial when there is no ESP32 / Wi-Fi module.
//
// Protocol: the server sends ONE ASCII command byte per cue, at 9600 baud:
//   's' = stop / hazard buzz   (all servos)
//   'l' = turn left  (double-tap on the Left servo)
//   'r' = turn right (double-tap on the Right servo)
//   'f' = go straight (double-tap on the Front servo)
// The server only sends a byte when the cue CHANGES, so the one-shot patterns below are
// not re-triggered by the phone's 10 Hz heartbeat. Anything else (idle) sends nothing and
// the belt falls quiet on its own. See server/README.md for the LC2 -> command mapping.

#include <Wire.h>
#include <Adafruit_PWMServoDriver.h>

Adafruit_PWMServoDriver pwm = Adafruit_PWMServoDriver();

#define NUM_SERVOS 4
#define SERVO_MIN 100
#define SERVO_MID 300
#define SERVO_MAX 600

// Map your servos to specific positions for clarity
const int PIN_FRONT = 0;
const int PIN_RIGHT = 1;
const int PIN_BACK  = 2;
const int PIN_LEFT  = 3;

int servoPins[NUM_SERVOS] = {PIN_FRONT, PIN_RIGHT, PIN_BACK, PIN_LEFT};

// --- STATE MACHINE VARIABLES ---
enum HapticState { IDLE, STOP_PATTERN, LEFT_TURN_PATTERN, RIGHT_TURN_PATTERN, FORWARD_PATTERN };
HapticState currentState = IDLE;

unsigned long previousMillis = 0;
unsigned long currentInterval = 0;
int patternStep = 0;

void setup() {
  Serial.begin(9600);
  Serial.println("Haptic Navigation System Starting...");

  pwm.begin();
  pwm.setPWMFreq(50);

  // Initialize all servos to min
  setAllServos(SERVO_MIN);
}

void loop() {
  // Update the servos without blocking the rest of your code
  updateHaptics();

  // The belt-bridge server sends one command byte per cue change.
  if (Serial.available() > 0) {
    char cmd = Serial.read();
    if (cmd == 's') triggerStopPattern();
    if (cmd == 'l') triggerLeftTurn();
    if (cmd == 'r') triggerRightTurn();
    if (cmd == 'f') triggerForward();
  }
}

// --- HELPER FUNCTIONS ---

void setAllServos(int position) {
  for(int i = 0; i < NUM_SERVOS; i++){
    pwm.setPWM(servoPins[i], 0, position);
  }
}

// --- TRIGGER FUNCTIONS ---
// Call these to kick off a specific sequence

void triggerStopPattern() {
  if (currentState != STOP_PATTERN) {
    currentState = STOP_PATTERN;
    patternStep = 0;
    currentInterval = 0; // Trigger immediately
  }
}

void triggerLeftTurn() {
  if (currentState != LEFT_TURN_PATTERN) {
    currentState = LEFT_TURN_PATTERN;
    patternStep = 0;
    currentInterval = 0;
  }
}

void triggerRightTurn() {
  if (currentState != RIGHT_TURN_PATTERN) {
    currentState = RIGHT_TURN_PATTERN;
    patternStep = 0;
    currentInterval = 0;
  }
}

void triggerForward() {
  if (currentState != FORWARD_PATTERN) {
    currentState = FORWARD_PATTERN;
    patternStep = 0;
    currentInterval = 0;
  }
}

// --- THE STATE MACHINE ---
// This runs constantly in the loop, checking if it's time to move a servo

void updateHaptics() {
  unsigned long currentMillis = millis();

  // If enough time hasn't passed, do nothing and exit the function
  if (currentMillis - previousMillis < currentInterval) {
    return;
  }

  // Update the timer
  previousMillis = currentMillis;

  // Handle the active pattern
  switch (currentState) {

    case IDLE:
      // Do nothing
      break;

    // ----------------------------------------------------
    // Your original stop() function, converted to millis()
    // ----------------------------------------------------
    case STOP_PATTERN:
      if (patternStep == 0) {
        setAllServos(SERVO_MIN);
        currentInterval = 800;
        patternStep++;
      }
      else if (patternStep == 1) {
        setAllServos(SERVO_MID);
        currentInterval = 800;
        patternStep++;
      }
      else if (patternStep == 2) {
        setAllServos(SERVO_MIN);
        currentState = IDLE; // Sequence finished
      }
      break;

    // ----------------------------------------------------
    // Double-tap left sequence
    // ----------------------------------------------------
    case LEFT_TURN_PATTERN:
      if (patternStep == 0) {
        pwm.setPWM(PIN_LEFT, 0, SERVO_MAX); // Tap 1
        currentInterval = 150;
        patternStep++;
      } else if (patternStep == 1) {
        pwm.setPWM(PIN_LEFT, 0, SERVO_MIN); // Release 1
        currentInterval = 100;
        patternStep++;
      } else if (patternStep == 2) {
        pwm.setPWM(PIN_LEFT, 0, SERVO_MAX); // Tap 2
        currentInterval = 150;
        patternStep++;
      } else if (patternStep == 3) {
        pwm.setPWM(PIN_LEFT, 0, SERVO_MIN); // Release 2
        currentState = IDLE;
      }
      break;

    // ----------------------------------------------------
    // Double-tap right sequence
    // ----------------------------------------------------
    case RIGHT_TURN_PATTERN:
      if (patternStep == 0) {
        pwm.setPWM(PIN_RIGHT, 0, SERVO_MAX); // Tap 1
        currentInterval = 150;
        patternStep++;
      } else if (patternStep == 1) {
        pwm.setPWM(PIN_RIGHT, 0, SERVO_MIN); // Release 1
        currentInterval = 100;
        patternStep++;
      } else if (patternStep == 2) {
        pwm.setPWM(PIN_RIGHT, 0, SERVO_MAX); // Tap 2
        currentInterval = 150;
        patternStep++;
      } else if (patternStep == 3) {
        pwm.setPWM(PIN_RIGHT, 0, SERVO_MIN); // Release 2
        currentState = IDLE;
      }
      break;

    // ----------------------------------------------------
    // Double-tap FRONT sequence (Go Straight)
    // ----------------------------------------------------
    case FORWARD_PATTERN:
      if (patternStep == 0) {
        pwm.setPWM(PIN_FRONT, 0, SERVO_MAX); // Tap 1
        currentInterval = 150;
        patternStep++;
      } else if (patternStep == 1) {
        pwm.setPWM(PIN_FRONT, 0, SERVO_MIN); // Release 1
        currentInterval = 100;
        patternStep++;
      } else if (patternStep == 2) {
        pwm.setPWM(PIN_FRONT, 0, SERVO_MAX); // Tap 2
        currentInterval = 150;
        patternStep++;
      } else if (patternStep == 3) {
        pwm.setPWM(PIN_FRONT, 0, SERVO_MIN); // Release 2
        currentState = IDLE;                 // Sequence finished
      }
      break;
  }
}
