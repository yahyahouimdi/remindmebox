// RemindMeBox ESP32 firmware
//
//  Setup mode (no WiFi saved): advertises over BLE so the app can send WiFi
//  credentials, then reboots into run mode.
//
//  Run mode:
//   - core 1 (loop): local scheduler, dispensing (servo + vacuum pump), pickup
//     detection (IR), alarm (LED + buzzer), OLED, SOS button, GPS parsing.
//   - core 0 (networkTask): pulls schedules from the backend, uploads the
//     event queue and telemetry over HTTPS.
//  Everything needed to dispense is cached on flash and every event is queued,
//  so the box keeps working through WiFi outages and syncs when back online.
//
// Libraries: ArduinoJson 7, U8g2, ESP32Servo, TinyGPSPlus (ESP32 Arduino core 3.x)

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <LittleFS.h>
#include <ArduinoJson.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLE2902.h>
#include <U8g2lib.h>
#include <ESP32Servo.h>
#include <TinyGPSPlus.h>
#include <time.h>
#include <sys/time.h>

#include "config.h"
#include "secrets.h"
#include "certs.h"

// ============================================================================
// Data
// ============================================================================

struct Dose {
  uint8_t compartment;
  uint8_t count;
};

struct Schedule {
  char id[65];
  uint8_t hour;
  uint8_t minute;
  uint8_t daysMask;  // bit 0 = Monday ... bit 6 = Sunday
  uint8_t doseCount;
  Dose doses[MAX_COMPARTMENTS];
};

struct DeviceConfig {
  bool loaded;
  bool claimed;
  char patientName[41];
  int utcOffsetMinutes;
  int missedDelayMin;
  int scheduleCount;
  Schedule schedules[MAX_SCHEDULES];
  char medNames[MAX_COMPARTMENTS + 1][21];
};

struct DoneEntry {
  char id[65];
  char date[11];
};

struct ActiveDose {
  bool active;
  Schedule schedule;
  char date[11];
  char time[6];
  time_t dispensedAt;
  unsigned long alarmStartedMs;
  unsigned long presenceSinceMs;
};

struct GpsSnapshot {
  bool valid;
  double lat;
  double lng;
  float accuracy;
};

static const char* CONFIG_FILE = "/config.json";
static const char* QUEUE_FILE = "/queue.jsonl";
static const char* DONE_FILE = "/done.json";

U8G2_SH1106_128X64_NONAME_F_HW_I2C display(U8G2_R0, U8X8_PIN_NONE);
Servo rotor;
TinyGPSPlus gps;
HardwareSerial gpsSerial(2);
Preferences prefs;

DeviceConfig config;        // guarded by stateMutex
GpsSnapshot gpsFix;         // guarded by stateMutex
DoneEntry done[MAX_SCHEDULES * 2];
ActiveDose activeDose;

SemaphoreHandle_t stateMutex;
SemaphoreHandle_t fsMutex;

volatile bool wifiOnline = false;
volatile bool flushRequested = false;
volatile uint32_t queueGeneration = 0;
bool setupMode = false;

String messageLine1, messageLine2;
unsigned long messageUntilMs = 0;

void drawScreen();

// ============================================================================
// Small helpers
// ============================================================================

bool timeValid() {
  return time(nullptr) > 1700000000;  // after Nov 2023
}

int utcOffsetMinutes() {
  xSemaphoreTake(stateMutex, portMAX_DELAY);
  int offset = config.utcOffsetMinutes;
  xSemaphoreGive(stateMutex);
  return offset;
}

// Box-local wall clock. The system clock stays in UTC; the offset comes from the backend.
void localTime(struct tm* out) {
  time_t t = time(nullptr) + (time_t)utcOffsetMinutes() * 60;
  gmtime_r(&t, out);
}

void dateKey(const struct tm& t, char* out) {
  snprintf(out, 11, "%04d-%02d-%02d", t.tm_year + 1900, t.tm_mon + 1, t.tm_mday);
}

int isoWeekday(const struct tm& t) {
  return t.tm_wday == 0 ? 7 : t.tm_wday;
}

