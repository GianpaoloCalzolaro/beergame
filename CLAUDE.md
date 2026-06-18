# Piano di riscrittura — Migrazione a Vercel + Supabase

> Documento di pianificazione. Descrive **come** riscrivere l'app per girare su
> **Vercel** (hosting + API) e **Supabase** (Postgres + Auth + Realtime),
> sostituendo l'attuale stack **Firebase/GCP**.
>
> Stato: **piano approvato, non ancora implementato.** Nessuna riga di codice
> applicativo è stata ancora migrata.

---

## 1. Obiettivo e scope

**Obiettivo:** sostituire completamente Firebase/GCP con Vercel + Supabase,
riscrivendo il codice. Stesso prodotto, stesse funzionalità, infrastruttura nuova.

**In scope:**
- Frontend SPA (React + Vite) servito da Vercel.
- Backend (logica server) come **Vercel API Routes**.
- Database **Supabase Postgres** + **RLS**.
- **Supabase Auth** (instructor/admin email-password, studenti anonimi).
- Realtime via **Supabase Realtime** (sostituisce i listener `onSnapshot`).

**Fuori scope (deciso col committente):**
- ❌ Nessuna migrazione di dati di produzione (si parte da DB pulito).
- ❌ Nessuna migrazione di utenti esistenti.
- ❌ Firebase **App Check** non viene replicato (perdita accettata; compensata
  con rate-limiting + CAPTCHA in registrazione).
- ❌ Billing kill-switch GCP (Pub/Sub) eliminato; al suo posto i limiti di spesa
  nativi di Supabase/Vercel.

---

## 2. Decisioni architetturali confermate

| # | Decisione | Scelta |
|---|---|---|
| 1 | Dove vive la logica backend | **Vercel API Routes** (Node) |
| 2 | Accesso al DB dal frontend | **Letture/Realtime dal client; tutte le scritture via API** |
| 3 | Game-loop (avanzamento turni) | **Resta nel browser dell'host**, come oggi |
| 4 | Ruoli/stato utente | **Tabella `profiles` + RLS** (no custom claims) |
| 5 | Email approvazione instructor | **SMTP2GO** (invariato, chiamato via REST da un endpoint) |
| 6 | Job periodici (cleanup) | **`pg_cron`** dentro Supabase |
| 7 | Anti-abuso | **Rate-limiting** (porting di `enforceRateLimit`) + **CAPTCHA** in registrazione |
| 8 | Modellazione mappe per-ruolo | **Colonne `jsonb`** (vicino al modello attuale) |
| 9 | Bootstrap primo admin | **Seed** nelle migrazioni Supabase |

---

## 3. Stack: prima → dopo

| Componente | Oggi (Firebase/GCP) | Domani (Vercel + Supabase) |
|---|---|---|
| Hosting frontend | Firebase Hosting | **Vercel** (preset Vite, output `dist/`) |
| Backend | Cloud Functions v2 (`onCall`) | **Vercel API Routes** (`/api/*`) |
| Database | Cloud Firestore (NoSQL) | **Supabase Postgres** |
| Autorizzazione | `firestore.rules` | **RLS Postgres** |
| Realtime | `onSnapshot` (Web SDK) | **Supabase Realtime** (`postgres_changes`) |
| Auth | Firebase Auth + custom claims | **Supabase Auth** + tabella `profiles` |
| Anti-bot | App Check (reCAPTCHA v3) | Rate-limit + CAPTCHA (App Check rimosso) |
| Job schedulati | `onSchedule` Cloud Functions | **`pg_cron`** |
| Email | SMTP2GO | SMTP2GO (invariato) |
| Kill-switch costi | Pub/Sub + Cloud Billing | Rimosso (spending cap nativi) |
| Logica di gioco | `src/logic/*` | **Riutilizzata as-is** |

---

## 4. Schema dati proposto (descrittivo)

Traduzione del modello a documenti Firestore in tabelle Postgres. Le mappe
per-ruolo restano `jsonb` per minimizzare il delta col codice attuale.

- **`profiles`** — un record per utente autenticato.
  `id (uuid, FK auth.users)`, `email`, `name`, `institution`, `country`,
  `role ('admin'|'instructor')`, `status ('pending'|'approved'|'rejected'|'revoked')`,
  `email_verified`, `reviewed_by`, `reviewed_at`, `created_at`,
  `sessions_created_count`, `players_joined_count`.

- **`games`** — una sessione.
  `code (text PK, 4-8 char)`, `status ('lobby'|'in_progress'|'ended')`,
  `owner_instructor_id (FK profiles)`, `owner_instructor_email`,
  `config (jsonb)`, `notes`, `human_join_count`, `created_at`,
  `expires_at (timestamptz)`.

