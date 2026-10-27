#pragma once

// Copy this file to secrets.h (git-ignored) and paste the values printed by:
//   cd backend/functions && npm run register-device -- --id RMB-0001 --compartments 6 --project <firebase-project-id>
// Each box gets its own ID, secret and pairing code.

#define DEVICE_ID "RMB-0001"
#define DEVICE_SECRET "paste-the-generated-secret-here"
#define PAIRING_CODE "XXXX-XXXX"

// Production:  https://europe-west1-<project-id>.cloudfunctions.net/deviceApi
// Emulator:    http://<your-computer-LAN-ip>:5001/demo-remindmebox/europe-west1/deviceApi
#define API_BASE_URL "https://europe-west1-your-project.cloudfunctions.net/deviceApi"

#define COMPARTMENT_COUNT 6
