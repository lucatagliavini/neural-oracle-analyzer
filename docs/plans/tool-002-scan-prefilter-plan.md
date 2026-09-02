# Piano: TOOL-002 — Pre-filtraggio I/O in `scan_alert_log` con `--since`

## Overview

`scan_alert_log.sh` supera il timeout MCP (~30s lato client Bob/Claude Code) su file di alert log
grandi (>300 MB) perché awk legge l'intero file anche quando `--since` è specificato.
Il filtro `since` oggi è applicato *durante* la lettura awk, non prima.

**Causa root**: su un file da 387 MB, la richiesta "errori nelle ultime 2 settimane" produce
`--since=2026-08-23`, ma awk legge comunque tutti i 387 MB dall'inizio. I dati rilevanti
sono solo negli ultimi ~20 MB.

**Soluzione**: quando `--since` è fornito, usare `grep -n` per trovare la prima riga a partire
dalla data richiesta, poi passare ad awk solo la coda del file con `tail -n +N`.
Riduzione I/O attesa: da 387 MB a ~20 MB (~20× meno dati NFS letti da awk).

**Scope minimo**: solo `scan_alert_log.sh` + vhost Apache (ProxyTimeout).
Nessuna modifica al server MCP, al protocollo, al contratto JSON, agli altri tool.

---

## Sub-task 1 — Pre-filtraggio I/O in `scan_alert_log.sh`

**Intent**: inserire un blocco bash tra `find_alert_log()` e la chiamata awk che, quando
`FILTER_SINCE` è impostato, usa `grep -n` per trovare la prima riga del giorno richiesto
e poi costruisce una pipe `tail -n +N | awk ...` invece di passare il file direttamente.

**Expected Outcomes**:
- Con `--since=2026-08-23` su un file da 387 MB: awk riceve solo la porzione dal
  giorno richiesto in avanti (~20 MB); tempo totale < 5s invece di ~30s
- Senza `--since`: comportamento invariato (awk legge il file intero come oggi)
- Output JSON identico in entrambi i casi — zero cambi al contratto
- `test_contract.sh` passa senza modifiche (il contratto JSON non cambia)

**Todo List**:
1. **Verifica formato timestamp sui log esistenti** (primo step, prima di scrivere il codice):
   - Per un campione di host/istanze del NFS (noprod + prod), leggere le prime 50 righe
     di ciascun alert log e verificare se i timestamp sono in formato ISO
     (`2026-09-01T08:16:43...`) oppure in formato testuale Oracle 11g (`Tue Sep 01 ...`).
   - Comando: `head -50 <alert_log> | grep -cE "^[0-9]{4}-[0-9]{2}-[0-9]{2}"`
   - Questo determina se il probe runtime è necessario o se l'infrastruttura è tutta 12c+.
2. **Aggiungere probe del formato** in `scan_alert_log.sh` (difesa contro log 11g):
   - Prima del blocco di pre-filtraggio, controllare il formato del timestamp
     con un `head -200` sul file: se nessuna riga inizia con `YYYY-MM-DD`, il log
     è in formato testuale (11g) — saltare il pre-filtraggio e usare awk sul file intero
     (il filtro `since` verrà applicato in awk come oggi: nessuna regressione).
3. **Implementare il pre-filtraggio** (attivo solo se formato ISO confermato + `FILTER_SINCE` impostato):
   - `start_line=$(grep -n "^${FILTER_SINCE}" "$LOG_PATH" | head -1 | cut -d: -f1)`
   - Se `start_line` trovato → awk legge solo `<(tail -n +${start_line} "$LOG_PATH")`
   - Se `start_line` vuoto (il range richiesto è oltre la fine del log, es. `--since` futuro
     o log già ruotato prima della data) → output `data: []` direttamente, senza awk.
     Motivazione: se `grep` non trova la data, non ci sono righe nel range — awk non
     troverebbe errori comunque, ma leggerebbe tutto il file inutilmente.
