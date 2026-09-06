import type { CollectionConfig } from "payload";
import { auditHooks } from "../lib/audit-hooks";
import { authed } from "../lib/access";

/**
 * Messages (E17.1) — het VERENIGDE bericht-model: één document voedt zowel
 * het in-app-bericht (modal/banner) als de e-mail-nieuwsbrief, met expliciet
 * kanaal, targeting (cohort + app-versie + platform), schedule, rich body,
 * image en CTA.
 *
 * Niet-destructief naast `Announcements`: die collectie blijft bestaan en de
 * macOS-app + `/v1/announcements/*` draaien er nog op tot E17.2 (`/v1/messages`)
 * en E17.3 (`MessagingService`) overstappen. Veldnamen/shape worden 1-op-1
 * door de backend-normalizer gespiegeld (E17.2); hernoemen hier = daar bijwerken.
 *
 * Lifecycle: drafts hebben `schedule.publishedAt = null`. De app-feed geeft
 * alleen gepubliceerde, niet-verlopen docs binnen het kanaal/targeting terug.
 */
export const Messages: CollectionConfig = {
  slug: "messages",
  admin: {
    useAsTitle: "title",
    defaultColumns: ["title", "slug", "channel", "schedule.publishedAt"],
    group: "Messaging",
  },
  access: {
    // Authenticated principals only. The backend reads with a valid Payload
    // API key (`Authorization: users API-Key <key>`), which Payload resolves
    // to `req.user` after validating the key — so `Boolean(req.user)` covers
    // the macOS-app read path. Do NOT also allow on mere header presence: an
    // unvalidated `Authorization: ...` header would have exposed
    // targeting.audienceEmails (end-user PII) to any anonymous caller.
    read: authed,
    create: authed,
    update: authed,
    delete: authed,
  },
  fields: [
    {
      name: "title",
      type: "text",
      required: true,
      admin: { description: "Headline (modal + e-mail). Scanbaar, < ~40 tekens." },
    },
    {
      name: "slug",
      type: "text",
      required: true,
      unique: true,
      admin: {
        description:
          "Stabiele identifier voor 'seen'-state per gebruiker. Na publiceren NIET wijzigen — kies een nieuwe slug om opnieuw te tonen.",
      },
    },
    {
      name: "channel",
      type: "select",
      required: true,
      defaultValue: "inApp",
      options: [
        { label: "In-app only", value: "inApp" },
        { label: "Email only", value: "email" },
        { label: "Both (in-app + email)", value: "both" },
      ],
      admin: {
        description:
          "Waar dit bericht verschijnt. 'email'/'both' ontsluiten de Newsletter-sectie onderaan.",
      },
    },
    {
      name: "body",
      type: "richText",
      admin: { description: "Bericht-body (Lexical). Inline styling + links; block-layouts worden geplat." },
    },
    {
      name: "image",
      type: "upload",
      relationTo: "media",
      admin: { description: "16:9 hero bovenaan modal en e-mail." },
    },
    {
      name: "primaryCta",
      type: "group",
      admin: { description: "Optionele CTA-knop. Beide velden leeg = alleen dismiss." },
      fields: [
        { name: "label", type: "text" },
        { name: "url", type: "text", admin: { description: "Externe URL of `aaavatar://`-deeplink." } },
      ],
    },
    {
      name: "targeting",
      type: "group",
      admin: { description: "Wie krijgt dit bericht (cohort + app-versie + platform)." },
      fields: [
        {
          name: "cohort",
          type: "select",
          required: true,
          defaultValue: "all",
          options: [
            { label: "All users", value: "all" },
            { label: "Free (Starter) users", value: "freeUsers" },
            { label: "Pro users", value: "proUsers" },
            { label: "Specific emails", value: "specificEmails" },
          ],
        },
        {
          name: "audienceEmails",
          type: "array",
          admin: {
            condition: (_, sibling) => sibling?.cohort === "specificEmails",
            description: "Lower-cased + getrimd vóór vergelijking.",
          },
          fields: [{ name: "email", type: "email", required: true }],
        },
        {
          name: "signupAfter",
          type: "date",
          admin: { description: "Alleen accounts aangemaakt ná deze datum (re-engagement/cohort). Leeg = geen ondergrens." },
        },
        {
          name: "signupBefore",
          type: "date",
          admin: { description: "Alleen accounts aangemaakt vóór deze datum. Leeg = geen bovengrens." },
        },
        {
          name: "minAppVersion",
          type: "text",
          admin: { description: "Semver-gate, bv. '2.0.0'. Oudere clients zien dit bericht niet." },
        },
        {
          name: "maxAppVersion",
          type: "text",
          admin: {
            description:
              "Bovengrens (inclusief), bv. '2.0.1'. Alléén clients t/m deze versie zien het bericht — bv. 'installeer de DMG opnieuw' voor 2.0.0/2.0.1 (E13.8). Leeg = geen bovengrens.",
          },
        },
        {
          name: "platform",
          type: "select",
          defaultValue: "all",
          options: [
            { label: "All platforms", value: "all" },
            { label: "macOS", value: "macos" },
          ],
          admin: { description: "Platform-gate (vooruit; nu alleen macOS-client)." },
        },
      ],
    },
    {
      name: "schedule",
      type: "group",
      admin: { description: "Wanneer + hoe vaak." },
      fields: [
        {
          name: "frequency",
          type: "select",
          required: true,
          defaultValue: "once",
          options: [
            { label: "Show once, ever", value: "once" },
            { label: "Show every sign-in until dismissed", value: "everySignInUntilDismissed" },
            { label: "Show until target date", value: "untilDate" },
            { label: "Show on Nth sign-in (delay)", value: "delayedNthSignIn" },
          ],
        },
        {
          name: "untilDate",
          type: "date",
          admin: {
            condition: (_, sibling) => sibling?.frequency === "untilDate",
            description: "Auto-verloopt op deze datum ongeacht dismissal.",
          },
        },
        {
          name: "delayN",
          type: "number",
          admin: {
            condition: (_, sibling) => sibling?.frequency === "delayedNthSignIn",
            description: "Sla de eerste N sign-ins na publish over.",
          },
        },
        {
          name: "publishedAt",
          type: "date",
          admin: { description: "Leeg = draft. Verleden = nu live; toekomst = ingepland." },
        },
        {
          name: "expiresAt",
          type: "date",
          admin: { description: "Verberg uit de feed na dit moment, ongeacht dismiss-state." },
        },
      ],
    },
    {
      name: "badgeTargets",
      type: "array",
      admin: {
        description: "Elke rij schildert een NEW-pill op het gekozen component voor N dagen na publish.",
      },
      fields: [
        {
          name: "componentId",
          type: "relationship",
          relationTo: "badge-components",
          required: true,
        },
        {
          name: "durationDays",
          type: "number",
          required: true,
          defaultValue: 14,
          min: 1,
          max: 365,
        },
      ],
    },
    {
      name: "newsletter",
      type: "group",
      admin: {
        description: "E-mail-distributie. Alleen relevant bij kanaal email/both.",
        condition: (data) => data?.channel === "email" || data?.channel === "both",
      },
      fields: [
        {
          name: "subject",
          type: "text",
          admin: { description: "E-mail-onderwerp. Default = titel." },
        },
        {
          name: "fromName",
          type: "text",
          admin: { description: "From-name. Default = RESEND_FROM_NAME env." },
        },
        {
          name: "customBody",
          type: "richText",
          admin: { description: "Optionele e-mail-only override. Leeg = hergebruik de body." },
        },
        {
          name: "sentAt",
          type: "date",
          admin: {
            readOnly: true,
            description: "Gestempeld bij dispatch. Verzending is idempotent op dit veld.",
          },
        },
      ],
    },
  ],
  hooks: (() => {
    const a = auditHooks<{ title?: string; slug?: string }>(
      "messages",
      (doc) => doc.title ?? doc.slug ?? "(untitled)",
    );
    return {
      afterChange: [a.afterChange],
      afterDelete: [a.afterDelete],
    };
  })(),
};