- **`players`** — `id (uuid PK)`, `game_code (FK games ON DELETE CASCADE)`,
  `name`, `normalized_name`, `role`, `team_id`, `is_robot`,
  `session_token_hash`, `last_heartbeat_at`, `removed_at`, `removed_by`,
  `created_at`.

- **`teams`** — `id (text)`, `game_code (FK games ON DELETE CASCADE)`,
  `name`, `current_week`, `human_count`,
  `stages (jsonb)`, `pending_orders (jsonb)`, `orders_submitted (jsonb)`.
  PK composta `(game_code, id)`.

- **`player_names`** — lock unicità nome.
  `game_code`, `normalized_name`, `player_id`, `created_at`.
  Vincolo **`UNIQUE(game_code, normalized_name)`** (sostituisce il lock-doc Firestore).

- **`rate_limits`** — `key (PK)`, `count`, `window_start`, `updated_at`.

- **`email_quota`** — `day_key (PK)`, `count`, `updated_at`.

**Note di traduzione (cosa Firestore dava "gratis" e come si replica):**
- Cancellazione ricorsiva sessione → **`ON DELETE CASCADE`** sulle FK.
- Incremento atomico contatori → `UPDATE ... SET x = x + 1`.
- `serverTimestamp()` → `default now()`.
- Transazioni → transazioni Postgres (negli endpoint con service role).
- Lock unicità nome → vincolo `UNIQUE`.

---

## 5. Autorizzazione (RLS)

Le `firestore.rules` attuali si traducono in policy RLS. Principi:
- **Letture dal client** abilitate via RLS (necessario per il Realtime).
  - `profiles`: un utente legge il proprio; admin legge tutti.
  - `games`/`players`/`teams`: leggibili dal proprietario (instructor) o se il
    gioco è "pubblicamente leggibile" (status valido e non scaduto), come oggi.
- **Scritture dal client: bloccate da RLS.** Tutte le scritture passano dagli
  endpoint server con **service role** (che bypassa RLS) dopo validazione.
- Helper RLS da ricreare: `is_admin()`, `is_approved_instructor()`,
  `owns_game(code)`, `is_public_readable(game)`.

---

## 6. Backend: mappatura endpoint

Le 8 Cloud Functions `onCall` diventano API Routes Vercel (`/api/...`),
autenticate col JWT Supabase e con validazione input equivalente.

| Cloud Function attuale | Nuovo endpoint Vercel | Note |
|---|---|---|
| `ensureAdminProfile` | `POST /api/admin/ensure-profile` | Bootstrap admin via `ADMIN_EMAIL` |
| `submitInstructorApplication` | `POST /api/instructor/apply` | + rate-limit + CAPTCHA |
| `syncEmailVerified` | `POST /api/instructor/sync-email` | Invia email admin via SMTP2GO |
| `adminReviewInstructor` | `POST /api/admin/review` | approve/reject + email |
| `adminRevokeInstructor` | `POST /api/admin/revoke` | |
| `adminDeleteInstructor` | `POST /api/admin/delete` | solo rejected |
| `createSession` | `POST /api/sessions/create` | `sanitizeConfig`, genera code |
| `deleteSession` | `POST /api/sessions/delete` | cascade delete |
| `joinOrResumePlayer` | `POST /api/players/join` | transazione + assegnazione ruolo |
| `submitPlayerOrder` | `POST /api/players/order` | validazione token sessione |
| `heartbeatPlayer` | `POST /api/players/heartbeat` | aggiorna `last_heartbeat_at` |

**Job schedulati (oggi `onSchedule`) → `pg_cron`:**
- `cleanupExpiredSessions` → query settimanale che cancella `games` scaduti (cascade).
- `cleanupOrphanAuthUsers` → adattato al modello Auth Supabase + pulizia `rate_limits`.

**Game-loop:** invariato lato concetto — l'host calcola il turno nel browser
(`computeOrdersForWeek` + `simulateWeek`) ma **scrive il risultato via endpoint**
(`POST /api/sessions/advance-week`) invece che con `writeBatch` diretto.

---

## 7. Realtime

Sostituzione dei listener `onSnapshot` con canali Supabase Realtime su
`postgres_changes`:
- **HostLobby:** lista sessioni proprie, dettaglio gioco, players, teams.
- **PlayerView:** documento gioco, proprio player, proprio team.
- **AdminDashboard:** lista instructors.

Attenzioni:
- Realtime invia **diff di riga**, non lo stato completo → adattare la logica di
  merge locale rispetto al pattern Firestore.
- Le RLS si applicano anche al Realtime → le policy di lettura devono permettere
  gli eventi necessari.
- Dimensionare connessioni/canali concorrenti sul piano Supabase scelto.

---

## 8. Auth

- **Supabase Auth (GoTrue):** email/password per instructor e admin; **anonymous
  sign-in** per gli studenti (sostituisce `signInAnonymously`).