void showMessage(const String& line1, const String& line2, unsigned long durationMs) {
  messageLine1 = line1;
  messageLine2 = line2;
  messageUntilMs = millis() + durationMs;
}

float readTrayDistanceCm() {
  long sum = 0;
  for (int i = 0; i < 5; i++) sum += analogRead(IR_PIN);
  // Sharp IR curve calibrated for a 10-bit reading; the ESP32 ADC is 12-bit.
  int raw = (int)(sum / 5) / 4;
  if (raw <= 20) return 999.0f;
  return 4800.0f / (raw - 20);
}

int readBatteryPercent() {
  float volts = analogReadMilliVolts(BATTERY_PIN) / 1000.0f * BATTERY_DIVIDER_RATIO;
  if (volts < 1.0f) return -1;  // no battery sense wired (USB powered)
  float pct = (volts - BATTERY_EMPTY_V) / (BATTERY_FULL_V - BATTERY_EMPTY_V) * 100.0f;
  return constrain((int)pct, 0, 100);
}

// ============================================================================
// Flash storage (LittleFS)
// ============================================================================

String readFile(const char* path) {
  xSemaphoreTake(fsMutex, portMAX_DELAY);
  String content;
  File f = LittleFS.open(path, "r");
  if (f) {
    content = f.readString();
    f.close();
  }
  xSemaphoreGive(fsMutex);
  return content;
}

void writeFile(const char* path, const String& content) {
  xSemaphoreTake(fsMutex, portMAX_DELAY);
  File f = LittleFS.open(path, "w");
  if (f) {
    f.print(content);
    f.close();
  }
  xSemaphoreGive(fsMutex);
}

// Copies `path` from byte `offset` to its end into a new file (caller holds fsMutex).
void dropFilePrefix(const char* path, size_t offset) {
  File src = LittleFS.open(path, "r");
  if (!src) return;
  if (offset >= src.size()) {
    src.close();
    LittleFS.remove(path);
    return;
  }
  src.seek(offset);
  File dst = LittleFS.open("/tmp.jsonl", "w");
  uint8_t buf[256];
  while (src.available()) {
    size_t n = src.read(buf, sizeof(buf));
    dst.write(buf, n);
  }
  src.close();
  dst.close();
  LittleFS.remove(path);
  LittleFS.rename("/tmp.jsonl", path);
}

void queueEvent(JsonDocument& event) {
  String line;
  serializeJson(event, line);
  xSemaphoreTake(fsMutex, portMAX_DELAY);
  File f = LittleFS.open(QUEUE_FILE, "a");
  if (f) {
    f.println(line);
    size_t size = f.size();
    f.close();
    if (size > QUEUE_MAX_BYTES) {
      // Storage is full after a very long outage: keep the most recent half.
      File r = LittleFS.open(QUEUE_FILE, "r");
      r.seek(size / 2);
      r.readStringUntil('\n');
      size_t cut = r.position();
      r.close();
      dropFilePrefix(QUEUE_FILE, cut);
      queueGeneration++;
    }
  }
  xSemaphoreGive(fsMutex);
  flushRequested = true;
}

// ---- "already dispensed today" markers: never dispense a schedule twice a day ----

void loadDone() {
  memset(done, 0, sizeof(done));
  JsonDocument doc;
  if (deserializeJson(doc, readFile(DONE_FILE))) return;
  int i = 0;
  for (JsonPair kv : doc.as<JsonObject>()) {
    if (i >= (int)(sizeof(done) / sizeof(done[0]))) break;
    strlcpy(done[i].id, kv.key().c_str(), sizeof(done[i].id));
    strlcpy(done[i].date, kv.value() | "", sizeof(done[i].date));
    i++;
  }
}

void saveDone() {
  JsonDocument doc;
  for (auto& d : done) {
    if (d.id[0]) doc[d.id] = d.date;
  }
  String out;
  serializeJson(doc, out);
  writeFile(DONE_FILE, out);
}

bool isDone(const char* scheduleId, const char* date) {
  for (auto& d : done) {
    if (strcmp(d.id, scheduleId) == 0) return strcmp(d.date, date) == 0;
  }
  return false;
}

