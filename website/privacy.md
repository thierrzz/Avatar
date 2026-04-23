# Privacy Policy

_Last updated: 20 April 2026_

Avatar is a macOS application published by **Square One** (the Netherlands, info@squareone.nl). This Privacy Policy explains what data Avatar handles, how it is used, and the rights you have. It applies to the Avatar macOS app and the website [https://aaavatar.nl](https://aaavatar.nl).

If you have any questions, contact us at **info@squareone.nl**.

---

## 1. Summary

Avatar is a local-first portrait editor. We do **not** run a backend. We do **not** collect your data on our servers. When you choose to use a shared workspace, your portraits and backgrounds are stored in **your own Google Drive**, under your account, and synchronised peer-to-peer through Google's APIs. Nothing passes through Square One.

---

## 2. Data Avatar handles

### 2.1 On your Mac

Avatar stores the following locally on your device, using Apple's SwiftData framework:

- Portrait images you import (originals and AI-generated cutouts)
- Background images and presets
- Export presets
- App preferences (language, last-opened workspace, UI state)

This data never leaves your Mac unless you explicitly enable a Google Drive workspace or export a library archive yourself.

### 2.2 In your Google Drive (optional)

When you create or join a shared workspace, Avatar uses the Google Drive API to store the following **inside a folder you own in your own Google Drive**:

- A folder named `Avatar Workspace - <name>` at a location you choose
- A `workspace.json` file with the workspace name, creation date, and creator email
- Portrait packages (`.avatarportrait`) and background packages (`.avatarbg`) inside `portraits/` and `backgrounds/` subfolders
- Permissions you grant to collaborators through Avatar's invite flow

We never receive a copy of any of this data. It lives exclusively in your and your collaborators' Google Drives.

### 2.3 Automatic updates

Avatar checks for application updates through the [Sparkle](https://sparkle-project.org/) framework by fetching an appcast file from GitHub. Your IP address and basic HTTP metadata may be logged by GitHub when this check happens. We do not receive that data.

---

## 3. How Avatar uses Google user data

Avatar requests the following Google OAuth scope:

- `https://www.googleapis.com/auth/drive` — read/write access to files in your Google Drive

This scope is used **only** to:

1. Create and manage the `Avatar Workspace - <name>` folders you explicitly create
2. Read and write portrait and background files inside those workspace folders
3. Detect workspace folders that other users have shared with the Google account you signed in with, so that shared workspaces appear in Avatar automatically
4. Send Google Drive sharing invitations on your behalf when you click **Invite** in Avatar
5. List, and at your request revoke, the access other people have to a workspace folder

Avatar does **not** read, modify, or index any other files in your Google Drive. Avatar does **not** upload your Google data to any server operated by Square One or any third party.

### 3.1 Google API Services User Data – Limited Use

Avatar's use and transfer of information received from Google APIs to any other app adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the **Limited Use** requirements. In particular:

- We use Google user data only to provide user-facing features within Avatar.
- We do not use Google user data for serving advertisements.
- We do not allow humans to read the data except (a) with your explicit consent, (b) for security purposes such as investigating abuse, (c) to comply with applicable law, or (d) for internal operations where the data has been aggregated and anonymised.
- We do not transfer Google user data to third parties except as necessary to provide or improve user-facing features, comply with applicable law, or as part of a merger, acquisition, or sale of assets with user notice.

---

## 4. Local authentication data

When you sign in with Google, Avatar stores your OAuth access and refresh tokens in the macOS Keychain on your Mac, via Google's GoogleSignIn SDK. These tokens never leave your Mac. You can revoke them at any time by signing out inside Avatar or at [https://myaccount.google.com/permissions](https://myaccount.google.com/permissions).

---

## 5. Data retention and deletion

- **Local data** stays on your Mac for as long as you keep Avatar installed. Quitting Avatar and deleting its app container removes all local portraits, backgrounds, and preferences.
- **Drive data** stays in your Google Drive until you delete it. Removing a workspace folder from Drive removes all associated data.
- **Authentication tokens** are removed from the Keychain when you sign out inside Avatar.
- We do not keep backups of your Google data, because we never receive it.

To revoke Avatar's access to your Google account at any time, visit [https://myaccount.google.com/permissions](https://myaccount.google.com/permissions) and remove Avatar.

---

## 6. Third parties

Avatar uses the following third-party services. None of them receive your portraits or workspace data unless the service is essential to the feature you are using:

| Service | Purpose | Data it sees |
|---|---|---|
| Google Drive API | Workspace storage & sharing | Your portraits, backgrounds, and workspace metadata (stored in your Drive) |
| Google Sign-In | Authentication | Your Google email, name, profile picture |
| GitHub (appcast) | Update checks | IP address, HTTP metadata |
| Sparkle framework | In-app updater | No data sent externally |

We do not use analytics, crash reporting, or advertising SDKs.

---

## 7. Children's privacy

Avatar is not directed at children under 13 and we do not knowingly collect information from them.

---

## 8. International users

Avatar is published from the Netherlands. By installing Avatar and signing in with Google, you acknowledge that authentication flows and Drive storage will involve Google's infrastructure, which may process data internationally under [Google's own terms](https://policies.google.com/privacy).

---

## 9. Your rights under the GDPR

If you are in the European Economic Area, you have the right to:

- access the personal data Avatar has about you (your Google email, name, and profile picture cached locally in the app);
- have that data corrected or deleted (sign out inside Avatar);
- withdraw consent for Google account access at any time ([Google account permissions](https://myaccount.google.com/permissions));
- lodge a complaint with a supervisory authority, in the Netherlands the [Autoriteit Persoonsgegevens](https://autoriteitpersoonsgegevens.nl).

Square One does not operate any server-side storage of your personal data, so requests under the GDPR are generally resolved by signing out of Avatar and revoking access in your Google account.

---

## 10. Changes to this policy

We may update this policy when the app changes or when legal requirements change. The date at the top of this page shows when it was last updated. Material changes will be highlighted in the Avatar release notes.

---

## 11. Contact

**Square One**
The Netherlands
**info@squareone.nl**

For data-protection questions, use the same email.
