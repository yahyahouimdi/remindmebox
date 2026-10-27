#pragma once

// ---------------------------------------------------------------------------
// RemindMeBox hardware configuration (ESP32-WROVER).
// Pin map follows the electrical design in the report (Fig. 3.2).
// ---------------------------------------------------------------------------

#define FIRMWARE_VERSION "1.0.0"

// Outputs
#define LED_PIN 2            // alert LED
#define BUZZER_PIN 25        // active buzzer
#define SERVO_PIN 13         // rotor servo (selects compartment / chute)
#define PUMP_PIN 26          // 12V vacuum pump through a logic-level MOSFET

// Inputs
#define IR_PIN 34            // Sharp IR presence sensor facing the pill tray (ADC1)
#define BUTTON_PIN 27        // SOS / setup button to GND (internal pull-up)
#define BATTERY_PIN 35       // battery voltage through divider (ADC1)

// GPS module on UART2
#define GPS_RX_PIN 16
#define GPS_TX_PIN 17
#define GPS_BAUD 9600

// OLED SH1106 on the default I2C pins (SDA 21, SCL 22)

// ---- Dispensing mechanism (calibrate on the assembled box) ----------------
#define MAX_COMPARTMENTS 12
#define COMPARTMENT_ANGLE_START 20   // servo angle above compartment 1
#define COMPARTMENT_ANGLE_STEP 25    // angle between two compartments
#define CHUTE_ANGLE 175              // servo angle above the chute to the tray
#define SERVO_SETTLE_MS 700
#define PUMP_PICK_MS 900             // suction time to grab one pill
#define PILL_DROP_MS 600             // time for the pill to slide to the tray

// ---- Pill pickup detection --------------------------------------------------
// Pickup is confirmed when a hand is detected over the tray for PICKUP_HOLD_MS.
#define PICKUP_DISTANCE_CM 12.0f
#define PICKUP_HOLD_MS 400

// ---- Alerts -----------------------------------------------------------------
#define REMINDER_BEEP_INTERVAL_MS 30000UL
#define SOS_HOLD_MS 2000UL           // hold the button 2 s to send an SOS
#define FACTORY_RESET_HOLD_MS 10000UL // hold 10 s to forget WiFi and re-run setup

// ---- Battery (3S LiPo 2200 mAh through a 100k/22k divider) ----------------
#define BATTERY_DIVIDER_RATIO 5.545f // (100k + 22k) / 22k
#define BATTERY_EMPTY_V 9.6f
#define BATTERY_FULL_V 12.6f

// ---- Cloud sync ---------------------------------------------------------------
#define CONFIG_SYNC_INTERVAL_MS 60000UL
#define TELEMETRY_INTERVAL_MS 60000UL
#define QUEUE_FLUSH_INTERVAL_MS 10000UL
#define EVENTS_PER_UPLOAD 20
#define QUEUE_MAX_BYTES 96000
#define HTTP_TIMEOUT_MS 12000

#define MAX_SCHEDULES 24

// ---- BLE provisioning (must match lib/services/provisioning_service.dart) ----
#define BLE_SERVICE_UUID "6e0a0001-7c5f-4b8e-9d3a-52454d494e44"
#define BLE_INFO_UUID    "6e0a0002-7c5f-4b8e-9d3a-52454d494e44"
#define BLE_WIFI_UUID    "6e0a0003-7c5f-4b8e-9d3a-52454d494e44"
#define BLE_STATUS_UUID  "6e0a0004-7c5f-4b8e-9d3a-52454d494e44"