void markDone(const char* scheduleId, const char* date) {
  DoneEntry* slot = nullptr;
  for (auto& d : done) {
    if (strcmp(d.id, scheduleId) == 0) { slot = &d; break; }
  }
  if (!slot) {
    // Reuse a free slot, otherwise the oldest entry.
    for (auto& d : done) {
      if (!d.id[0]) { slot = &d; break; }
      if (!slot || strcmp(d.date, slot->date) < 0) slot = &d;
    }
  }
  strlcpy(slot->id, scheduleId, sizeof(slot->id));
  strlcpy(slot->date, date, sizeof(slot->date));
  saveDone();
}

// ============================================================================
// Backend API
// ============================================================================

int apiRequest(const char* method, const char* path, const String& body, String& response) {
  String url = String(API_BASE_URL) + path;
  WiFiClientSecure secureClient;
  WiFiClient plainClient;
  HTTPClient http;
  bool ok;
  if (url.startsWith("https://")) {
    secureClient.setCACert(GOOGLE_ROOT_CA);
    ok = http.begin(secureClient, url);
  } else {
    ok = http.begin(plainClient, url);  // local emulator only
  }
  if (!ok) return -1;
  http.setTimeout(HTTP_TIMEOUT_MS);
  http.addHeader("Authorization", String("Bearer ") + DEVICE_ID + ":" + DEVICE_SECRET);
  http.addHeader("Content-Type", "application/json");
  int code = strcmp(method, "GET") == 0 ? http.GET() : http.POST(body);
  if (code > 0) response = http.getString();
  http.end();
  return code;
}

bool parseConfig(const String& json, DeviceConfig& out) {
  JsonDocument doc;
  if (deserializeJson(doc, json)) return false;
  memset(&out, 0, sizeof(out));
  out.loaded = true;
  out.claimed = doc["claimed"] | false;
  strlcpy(out.patientName, doc["patientName"] | "", sizeof(out.patientName));
  out.utcOffsetMinutes = doc["utcOffsetMinutes"] | 60;
  out.missedDelayMin = doc["missedDoseDelayMin"] | 30;

  for (JsonObject c : doc["compartments"].as<JsonArray>()) {
    int index = c["index"] | 0;
    if (index >= 1 && index <= MAX_COMPARTMENTS) {
      strlcpy(out.medNames[index], c["medicationName"] | "", sizeof(out.medNames[index]));
    }
  }
  for (JsonObject s : doc["schedules"].as<JsonArray>()) {
    if (out.scheduleCount >= MAX_SCHEDULES) break;
    Schedule& sch = out.schedules[out.scheduleCount];
    const char* time = s["time"] | "";
    int h, m;
    if (sscanf(time, "%d:%d", &h, &m) != 2) continue;
    strlcpy(sch.id, s["id"] | "", sizeof(sch.id));
    sch.hour = h;
    sch.minute = m;
    for (JsonVariant day : s["days"].as<JsonArray>()) {
      int d = day.as<int>();
      if (d >= 1 && d <= 7) sch.daysMask |= 1 << (d - 1);
    }
    for (JsonObject dose : s["doses"].as<JsonArray>()) {
      if (sch.doseCount >= MAX_COMPARTMENTS) break;
      sch.doses[sch.doseCount].compartment = dose["compartment"] | 0;
      sch.doses[sch.doseCount].count = dose["count"] | 0;
      sch.doseCount++;
    }
    if (sch.id[0] && sch.daysMask && sch.doseCount) out.scheduleCount++;
  }
  if (!timeValid()) {
    // NTP not answered yet: the server clock is good enough to start.
    long serverTime = doc["serverTime"] | 0L;
    if (serverTime > 1700000000) {
      struct timeval tv = {serverTime, 0};
      settimeofday(&tv, nullptr);
    }
  }
  return true;
}

void syncConfig() {
  String response;
  int code = apiRequest("GET", "/config", "", response);
  if (code != 200) {
    Serial.printf("[sync] config failed: %d\n", code);
    return;
  }
  static DeviceConfig parsed;  // static: too large for the task stack
  if (!parseConfig(response, parsed)) return;
  xSemaphoreTake(stateMutex, portMAX_DELAY);
  config = parsed;
  xSemaphoreGive(stateMutex);
  writeFile(CONFIG_FILE, response);
  Serial.printf("[sync] %d schedule(s), claimed=%d\n", parsed.scheduleCount, parsed.claimed);
}

