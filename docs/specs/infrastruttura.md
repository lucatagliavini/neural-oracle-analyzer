# Specs: Infrastruttura e deploy

## Macchina di riferimento (server MCP)

- Hostname: `lxprworkerlana01`
- FQDN/accesso SSH: `root@lxprworkerlana01.servizi.gr-u.it`
- Accesso corrente: chiavi SSH scambiate, utente `root` — funziona già verso tutti i server destinazione.
- Accesso target (obiettivo): utente `oracle@<server-destinazione>` con chiave SSH dedicata, da scambiare a cura dell'utente. Usare questo quando disponibile (privilegio minimo); in transizione, `root` è il fallback operativo.
- Su questa macchina verrà eseguito il server MCP (esposizione HTTP, FastAPI/Python3, vedi `architettura.md`).
- Non appena esiste codice funzionante, va creato uno script `deploy.sh` per il deployment su questa macchina — non fare deploy manuali una volta che lo script esiste.

## Git

- Il repository è un git interno (non GitHub). Non va inizializzato subito: verrà configurato nel corso del progetto.
- Quando verrà attivato: aggiungere `.gitignore` che escluda env file con credenziali (connection string, API key) prima del primo commit.

## Testing end-to-end

Non appena il servizio MCP è testabile:
- è raggiungibile direttamente da Claude Code (via HTTP, con l'API key configurata) per verificarne le risposte;
- è comunque disponibile anche l'accesso diretto alla macchina via SSH per debug/verifica lato filesystem/processi.

Questi due canali sono complementari: il primo verifica il comportamento "come lo vedrebbe un client MCP", il secondo permette di ispezionare cosa succede realmente sul server (log, processi, permessi).