- **Ruoli/stato** in tabella `profiles` (no custom claims). Le RLS e gli endpoint
  leggono ruolo/stato da lì.
- **Bootstrap admin:** seed in migrazione + endpoint `ensure-profile` che promuove
  ad admin chi accede con l'email configurata (`ADMIN_EMAIL`).
- **Cleanup anonimi orfani:** ridisegnato su `pg_cron` + API Admin Supabase.

---

## 9. Variabili d'ambiente (target)

**Frontend (Vercel, build-time `VITE_*`):**
- `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`.
- (Rimosse: tutte le `VITE_FIREBASE_*`, `VITE_RECAPTCHA_*`, `VITE_APPCHECK_*`.)

**Backend (Vercel, server-side):**
- `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_URL`.
- `SMTP2GO_API_KEY`, `MAIL_FROM`, `ADMIN_EMAIL`, `APP_BASE_URL`.
- Eventuale `CAPTCHA_SECRET`.

---

## 10. Piano in fasi

### Fase 0 — Prerequisiti
- [ ] Introdurre CI minima (lint + `tsc` + Playwright) — oggi assente.
- [ ] Setup progetto Supabase + stack locale (CLI) per sviluppare RLS/migrazioni.
- [ ] Setup progetto Vercel collegato al repo.

### Fase 1 — Database & Auth
- [ ] Migrazioni schema (sezione 4) + seed admin.
- [ ] Policy RLS (sezione 5) con test.
- [ ] Configurare Supabase Auth (email/password + anonimo + CAPTCHA).

### Fase 2 — Backend (Vercel API)
- [ ] Riscrivere i 11 endpoint (sezione 6) con service role + validazione.
- [ ] Porting di `enforceRateLimit` e quota email.
- [ ] `pg_cron` per i cleanup.

### Fase 3 — Frontend
- [ ] Sostituire `src/firebase.ts` con client Supabase.
- [ ] Riscrivere `src/api.ts` (chiamate HTTP agli endpoint Vercel).
- [ ] Convertire i listener `onSnapshot` → Supabase Realtime
      (`App`, `HostLobby`, `PlayerView`, `AdminDashboard`).
- [ ] Adattare le scritture dirette dell'host a chiamate API.
- [ ] Rimuovere App Check / reCAPTCHA dal codice.
- [ ] `src/logic/*` invariato (verificare solo gli import).

### Fase 4 — Deploy & dismissione
- [ ] Config Vercel (build `tsc -b && vite build`, output `dist`, rewrite SPA).
- [ ] Smoke test E2E (riusare/aggiornare `tests/`).
- [ ] Rimuovere artefatti Firebase (`firebase.json`, `.firebaserc`,
      `firestore.*`, cartella `functions/`).
- [ ] Aggiornare `Howtohost.md` per il nuovo stack.

---

## 11. File impattati (riferimento)

**Da riscrivere:** `src/firebase.ts`, `src/api.ts`, `functions/` (intera),
`src/components/{HostLobby,PlayerView,AdminDashboard,App}.tsx`,
`firestore.rules`, `firestore.indexes.json`, `firebase.json`, `.firebaserc`.

**Da riutilizzare (poco/nessun cambiamento):** `src/logic/*`
(`gameEngine`, `gameModel`, `robotOrders`, `endgameAnalytics`, `teamNames`),
`src/utils/*` (export PDF/CSV), `src/components/charts/*`.

**Da aggiornare:** `Howtohost.md`, `.env.example`, `package.json`
(rimuovere `firebase`, aggiungere `@supabase/supabase-js`).

---

## 12. Rischi e mitigazioni

| Rischio | Mitigazione |
|---|---|
| RLS scritte male = falle di sicurezza | Test espliciti per ruolo; scritture solo via service role |
| Semantica Realtime diversa da `onSnapshot` | Adattare merge locale; test su lobby/presenza/turni |
| Perdita App Check (abusi via script) | Rate-limit + CAPTCHA registrazione (accettato) |
| Limiti connessioni Realtime su sessioni grandi | Dimensionare il piano Supabase |
| Game-loop fragile (host browser) | Mantenuto come oggi in v1; valutare server-side in seguito |
| Assenza CI durante riscrittura ampia | Introdurre CI in Fase 0 |

---

## 13. Note per Claude (sviluppo)

- **Branch di lavoro:** `claude/bold-thompson-mdgsgn`.
- **Non reintrodurre** dipendenze Firebase/GCP.
- La **logica di gioco** in `src/logic/*` è autorevole e va preservata: non
  reimplementarla, solo ricollegarla ai nuovi data layer.
- Ogni **scrittura** deve passare da un endpoint server; il client fa solo
  letture/Realtime.