void sendTelemetry() {
  JsonDocument doc;
  doc["firmware"] = FIRMWARE_VERSION;
  doc["rssi"] = WiFi.RSSI();
  int battery = readBatteryPercent();
  if (battery >= 0) doc["battery"] = battery;
  xSemaphoreTake(stateMutex, portMAX_DELAY);
  GpsSnapshot fix = gpsFix;
  xSemaphoreGive(stateMutex);
  if (fix.valid) {
    doc["lat"] = fix.lat;
    doc["lng"] = fix.lng;
    doc["accuracy"] = fix.accuracy;
  }
  String body, response;
  serializeJson(doc, body);
  int code = apiRequest("POST", "/telemetry", body, response);
  if (code != 200) Serial.printf("[sync] telemetry failed: %d\n", code);
}

void flushQueue() {
  xSemaphoreTake(fsMutex, portMAX_DELAY);
  uint32_t generation = queueGeneration;
  File f = LittleFS.open(QUEUE_FILE, "r");
  if (!f) {
    xSemaphoreGive(fsMutex);
    return;
  }
  String body = "{\"events\":[";
  int count = 0;
  size_t consumed = 0;
  while (f.available() && count < EVENTS_PER_UPLOAD) {
    String line = f.readStringUntil('\n');
    consumed = f.position();
    line.trim();
    if (line.isEmpty()) continue;
    if (count) body += ',';
    body += line;
    count++;
  }
  f.close();
  if (count == 0) LittleFS.remove(QUEUE_FILE);
  xSemaphoreGive(fsMutex);
  if (count == 0) return;
  body += "]}";

  String response;
  int code = apiRequest("POST", "/events", body, response);
  // 400 means the batch can never be accepted: drop it rather than block the queue.
  if ((code >= 200 && code < 300) || code == 400) {
    xSemaphoreTake(fsMutex, portMAX_DELAY);
    if (generation == queueGeneration) dropFilePrefix(QUEUE_FILE, consumed);
    xSemaphoreGive(fsMutex);
    Serial.printf("[sync] uploaded %d event(s)\n", count);
    flushRequested = true;  // there may be more
  } else {
    Serial.printf("[sync] upload failed: %d\n", code);
  }
}

void networkTask(void*) {
  unsigned long lastConfig = 0, lastTelemetry = 0, lastFlush = 0, lastAttempt = 0;
  bool firstSync = true;
  for (;;) {
    if (WiFi.status() != WL_CONNECTED) {
      wifiOnline = false;
      if (millis() - lastAttempt > 20000) {
        WiFi.reconnect();
        lastAttempt = millis();
      }
      vTaskDelay(pdMS_TO_TICKS(1000));
      continue;
    }
    if (!wifiOnline) {
      wifiOnline = true;
      configTime(0, 0, "pool.ntp.org", "time.google.com");
      firstSync = true;
    }
    unsigned long now = millis();
    if (firstSync || now - lastConfig >= CONFIG_SYNC_INTERVAL_MS) {
      syncConfig();
      lastConfig = now;
    }
    if (firstSync || now - lastTelemetry >= TELEMETRY_INTERVAL_MS) {
      sendTelemetry();
      lastTelemetry = now;
    }
    if (firstSync || flushRequested || now - lastFlush >= QUEUE_FLUSH_INTERVAL_MS) {
      flushRequested = false;
      flushQueue();
      lastFlush = now;
    }
    firstSync = false;
    vTaskDelay(pdMS_TO_TICKS(500));
  }
}

// ============================================================================
// Dispensing
// ============================================================================

