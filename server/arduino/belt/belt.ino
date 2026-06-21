// Citrus Squad belt firmware (Arduino + Adafruit PCA9685), USB-tethered fallback path.
//
// By Angelo (the `arduino` branch). This is the firmware the belt-bridge server
// (`server/app.py`) drives over USB serial when there is no ESP32 / Wi-Fi module.
//
// Protocol: the server sends ONE newline-terminated command per cue, at 9600 baud.
//   m<bits>  -- the live path: fire exactly the motors in the phone's quadrant mask
//              (bit0 Front, bit1 Left, bit2 Right, bit3 Back). e.g. "m2" = left only,
//              "m6" = left+right, "m15" = all four. This is the finite per-servo control.
//   idle     -- stop the belt (the server sends it when a cue clears and on link silence)
//   named words (forward | stop | left | right | rotate_left | rotate_right | u_turn |
//              low_battery/error) -- fixed patterns kept for manual and dashboard testing.
// Every command latches a CONTINUOUS pulse that runs until the next one (low_battery is a
// finite 3-tap alert). See server/README.md for the cue -> command mapping.

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
  ROTATE_RIGHT,
  U_TURN,
  LOW_BATTERY,
  MASK             // fire exactly the motors named in maskBits (the phone's quadrant mask)
};

HapticState currentState = IDLE;

// Which motors the MASK state pulses, using the phone's quadrant bits:
// bit0 = Front, bit1 = Left, bit2 = Right, bit3 = Back. This is the finite per-motor path:
// the server sends "m<bits>" and exactly those motors fire, matching the phone's belt view.
const uint8_t M_FRONT = 0x01, M_LEFT = 0x02, M_RIGHT = 0x04, M_BACK = 0x08;
uint8_t maskBits = 0;

unsigned long previousMillis = 0;
unsigned long currentInterval = 0;
bool isPulseOn = false;

// Tracks how many taps have occurred for finite patterns
int tapCounter = 0;

// The timing for ALL taps across the system
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
    cmd.trim(); 

    if (cmd.length() > 0) {
      Serial.print("Received command: [");
      Serial.print(cmd);
      Serial.println("]");
    }

    // Route the command to the correct trigger function
    if (cmd == "forward") triggerPattern(FORWARD);
    else if (cmd == "stop") triggerPattern(STOP);
    else if (cmd == "left") triggerPattern(TURN_LEFT);
    else if (cmd == "right") triggerPattern(TURN_RIGHT);
    else if (cmd == "rotate_left") triggerPattern(ROTATE_LEFT);
    else if (cmd == "rotate_right") triggerPattern(ROTATE_RIGHT);
    else if (cmd == "u_turn") triggerPattern(U_TURN);
    else if (cmd == "low_battery" || cmd == "error") triggerPattern(LOW_BATTERY);
    else if (cmd == "idle") triggerPattern(IDLE);
    else if (cmd.startsWith("m")) setMask((uint8_t) cmd.substring(1).toInt());
    else if (cmd.length() > 0) Serial.println("-> ERROR: Command not recognized.");
  }
}

// --- TRIGGER FUNCTION ---

// This function safely transitions between states
void triggerPattern(HapticState newState) {
  if (currentState != newState) {
    Serial.println("-> State Changed");
    currentState = newState;
    isPulseOn = false;
    currentInterval = 0;
    tapCounter = 0;             // Reset the tap counter for the new state
    retractAllServosSmoothly();
  }
}

// Fire exactly the motors named in `bits` (the phone's quadrant mask). Empty mask = idle.
// Re-triggers when the set of motors changes so the new mask takes effect immediately.
void setMask(uint8_t bits) {
  if (bits == 0) { triggerPattern(IDLE); return; }
  if (currentState != MASK || bits != maskBits) {
    maskBits = bits;
    currentState = MASK;
    isPulseOn = false;
    currentInterval = 0;
    tapCounter = 0;
    retractAllServosSmoothly();
  }
}

// --- SMOOTH MOVEMENT HELPER FUNCTIONS ---

void extendServosSmoothly(bool front, bool right, bool back, bool left) {
  for(int pos = SERVO_MIN; pos <= SERVO_MAX; pos += 20) {
    if(front) pwm.setPWM(PIN_FRONT, 0, pos);
    if(right) pwm.setPWM(PIN_RIGHT, 0, pos);
    if(back)  pwm.setPWM(PIN_BACK, 0, pos);
    if(left)  pwm.setPWM(PIN_LEFT, 0, pos);
    delay(2); 
  }
}

void retractAllServosSmoothly() {
  for(int pos = SERVO_MAX; pos >= SERVO_MIN; pos -= 20) {
    for(int i = 0; i < NUM_SERVOS; i++) {
      pwm.setPWM(servoPins[i], 0, pos);
    }
    delay(2);
  }
}

// --- THE STATE MACHINE ---

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
  
  // Set the duration for the next cycle (Now identical for all commands)
  currentInterval = isPulseOn ? PULSE_ON_TIME : PULSE_OFF_TIME;

  // If it's the "OFF" phase of the pulse, retract everything smoothly
  if (!isPulseOn) {
    retractAllServosSmoothly();
    
    // Check if we just completed a tap during a finite state
    if (currentState == LOW_BATTERY) {
      tapCounter++;
      // If we have completed 3 standard taps, automatically switch back to IDLE
      if (tapCounter >= 3) {
        Serial.println("-> Alert Complete. Returning to IDLE.");
        triggerPattern(IDLE);
      }
    }
    return;
  }

  // If it's the "ON" phase of the pulse, sweep the correct servos forward smoothly
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
      
    case U_TURN:
      extendServosSmoothly(false, false, true, false);
      break;
      
    case LOW_BATTERY:
      extendServosSmoothly(false, false, true, false);
      break;

    case MASK:
      // Fire exactly the motors the phone lit, decoding its quadrant bits.
      // extendServosSmoothly(front, right, back, left).
      extendServosSmoothly(maskBits & M_FRONT, maskBits & M_RIGHT,
                           maskBits & M_BACK,  maskBits & M_LEFT);
      break;
  }
}