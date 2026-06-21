// Citrus Squad belt firmware (Arduino + Adafruit PCA9685), USB-tethered fallback path.
//
// By Angelo (the `arduino` branch). This is the firmware the belt-bridge server
// (`server/app.py`) drives over USB serial when there is no ESP32 / Wi-Fi module.
//
// Protocol: the server sends ONE newline-terminated word per cue, at 9600 baud:
//   forward | stop | left | right | rotate_left | rotate_right | idle
// Each command latches a CONTINUOUS pulse pattern that keeps running until a new
// command arrives. "idle" is what stops the belt, so the server must send it when a
// cue clears and on link silence. See server/README.md for the LC2 -> command mapping.

#include <Wire.h>
#include <Adafruit_PWMServoDriver.h>

Adafruit_PWMServoDriver pwm = Adafruit_PWMServoDriver();

#define NUM_SERVOS 4
#define SERVO_MIN 100
#define SERVO_MAX 300

// Map your servos to specific positions for clarity
const int PIN_FRONT = 0;
const int PIN_RIGHT = 1;
const int PIN_BACK  = 2;
const int PIN_LEFT  = 3;

int servoPins[NUM_SERVOS] = {PIN_FRONT, PIN_RIGHT, PIN_BACK, PIN_LEFT};

// --- STATE MACHINE VARIABLES ---
enum HapticState { 
  IDLE, 
  FORWARD, 
  STOP, 
  TURN_LEFT, 
  TURN_RIGHT, 
  ROTATE_LEFT, 
  ROTATE_RIGHT 
};

HapticState currentState = IDLE;

unsigned long previousMillis = 0;
unsigned long currentInterval = 0; 
bool isPulseOn = false; // Tracks if the servo is currently extended (tapping) or retracted

// Adjust these timings to change the "feel" of the tap
// Note: The smooth sweep takes about 50ms, so we subtracted 50ms from the original timings
// to keep the overall heartbeat feeling the same.
const int PULSE_ON_TIME = 150;  
const int PULSE_OFF_TIME = 250; 

void setup() {
  Serial.begin(9600);
  Serial.println("Haptic Navigation System Starting...");

  pwm.begin();
  pwm.setPWMFreq(50);

  // Initialize all servos to the minimum position smoothly
  retractAllServosSmoothly();
}

void loop() {
  // 1. Check for incoming commands from the Google Maps API
  checkSerialCommands();

  // 2. Update the servos without blocking the code
  updateHaptics();
}

// --- SERIAL COMMUNICATION ---

void checkSerialCommands() {
  if (Serial.available() > 0) {
    // Read the incoming string until a newline character
    String cmd = Serial.readStringUntil('\n');
    cmd.trim(); // Remove any accidental whitespace or carriage returns

    // Print exactly what the Arduino thinks it received for debugging
    if (cmd.length() > 0) {
      Serial.print("Received command: [");
      Serial.print(cmd);
      Serial.println("]");
    }

    // Route the command to the correct trigger function
    if (cmd == "forward") {
      triggerPattern(FORWARD);
    }
    else if (cmd == "stop") {
      triggerPattern(STOP);
    }
    else if (cmd == "left") {
      triggerPattern(TURN_LEFT);
    }
    else if (cmd == "right") {
      triggerPattern(TURN_RIGHT);
    }
    else if (cmd == "rotate_left") {
      triggerPattern(ROTATE_LEFT);
    }
    else if (cmd == "rotate_right") {
      triggerPattern(ROTATE_RIGHT);
    }
    else if (cmd == "idle") {
      triggerPattern(IDLE);
    }
    else if (cmd.length() > 0) {
      Serial.println("-> ERROR: Command not recognized.");
    }
  }
}

// --- TRIGGER FUNCTION ---

// This function safely transitions between states
void triggerPattern(HapticState newState) {
  if (currentState != newState) {
    Serial.println("-> State Changed");
    currentState = newState;
    isPulseOn = false;       // Reset the pulse phase
    currentInterval = 0;     // Force the new pattern to start immediately
    retractAllServosSmoothly(); // Retract all servos to ensure a clean slate
  }
}

// --- SMOOTH MOVEMENT HELPER FUNCTIONS ---

// Smoothly extend specific servos simultaneously to prevent power spikes
void extendServosSmoothly(bool front, bool right, bool back, bool left) {
  for(int pos = SERVO_MIN; pos <= SERVO_MAX; pos += 20) {
    if(front) pwm.setPWM(PIN_FRONT, 0, pos);
    if(right) pwm.setPWM(PIN_RIGHT, 0, pos);
    if(back)  pwm.setPWM(PIN_BACK, 0, pos);
    if(left)  pwm.setPWM(PIN_LEFT, 0, pos);
    delay(2); // A tiny 2ms delay spreads the massive current spike out over 50ms
  }
}

// Smoothly retract all servos
void retractAllServosSmoothly() {
  for(int pos = SERVO_MAX; pos >= SERVO_MIN; pos -= 20) {
    for(int i = 0; i < NUM_SERVOS; i++) {
      pwm.setPWM(servoPins[i], 0, pos);
    }
    delay(2);
  }
}


// --- THE STATE MACHINE ---
// Runs constantly in the loop, creating a continuous pulse based on the active state

void updateHaptics() {
  unsigned long currentMillis = millis();

  // If enough time hasn't passed, do nothing and exit the function
  if (currentMillis - previousMillis < currentInterval) {
    return;
  }

  // Update the timer
  previousMillis = currentMillis;

  // If we are idle, do nothing
  if (currentState == IDLE) {
    return;
  }

  // Toggle the pulse state (ON to OFF, or OFF to ON)
  isPulseOn = !isPulseOn; 
  
  // Set the duration for the next cycle
  currentInterval = isPulseOn ? PULSE_ON_TIME : PULSE_OFF_TIME;

  // If it's the "OFF" phase of the pulse, retract everything smoothly
  if (!isPulseOn) {
    retractAllServosSmoothly();
    return;
  }

  // If it's the "ON" phase of the pulse, sweep the correct servos forward smoothly
  // Format: extendServosSmoothly(FRONT, RIGHT, BACK, LEFT);
  switch (currentState) {
    case FORWARD:
      extendServosSmoothly(true, false, false, false);
      break;
      
    case STOP:
      extendServosSmoothly(true, true, true, true);
      break;
      
    case TURN_LEFT:
      extendServosSmoothly(true, false, false, true);
      break;
      
    case TURN_RIGHT:
      extendServosSmoothly(true, true, false, false);
      break;
      
    case ROTATE_LEFT:
      extendServosSmoothly(false, false, false, true);
      break;
      
    case ROTATE_RIGHT:
      extendServosSmoothly(false, true, false, false);
      break;
  }
}