bool dispensePill(uint8_t compartment) {
  if (compartment < 1 || compartment > COMPARTMENT_COUNT) return false;
  rotor.write(COMPARTMENT_ANGLE_START + (compartment - 1) * COMPARTMENT_ANGLE_STEP);
  delay(SERVO_SETTLE_MS);
  digitalWrite(PUMP_PIN, HIGH);  // grab one pill by suction
  delay(PUMP_PICK_MS);
  rotor.write(CHUTE_ANGLE);
  delay(SERVO_SETTLE_MS);
  digitalWrite(PUMP_PIN, LOW);   // release it into the chute
  delay(PILL_DROP_MS);
  return true;
}

void queueDoseEvent(const char* status, const char* error) {
  JsonDocument ev;
  ev["type"] = "dose";
  ev["scheduleId"] = activeDose.schedule.id;
  ev["date"] = activeDose.date;
  ev["time"] = activeDose.time;
  ev["status"] = status;
  ev["at"] = (long)time(nullptr);
  if (error) ev["error"] = error;
  JsonArray doses = ev["doses"].to<JsonArray>();
  for (int i = 0; i < activeDose.schedule.doseCount; i++) {
    JsonObject d = doses.add<JsonObject>();
    d["compartment"] = activeDose.schedule.doses[i].compartment;
    d["count"] = activeDose.schedule.doses[i].count;
  }
  queueEvent(ev);
}

void stopAlarm() {
  activeDose.active = false;
  digitalWrite(LED_PIN, LOW);
  digitalWrite(BUZZER_PIN, LOW);
}

void startDose(const Schedule& schedule, const char* date) {
  // Mark first: if the box reboots mid-dispense it must not dispense again (overdose risk).
  markDone(schedule.id, date);

  activeDose = {};
  activeDose.schedule = schedule;
  strlcpy(activeDose.date, date, sizeof(activeDose.date));
  snprintf(activeDose.time, sizeof(activeDose.time), "%02d:%02d", schedule.hour, schedule.minute);
  Serial.printf("[dose] %s %s\n", activeDose.date, activeDose.time);

  showMessage("Dispensing...", activeDose.time, 60000);
  drawScreen();
  for (int i = 0; i < schedule.doseCount; i++) {
    for (int n = 0; n < schedule.doses[i].count; n++) {
      if (!dispensePill(schedule.doses[i].compartment)) {
        char error[40];
        snprintf(error, sizeof(error), "invalid compartment %d", schedule.doses[i].compartment);
        queueDoseEvent("failed", error);
        showMessage("Dispense error", "Caregiver notified", 10000);
        return;
      }
    }
  }
  messageUntilMs = 0;
  activeDose.active = true;
  activeDose.dispensedAt = time(nullptr);
  activeDose.alarmStartedMs = millis();
  queueDoseEvent("dispensed", nullptr);
}

void runScheduler() {
  if (activeDose.active || !timeValid()) return;
  struct tm now;
  localTime(&now);
  char today[11];
  dateKey(now, today);
  int weekdayBit = 1 << (isoWeekday(now) - 1);
  int nowMinutes = now.tm_hour * 60 + now.tm_min;

  xSemaphoreTake(stateMutex, portMAX_DELAY);
  if (!config.claimed) {
    xSemaphoreGive(stateMutex);
    return;
  }
  int window = config.missedDelayMin;
  Schedule due;
  bool found = false;
  for (int i = 0; i < config.scheduleCount && !found; i++) {
    const Schedule& s = config.schedules[i];
    int start = s.hour * 60 + s.minute;
    // Catch up if the box was off at the exact minute, but only within the missed-dose window.
    if ((s.daysMask & weekdayBit) && nowMinutes >= start && nowMinutes < start + window && !isDone(s.id, today)) {
      due = s;
      found = true;
    }
  }
  xSemaphoreGive(stateMutex);
  if (found) startDose(due, today);
}