4. **Due branch espliciti** `if/else` per la chiamata awk (non process substitution
   in variabile — gotcha bash: `<(cmd)` salvato in una variabile stringa non funziona
   all'espansione). I due branch sono identici salvo l'ultimo argomento:
   `"$LOG_PATH"` nel branch senza pre-filtraggio, `<(tail -n +N "$LOG_PATH")` nell'altro.

**Relevant Context**:
- File: [`tools/scan_alert_log.sh`](../../tools/scan_alert_log.sh), righe 77–205
- La chiamata awk è a riga 199: `scan_output=$(LC_ALL=C awk ... "$LOG_PATH")`
- `FILTER_SINCE` è già disponibile come variabile bash a quel punto
- Formato timestamp Oracle 12c/19c: `2026-09-01T08:16:43.043810+02:00` → inizia con `YYYY-MM-DD`
- Formato timestamp Oracle 11g: `Tue Sep 01 08:16:43 2026` → non inizia con cifre
- L'infrastruttura ha Oracle 11g, 12c, 19c misti → il probe è necessario
- `grep -n` su NFS è molto più veloce di awk (lettura lineare grezza, nessun parsing)
- **Gotcha bash process substitution**: `<(tail ...)` non funziona salvata in variabile
  e poi espansa — usare due `if/else` espliciti.

**Status**: [x] done

---

## Sub-task 2 — Attivare reverse proxy HTTP su porta 80

**Intent**: il vhost `:80` oggi fa solo redirect → HTTPS (301), ma il vhost `:443`
ha `SSLEngine on` con certificati commentati — non è attivo. Il client MCP parla
direttamente con uvicorn su `:8420`, bypassando Apache.

Convertire il vhost `:80` in un reverse proxy attivo verso uvicorn, con
`ProxyTimeout 300`. Quando il certificato SSL sarà disponibile, il `:80` tornerà
a redirect e il `:443` diventerà il proxy attivo. Il vhost `:443` rimane nel file
come placeholder (commentato o disabilitato).

**Expected Outcomes**:
- `http://neural-mcp-oracle.servizi.gr-u.it/mcp` risponde con JSON-RPC 2.0 (no redirect)
- `ProxyTimeout 300` esplicito — scan_alert_log su file grandi non viene troncato da Apache
- `httpd -t` passa senza errori
- Il vhost `:443` rimane nel file ma non interferisce (SSL commentato → Apache lo ignora
  o lo commentiamo esplicitamente)

**Todo List**:
1. Sostituire il contenuto del vhost `:80` in `etc/httpd/neural-mcp-oracle.conf`:
   - Rimuovere il blocco redirect
   - Aggiungere `ProxyPreserveHost On`, `ProxyRequests Off`
   - `ProxyPass / http://127.0.0.1:8420/` e `ProxyPassReverse`
   - `ProxyTimeout 300` con commento esplicativo
   - Mantenere i log separati (`ErrorLog`, `CustomLog`)
2. Commentare o rimuovere il vhost `:443` (con `SSLEngine on` e certificati mancanti
   Apache su RHEL 9 potrebbe rifiutare di partire se `mod_ssl` è caricato)
3. Deploy + `systemctl reload httpd` sul server
4. Verificare che `curl http://neural-mcp-oracle.servizi.gr-u.it/health` risponda
   `{"status":"ok","service":"neural-oracle-mcp"}` (senza seguire redirect)

**Relevant Context**:
- File: [`etc/httpd/neural-mcp-oracle.conf`](../../etc/httpd/neural-mcp-oracle.conf)
- Il vhost `:443` ha `SSLEngine on` con cert commentati — se `mod_ssl` è caricato,
  Apache può fallire il configtest. Va commentato intero o rimosso temporaneamente.
- `ProxyTimeout` default Apache è 300s, ma renderlo esplicito è corretto per chiarezza
- Quando SSL sarà pronto: ripristinare `:80` come redirect, attivare `:443` con cert

**Status**: [x] done

---

## Sub-task 3 — Test di regressione e validazione

**Intent**: verificare che la modifica a `scan_alert_log.sh` non rompa nulla
e che il pre-filtraggio produca output identico a quello senza pre-filtraggio
(stessi errori, stesso count, stesso JSON).

**Expected Outcomes**:
- `test_contract.sh` passa 525/525 (invariato)
- `test_mcp_tools.sh` passa 65/65 (invariato)
- Un test manuale su SDC1 (PROD, 387 MB) con `--since` mostra tempo < 10s

**Todo List**:
1. Eseguire `bash tests/test_contract.sh --quick` in locale per verifica rapida
2. Dopo deploy, eseguire suite completa su server: `bash tests/test_contract.sh`
3. Eseguire `bash tests/test_mcp_tools.sh`
4. Test manuale di timing su SDC1 PROD (file ~387 MB, `axprracdb03`):
   - `time bash tools/scan_alert_log.sh PROD axprracdb03 SDC1 --since=$(date -d '14 days ago' +%F)`
   - Misurare e confrontare con baseline (~30s+ senza pre-filtraggio)
   - Verificare che l'output JSON sia valido e coerente con una scansione senza pre-filtraggio
     sullo stesso range (spot-check: stesso set di codici ORA-, count ≥ atteso)

**Relevant Context**:
- Test suite: [`tests/test_contract.sh`](../../tests/test_contract.sh),
  [`tests/test_mcp_tools.sh`](../../tests/test_mcp_tools.sh)
- Fixture rilevante: [`tests/fixtures/scan_alert_log.ok.json`](../../tests/fixtures/scan_alert_log.ok.json)
  (usa `axnporadb41/NP41CDB0`, file piccolo — non testa il path con `--since` su file grande)
- Il contratto JSON non cambia: nessun nuovo campo, nessuna modifica all'envelope

**Status**: [x] done — 525/525 bash, 65/65 MCP wire, timing SDC1: 1.4s (era ~30s+)

---

## Sub-task 4 — Aggiornare backlog e session log

**Intent**: chiudere TOOL-002 nel backlog e documentare la sessione.

**Todo List**:
1. In `docs/backlog.md`: spostare TOOL-002 nella sezione "Issue risolte"
2. Scrivere `docs/sessions/2026-09-06-2.md` con riepilogo delle modifiche

**Status**: [-] in progress

---

## Note architetturali

### Perché non streaming/SSE

La soluzione streaming (MCP SSE) è sproporzionata: richiede refactoring del server
FastAPI, cambio del protocollo MCP, e il client Bob/Claude deve supportare SSE.
Il pre-filtraggio risolve il 95% dei casi reali (query con range temporale) con
~20 righe di bash.

### Perché non `--since` di default

Cambiare la semantica di default del tool (scan lifetime → scan 90gg) rompe i
casi d'uso legittimi dove un DBA vuole lo storico completo. Il pre-filtraggio è
trasparente: se non c'è `--since`, il comportamento è identico a oggi.

### Limite residuo

La scansione completa senza `--since` su file >300 MB rimane lenta (~30s+).
Questo è accettabile: è un caso d'uso estremo, il DBA deve usare `--since` per
query storiche su istanze prod attive da anni. Documentare nella descrizione MCP
del tool.
