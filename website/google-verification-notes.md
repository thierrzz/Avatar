# Google OAuth Verification — Fields to Submit

Google Cloud project: **avatar-493706**
Restricted scope: **`https://www.googleapis.com/auth/drive`**
Console URL: https://console.cloud.google.com/auth/scopes;verificationMode=true?project=avatar-493706

Keep this file up to date — if the browser tab is lost mid-edit, copy the text below back into the form.

---

## What features will you use?

> Drive sync client

(Selected from the multi-select dropdown. Do NOT also select Drive backup or Drive productivity unless Google asks for them.)

---

## How will the scopes be used? (scope justification, max 1000 chars)

```
Aaavatar is a macOS portrait editor that syncs collaborative workspaces to Google Drive. A workspace is a Drive folder containing portrait files, background files, and a workspace.json manifest.

The /auth/drive scope is required for three sync-client functions:

1. Discovering workspaces shared with the signed-in account. drive.file only exposes files the client itself created or opened via Picker, so folders shared via Drive invite remain invisible under drive.file.

2. Bidirectional sync of the full workspace folder contents and polling the Drive Changes API to pick up edits from collaborators on other devices.

3. Inviting and revoking collaborators via permissions.create and permissions.delete on the workspace folder.

Aaavatar never accesses files outside the user-created "Avatar Workspace - *" folders, never writes to Drive outside those folders, and never transmits Drive data to any Aaavatar-operated server.
```

Character count: ~929 / 1000.

---

## Demo video — YouTube link (required, must be filled to enable Save)

Record a ~2–3 min screen recording on macOS. Public or unlisted YouTube URL both work. The video **must** show:

1. The Aaavatar app name and logo
2. A fresh sign-in flow where the OAuth consent screen appears, with the `/auth/drive` scope visible in the consent dialog
3. Each feature that uses the scope:
   - Creating a workspace → a new `Avatar Workspace - <name>` folder appears in Drive
   - Inviting a collaborator via the invite sheet → invitation email arrives in invitee's inbox
   - Invitee clicks the `avatar://join` link → workspace appears in their Aaavatar
   - Editing a portrait on one side, watching it sync to the other
   - Member list + revoke in the workspace settings sheet
4. (Optional but helpful) Brief on-screen captions explaining each step — no voiceover required

Upload to YouTube, copy the link, paste it into the **YouTube link** field on the Data Access page, then click **Save**.

---

## After Save: submit for verification

Once Save succeeds on the Data Access page:
1. Go to **Verification Center** → **Prepare for verification** → **Submit**
2. Google asks for a few days to weeks for restricted-scope review
3. If they request changes, they'll email thierry@squareone.nl

---

## Additional info (optional, 1000 chars)

If the reviewer asks for test credentials, they can test the flow against the public DMG from aaavatar.nl — no special test account is needed because the invite flow works between any two Google accounts.