void watchActiveDose() {
  if (!activeDose.active) return;
  unsigned long ms = millis();

  // Pickup: a hand over the tray for PICKUP_HOLD_MS.
  if (readTrayDistanceCm() < PICKUP_DISTANCE_CM) {
    if (!activeDose.presenceSinceMs) activeDose.presenceSinceMs = ms;
    if (ms - activeDose.presenceSinceMs >= PICKUP_HOLD_MS) {
      queueDoseEvent("taken", nullptr);
      stopAlarm();
      showMessage("Thank you!", "Dose taken", 5000);
      return;
    }
  } else {
    activeDose.presenceSinceMs = 0;
  }

  xSemaphoreTake(stateMutex, portMAX_DELAY);
  long delaySeconds = (long)config.missedDelayMin * 60;
  xSemaphoreGive(stateMutex);
  if (time(nullptr) - activeDose.dispensedAt >= delaySeconds) {
    queueDoseEvent("missed", nullptr);
    stopAlarm();
    showMessage("Dose missed", "Caregiver notified", 10000);
    return;
  }

  // LED blinks; buzzer plays 3 beeps at the start and then every REMINDER_BEEP_INTERVAL_MS.
  digitalWrite(LED_PIN, (ms / 500) % 2);
  unsigned long sinceStart = (ms - activeDose.alarmStartedMs) % REMINDER_BEEP_INTERVAL_MS;
  digitalWrite(BUZZER_PIN, sinceStart < 1200 && (sinceStart % 400) < 200);
}

// ============================================================================
// SOS button
// ============================================================================

unsigned long buttonDownMs = 0;

void factoryReset() {
  display.clearBuffer();
  display.setFont(u8g2_font_ncenB08_tr);
  display.drawStr(0, 30, "Resetting WiFi...");
  display.sendBuffer();
  prefs.begin("wifi", false);
  prefs.clear();
  prefs.end();
  xSemaphoreTake(fsMutex, portMAX_DELAY);
  LittleFS.remove(CONFIG_FILE);
  LittleFS.remove(DONE_FILE);
  xSemaphoreGive(fsMutex);
  delay(1500);
  ESP.restart();
}

void sendSos() {
  JsonDocument ev;
  ev["type"] = "sos";
  ev["at"] = (long)time(nullptr);
  xSemaphoreTake(stateMutex, portMAX_DELAY);
  GpsSnapshot fix = gpsFix;
  xSemaphoreGive(stateMutex);
  if (fix.valid) {
    ev["lat"] = fix.lat;
    ev["lng"] = fix.lng;
  }
  queueEvent(ev);
  showMessage("SOS sent", wifiOnline ? "Help is notified" : "Will send when online", 15000);
  for (int i = 0; i < 3; i++) {
    digitalWrite(BUZZER_PIN, HIGH);
    delay(150);
    digitalWrite(BUZZER_PIN, LOW);
    delay(100);
  }
}

void handleButton() {
  bool pressed = digitalRead(BUTTON_PIN) == LOW;
  unsigned long ms = millis();
  if (pressed && !buttonDownMs) buttonDownMs = ms;
  if (pressed && ms - buttonDownMs >= FACTORY_RESET_HOLD_MS) factoryReset();
  if (!pressed && buttonDownMs) {
    if (ms - buttonDownMs >= SOS_HOLD_MS) sendSos();
    buttonDownMs = 0;
  }
}

// ============================================================================
// GPS
// ============================================================================

void readGps() {
  while (gpsSerial.available()) gps.encode(gpsSerial.read());
  static unsigned long lastUpdate = 0;
  if (millis() - lastUpdate < 1000) return;
  lastUpdate = millis();
  GpsSnapshot fix = {};
  if (gps.location.isValid() && gps.location.age() < 5000) {
    fix.valid = true;
    fix.lat = gps.location.lat();
    fix.lng = gps.location.lng();
    // Rough horizontal accuracy from HDOP (~5 m UERE for a consumer module).
    fix.accuracy = gps.hdop.isValid() ? gps.hdop.hdop() * 5.0f : 25.0f;
  }
  xSemaphoreTake(stateMutex, portMAX_DELAY);
  gpsFix = fix;
  xSemaphoreGive(stateMutex);
}

// ============================================================================
// OLED
// ============================================================================

