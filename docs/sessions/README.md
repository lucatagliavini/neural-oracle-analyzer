# docs/sessions/

Contiene lo storico delle sessioni di lavoro, uno snapshot per continuità tra un giorno e l'altro.

## Regole di gestione

- Un file per sessione, nominato `YYYY-MM-DD.md`. Se ci sono più sessioni nello stesso giorno, usare il suffisso `-2`, `-3`, ecc. (es. `2026-08-27-2.md`).
- Alla fine di ogni sessione di lavoro, scrivere automaticamente il riassunto — senza attendere una richiesta esplicita dell'utente.
- All'inizio di una nuova sessione, leggere il file più recente per sapere da dove riprendere.
- Ogni riassunto dovrebbe contenere: cosa è stato fatto, decisioni prese (e perché), stato attuale del progetto, prossimi passi/cose da riprendere.
- A differenza di `docs/specs/`, questo è uno storico cronologico: non va riscritto o "pulito", ogni file rappresenta un punto nel tempo.
