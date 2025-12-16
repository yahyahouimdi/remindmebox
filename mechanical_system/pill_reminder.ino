#include <Wire.h>
#include <U8g2lib.h>

// OLED setup
U8G2_SH1106_128X64_NONAME_F_HW_I2C u8g2(U8G2_R0);

// Pin definitions
#define IR_PIN A0
#define LED_PIN 2
#define BUZZER_PIN 8

bool previousAlarm = false;

void setup() {
  Serial.begin(9600);
  u8g2.begin();

  pinMode(LED_PIN, OUTPUT);
  pinMode(BUZZER_PIN, OUTPUT);
  
  digitalWrite(LED_PIN, LOW);
  digitalWrite(BUZZER_PIN, LOW);
}

void loop() {
  int sensorValue = analogRead(IR_PIN);
  
  // Avoid division by zero
  float distance = 0;
  if (sensorValue > 20) {
    distance = 4800.0 / (sensorValue - 20);
  }

  bool alarm = (distance > 0 && distance < 30);

  // Serial monitor
  Serial.print("Distance: ");
  Serial.print(distance);
  Serial.print(" cm  Alarm: ");
  Serial.println(alarm);

  // ===== ALARM CONTROL =====
  if (alarm) {
    digitalWrite(LED_PIN, HIGH);
    digitalWrite(BUZZER_PIN, HIGH);
  } else {
    digitalWrite(LED_PIN, LOW);
    digitalWrite(BUZZER_PIN, LOW);
  }

  previousAlarm = alarm;

  // ===== OLED DISPLAY =====
  u8g2.clearBuffer();
  u8g2.setFont(u8g2_font_ncenB08_tr);

  if (alarm) {
    u8g2.drawStr(0, 30, "TAKE THE PILL!");
  } else {
    char buff[20];
    sprintf(buff, "Dist: %.1f cm", distance);
    u8g2.drawStr(0, 30, buff);
  }

  u8g2.sendBuffer();

  delay(200);
}