String nextDoseLabel() {
  if (!timeValid()) return "--:--";
  struct tm now;
  localTime(&now);
  int nowMinutes = now.tm_hour * 60 + now.tm_min;
  int weekdayBit = 1 << (isoWeekday(now) - 1);
  int best = -1;
  xSemaphoreTake(stateMutex, portMAX_DELAY);
  for (int i = 0; i < config.scheduleCount; i++) {
    const Schedule& s = config.schedules[i];
    int start = s.hour * 60 + s.minute;
    if ((s.daysMask & weekdayBit) && start > nowMinutes && (best < 0 || start < best)) best = start;
  }
  xSemaphoreGive(stateMutex);
  if (best < 0) return "none today";
  char buf[6];
  snprintf(buf, sizeof(buf), "%02d:%02d", best / 60, best % 60);
  return buf;
}

void drawScreen() {
  display.clearBuffer();
  display.setFont(u8g2_font_ncenB08_tr);
  unsigned long ms = millis();

  if (setupMode) {
    display.drawStr(0, 10, "Setup mode");
    display.drawStr(0, 24, "Open RemindMeBox app");
    display.drawStr(0, 38, "ID: " DEVICE_ID);
    display.drawStr(0, 52, "Code: " PAIRING_CODE);
  } else if (messageUntilMs && ms < messageUntilMs) {
    display.setFont(u8g2_font_ncenB14_tr);
    display.drawStr(0, 26, messageLine1.c_str());
    display.setFont(u8g2_font_ncenB08_tr);
    display.drawStr(0, 48, messageLine2.c_str());
  } else if (activeDose.active) {
    display.setFont(u8g2_font_ncenB14_tr);
    display.drawStr(0, 18, "TAKE YOUR");
    display.drawStr(0, 36, "PILLS");
    display.setFont(u8g2_font_ncenB08_tr);
    String meds;
    xSemaphoreTake(stateMutex, portMAX_DELAY);
    for (int i = 0; i < activeDose.schedule.doseCount; i++) {
      uint8_t c = activeDose.schedule.doses[i].compartment;
      if (i) meds += ", ";
      if (c <= MAX_COMPARTMENTS && config.medNames[c][0]) {
        meds += config.medNames[c];
      } else {
        meds += "C";
        meds += c;
      }
      meds += " x";
      meds += activeDose.schedule.doses[i].count;
    }
    xSemaphoreGive(stateMutex);
    display.drawStr(0, 50, meds.c_str());
    display.drawStr(0, 62, activeDose.time);
  } else if (buttonDownMs && ms - buttonDownMs >= SOS_HOLD_MS) {
    display.drawStr(0, 20, ms - buttonDownMs < 5000 ? "Release to send SOS" : "Hold to reset WiFi");
  } else {
    char clock[6] = "--:--";
    if (timeValid()) {
      struct tm now;
      localTime(&now);
      snprintf(clock, sizeof(clock), "%02d:%02d", now.tm_hour, now.tm_min);
    }
    display.setFont(u8g2_font_ncenB18_tr);
    display.drawStr(0, 22, clock);
    display.setFont(u8g2_font_ncenB08_tr);
    display.drawStr(80, 10, wifiOnline ? "Online" : "Offline");
    xSemaphoreTake(stateMutex, portMAX_DELAY);
    bool claimed = config.claimed;
    xSemaphoreGive(stateMutex);
    if (!claimed) {
      display.drawStr(0, 40, "Pair in the app:");
      display.drawStr(0, 52, "ID " DEVICE_ID);
      display.drawStr(0, 63, "Code " PAIRING_CODE);
    } else {
      display.drawStr(0, 42, ("Next dose: " + nextDoseLabel()).c_str());
      if (!timeValid()) display.drawStr(0, 56, "Waiting for time...");
    }
  }
  display.sendBuffer();
}

// ============================================================================
// BLE provisioning (setup mode)
// ============================================================================

BLECharacteristic* statusChar = nullptr;
volatile bool credentialsReceived = false;
String pendingSsid, pendingPassword;

void setBleStatus(const char* status) {
  if (!statusChar) return;
  statusChar->setValue(status);
  statusChar->notify();
}

class WifiCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    JsonDocument doc;
    if (deserializeJson(doc, c->getValue().c_str())) {
      setBleStatus("failed");
      return;
    }
    pendingSsid = doc["ssid"] | "";
    pendingPassword = doc["password"] | "";
    credentialsReceived = pendingSsid.length() > 0;
  }
};

void startBleProvisioning() {
  String name = String("RemindMeBox-") + String(DEVICE_ID).substring(max(0, (int)strlen(DEVICE_ID) - 4));
  BLEDevice::init(name.c_str());
  BLEServer* server = BLEDevice::createServer();
  BLEService* service = server->createService(BLE_SERVICE_UUID);

  JsonDocument info;
  info["deviceId"] = DEVICE_ID;
  info["firmware"] = FIRMWARE_VERSION;
  info["compartments"] = COMPARTMENT_COUNT;
  String infoJson;
  serializeJson(info, infoJson);
  BLECharacteristic* infoChar = service->createCharacteristic(BLE_INFO_UUID, BLECharacteristic::PROPERTY_READ);
  infoChar->setValue(infoJson.c_str());

  BLECharacteristic* wifiChar = service->createCharacteristic(BLE_WIFI_UUID, BLECharacteristic::PROPERTY_WRITE);
  wifiChar->setCallbacks(new WifiCallbacks());

  statusChar = service->createCharacteristic(
      BLE_STATUS_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  statusChar->addDescriptor(new BLE2902());
  statusChar->setValue("waiting");

  service->start();
  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(BLE_SERVICE_UUID);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();
  Serial.printf("[ble] advertising as %s\n", name.c_str());
}

void handleProvisioning() {
  if (!credentialsReceived) return;
  credentialsReceived = false;
  setBleStatus("connecting");
  WiFi.mode(WIFI_STA);
  WiFi.begin(pendingSsid.c_str(), pendingPassword.c_str());
  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 20000) delay(250);

  if (WiFi.status() == WL_CONNECTED) {
    prefs.begin("wifi", false);
    prefs.putString("ssid", pendingSsid);
    prefs.putString("password", pendingPassword);
    prefs.end();
    setBleStatus("connected");
    delay(2000);  // let the app read the status before the radio goes away
    ESP.restart();
  } else {
    WiFi.disconnect();
    setBleStatus("failed");
  }
}

// ============================================================================
// Arduino entry points
// ============================================================================

void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT);
  pinMode(BUZZER_PIN, OUTPUT);
  pinMode(PUMP_PIN, OUTPUT);
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  digitalWrite(LED_PIN, LOW);
  digitalWrite(BUZZER_PIN, LOW);
  digitalWrite(PUMP_PIN, LOW);
  analogReadResolution(12);

  stateMutex = xSemaphoreCreateMutex();
  fsMutex = xSemaphoreCreateMutex();
  memset(&config, 0, sizeof(config));
  config.utcOffsetMinutes = 60;
  config.missedDelayMin = 30;

  display.begin();
  rotor.setPeriodHertz(50);
  rotor.attach(SERVO_PIN, 500, 2400);
  rotor.write(CHUTE_ANGLE);
  gpsSerial.begin(GPS_BAUD, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);

  if (!LittleFS.begin(true)) Serial.println("[fs] mount failed");

  prefs.begin("wifi", true);
  String ssid = prefs.getString("ssid", "");
  String password = prefs.getString("password", "");
  prefs.end();

  if (ssid.isEmpty()) {
    setupMode = true;
    startBleProvisioning();
    drawScreen();
    return;
  }

  // Run offline from the last known configuration until the backend answers.
  static DeviceConfig cached;
  if (parseConfig(readFile(CONFIG_FILE), cached)) config = cached;
  loadDone();

  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.begin(ssid.c_str(), password.c_str());
  xTaskCreatePinnedToCore(networkTask, "network", 12288, nullptr, 1, nullptr, 0);
}

void loop() {
  static unsigned long lastDraw = 0, lastScheduler = 0;

  if (setupMode) {
    handleProvisioning();
    if (millis() - lastDraw > 1000) {
      drawScreen();
      lastDraw = millis();
    }
    delay(50);
    return;
  }

  readGps();
  handleButton();
  watchActiveDose();
  if (millis() - lastScheduler >= 1000) {
    runScheduler();
    lastScheduler = millis();
  }
  if (millis() - lastDraw >= 250) {
    drawScreen();
    lastDraw = millis();
  }
  delay(10);
}
