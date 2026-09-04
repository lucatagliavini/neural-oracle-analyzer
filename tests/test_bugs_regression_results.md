# Risultati test di regressione bug — Neural Oracle Analyzer

**Data**: 2026-09-04 11:55:01 UTC
**Ambiente**: TEST / axnporadb41
**Istanze**: NP41CDB0, NP41CDB1, NP41CDB2

| Totale | Passati | Falliti | Saltati |
|---|---|---|---|
| 113 | 58 | 41 | 14 |

## ⚠️ Fallimenti


- ❌ BUG-08/NP41CDB0: status=error (atteso ok)
- ❌ BUG-08/NP41CDB1: status=error (atteso ok)
- ❌ BUG-08/NP41CDB2: status=error (atteso ok)
- ❌ BUG-01/default: status=error (atteso ok)
- ❌ BUG-01/limit5: status=error (atteso ok)
- ❌ BUG-03+09/NP41CDB1: status=error (atteso ok)
- ❌ BUG-03: db_recovery_file_dest='null' (len=4, sospetto troncamento)
- ❌ BUG-03: fra_size ha 0 righe su istanza senza FRA (atteso ≥2)
- ❌ BUG-02/NP41CDB1: sezione fra_status MANCANTE
- ❌ BUG-02/NP41CDB1: fra_configured='null' (atteso true)
- ❌ BUG-02/NP41CDB1: db_recovery_file_dest vuoto in fra_status
- ❌ BUG-02/NP41CDB0: fra_configured='null' (atteso false)
- ❌ BUG-02/NP41CDB2: fra_configured='null' (atteso false)
- ❌ BUG-13: status=error (atteso ok)
- ❌ BUG-13: .data | length=0 non > 0
- ❌ BUG-04/full: full_scan_performed='null' (atteso true)
- ❌ BUG-04/since: full_scan_performed='null' (atteso false)
- ❌ BUG-15: status=error (atteso ok)
- ❌ BUG-15: .data[0].io_collected non è un bool → 'null'
- ❌ BUG-07/scan_alert_log: oracle_version='null' (atteso n/a)
- ❌ BUG-07/list_known_hosts: oracle_version='null' (atteso n/a)
- ❌ BUG-07/list_all_hosts_and_instances: oracle_version='null' (atteso n/a)
- ❌ BUG-07/get_alert_log_info: oracle_version='null' (atteso n/a)
- ❌ BUG-07/tail_alert_log: oracle_version='null' (atteso n/a)
- ❌ BUG-07/list_known_instances: oracle_version='null' (atteso n/a)
- ❌ BUG-12/user: status=error (atteso ok)
- ❌ BUG-12/machine: status=error (atteso ok)
- ❌ BUG-12/user: scope='null' (atteso user_sessions)
- ❌ BUG-12/machine: scope='null' (atteso all_sessions)
- ❌ BUG-12/user: total_user_sessions='null' non è un numero positivo
- ❌ BUG-12/machine: total_all_sessions='null' non è un numero positivo
- ❌ BUG-06: status=error (atteso ok)
- ❌ BUG-06: .data | length=0 non > 0
- ❌ BUG-06: nessuna istanza resident=true (attesi NP41CDB0/1/2)
- ❌ diagnose_instance/NP41CDB0: .status = 'error' (atteso 'ok')
- ❌ diagnose_instance/NP41CDB0: .summary.stato_generale è null/vuoto
- ❌ diagnose_instance/NP41CDB0: .data array vuoto o assente
- ❌ diagnose_instance/NP41CDB1: .status = 'error' (atteso 'ok')
- ❌ diagnose_instance/NP41CDB1: .summary.stato_generale è null/vuoto
- ❌ diagnose_instance/NP41CDB1: .data array vuoto o assente
- ❌ check_memory_pressure: .summary.distribuzione_per_pdb array vuoto o assente

## Dettaglio test


### BUG-08 — check_resource_limits: denominatore = limit_value, non max_utilization
| Stato | Test |
|---|---|
| ✅ | `BUG-08/NP41CDB0: output è JSON valido` |
| ❌ | `BUG-08/NP41CDB0: status=error (atteso ok)` |
| ✅ | `BUG-08/NP41CDB1: output è JSON valido` |
| ❌ | `BUG-08/NP41CDB1: status=error (atteso ok)` |
| ✅ | `BUG-08/NP41CDB2: output è JSON valido` |
| ❌ | `BUG-08/NP41CDB2: status=error (atteso ok)` |

### BUG-11 — scan_alert_log: normalizzazione zero-padding (ORA-4036 → ORA-04036)
| Stato | Test |
|---|---|
| ✅ | `BUG-11/ORA-04036: output è JSON valido` |
| ✅ | `BUG-11/ORA-4036: output è JSON valido` |
| ✅ | `BUG-11: --code=ORA-04036 e --code=ORA-4036 trovano stessi gruppi (0)` |
| ⏭ | `SKIP: BUG-11: nessun ORA-04036 trovato su NP41CDB1 dal 2025-01-01 (log non disponibile o assente)` |
| ✅ | `BUG-11/ORA-00020: output è JSON valido` |
| ✅ | `BUG-11/ORA-20: output è JSON valido` |
| ✅ | `BUG-11: ORA-00020 e ORA-20 trovano stessi gruppi (0)` |

### BUG-10 — scan_alert_log: ORA-00020 e ORA-04036 con severity=critical
| Stato | Test |
|---|---|
| ✅ | `BUG-10/ORA-00020: output è JSON valido` |
| ⏭ | `SKIP: BUG-10/ORA-00020: nessuna occorrenza nel log (ok se mai capitato)` |
| ✅ | `BUG-10/ORA-04036: output è JSON valido` |
| ⏭ | `SKIP: BUG-10/ORA-04036: nessuna occorrenza dal 2025-01-01 (log ruotato o istanza riavviata)` |
| ✅ | `BUG-10/ORA-01692: output è JSON valido` |
| ⏭ | `SKIP: BUG-10/ORA-01692: nessuna occorrenza su NP41CDB0` |

### BUG-01 — pga_by_pdb_session: --limit riduce payload
| Stato | Test |
|---|---|
| ✅ | `BUG-01/default: output è JSON valido` |
| ❌ | `BUG-01/default: status=error (atteso ok)` |
| ✅ | `BUG-01/default: data.length=0 ≤ 50 (limit default rispettato)` |
| ✅ | `BUG-01/limit5: output è JSON valido` |
| ❌ | `BUG-01/limit5: status=error (atteso ok)` |
| ✅ | `BUG-01/limit5: data.length=0 ≤ 5` |
| ✅ | `BUG-01/order: output è JSON valido` |

### BUG-03+09 — check_fra_usage: v$parameter (no wrapping) + space_limit come intero
| Stato | Test |
|---|---|
| ✅ | `BUG-03+09/NP41CDB1: output è JSON valido` |
| ❌ | `BUG-03+09/NP41CDB1: status=error (atteso ok)` |
| ✅ | `BUG-03: nessuna riga spuria name=null in fra_size` |
| ❌ | `BUG-03: db_recovery_file_dest='null' (len=4, sospetto troncamento)` |
| ⏭ | `SKIP: BUG-09: space_limit null/assente in fra_dest (FRA assente su questa istanza?)` |
| ✅ | `BUG-03+09/NP41CDB0_noFRA: output è JSON valido` |
| ❌ | `BUG-03: fra_size ha 0 righe su istanza senza FRA (atteso ≥2)` |

### BUG-02 — check_fra_usage: sezione fra_status con fra_configured esplicito
| Stato | Test |
|---|---|
| ✅ | `BUG-02/NP41CDB1: output è JSON valido` |
| ❌ | `BUG-02/NP41CDB1: sezione fra_status MANCANTE` |
| ❌ | `BUG-02/NP41CDB1: fra_configured='null' (atteso true)` |
| ❌ | `BUG-02/NP41CDB1: db_recovery_file_dest vuoto in fra_status` |
| ✅ | `BUG-02/NP41CDB0: output è JSON valido` |
| ❌ | `BUG-02/NP41CDB0: fra_configured='null' (atteso false)` |
| ✅ | `BUG-02/NP41CDB2: output è JSON valido` |
| ❌ | `BUG-02/NP41CDB2: fra_configured='null' (atteso false)` |

### BUG-13 — pga_by_pdb_session: sessioni CDB$ROOT incluse (LEFT OUTER JOIN)
| Stato | Test |
|---|---|
| ✅ | `BUG-13: output è JSON valido` |
| ❌ | `BUG-13: status=error (atteso ok)` |
| ⏭ | `SKIP: BUG-13: nessuna sessione CDB$ROOT trovata (possibile se tutti gli utenti sono su PDB)` |
| ❌ | `BUG-13: .data | length=0 non > 0` |

### BUG-14 — runbook_ora04030: cerca ORA-04036, no falso negativo su NP41CDB1
| Stato | Test |
|---|---|
| ✅ | `BUG-14: output è JSON valido` |
| ✅ | `BUG-14: .status = ok` |
| ⏭ | `SKIP: BUG-14: eventi_ora04036=0 (log ruotato? attesi ≥56)` |
| ✅ | `BUG-14: sezione scan_alert_log_ora04036 presente nei dati` |
| ⏭ | `SKIP: BUG-14/BUG-05: log_start_date=null (log 11g puro o --since impostato)` |

### BUG-05 — scan_alert_log: log_start_date nell'envelope top-level
| Stato | Test |
|---|---|
| ✅ | `BUG-05/con-since: output è JSON valido` |
| ✅ | `BUG-05/con-since: log_start_date=null quando --since è impostato` |
| ✅ | `BUG-05/senza-since: output è JSON valido` |
| ⏭ | `SKIP: BUG-05/senza-since: log_start_date=null (log 11g puro o NFS assente)` |

### BUG-04 — scan_alert_log: full_scan_performed nell'envelope
| Stato | Test |
|---|---|
| ✅ | `BUG-04/full: output è JSON valido` |
| ❌ | `BUG-04/full: full_scan_performed='null' (atteso true)` |
| ✅ | `BUG-04/since: output è JSON valido` |
| ❌ | `BUG-04/since: full_scan_performed='null' (atteso false)` |

### BUG-15 — os_disk_stats: io_collected distinto da io_available
| Stato | Test |
|---|---|
| ✅ | `BUG-15: output è JSON valido` |
| ❌ | `BUG-15: status=error (atteso ok)` |
| ❌ | `BUG-15: .data[0].io_collected non è un bool → 'null'` |
| ✅ | `BUG-15: io_available=null, io_collected=null (distinti)` |
| ✅ | `BUG-15/orchestration: output è JSON valido` |
| ✅ | `BUG-15/orchestration: disk_io_await_p95_ms='null' (null o numero, non zero falso)` |

### BUG-07 — Tool NFS: oracle_version = "n/a" invece di null
| Stato | Test |
|---|---|
| ✅ | `BUG-07/scan_alert_log: output è JSON valido` |
| ❌ | `BUG-07/scan_alert_log: oracle_version='null' (atteso n/a)` |
| ✅ | `BUG-07/list_known_hosts: output è JSON valido` |
| ❌ | `BUG-07/list_known_hosts: oracle_version='null' (atteso n/a)` |
| ✅ | `BUG-07/list_all_hosts_and_instances: output è JSON valido` |
| ❌ | `BUG-07/list_all_hosts_and_instances: oracle_version='null' (atteso n/a)` |
| ✅ | `BUG-07/get_alert_log_info: output è JSON valido` |
| ❌ | `BUG-07/get_alert_log_info: oracle_version='null' (atteso n/a)` |
| ✅ | `BUG-07/tail_alert_log: output è JSON valido` |
| ❌ | `BUG-07/tail_alert_log: oracle_version='null' (atteso n/a)` |
| ✅ | `BUG-07/list_known_instances: output è JSON valido` |
| ❌ | `BUG-07/list_known_instances: oracle_version='null' (atteso n/a)` |

### BUG-12 — sessions_by_user/machine: scope e totali per riconciliazione
| Stato | Test |
|---|---|
| ✅ | `BUG-12/user: output è JSON valido` |
| ✅ | `BUG-12/machine: output è JSON valido` |
| ❌ | `BUG-12/user: status=error (atteso ok)` |
| ❌ | `BUG-12/machine: status=error (atteso ok)` |
| ❌ | `BUG-12/user: scope='null' (atteso user_sessions)` |
| ❌ | `BUG-12/machine: scope='null' (atteso all_sessions)` |
| ❌ | `BUG-12/user: total_user_sessions='null' non è un numero positivo` |
| ❌ | `BUG-12/machine: total_all_sessions='null' non è un numero positivo` |

### BUG-06 — list_known_instances: campo resident distingue istanze RAC non residenti
| Stato | Test |
|---|---|
| ✅ | `BUG-06: output è JSON valido` |
| ❌ | `BUG-06: status=error (atteso ok)` |
| ❌ | `BUG-06: .data | length=0 non > 0` |
| ✅ | `BUG-06: tutti i 0 record hanno il campo resident` |
| ❌ | `BUG-06: nessuna istanza resident=true (attesi NP41CDB0/1/2)` |
| ⏭ | `SKIP: BUG-06: nessuna istanza resident=false (mount NFS potrebbe non avere cross-mount RAC)` |

### ORCHESTRAZIONE — diagnose_instance: integrazione completa su NP41CDB0 e NP41CDB1
| Stato | Test |
|---|---|
| ✅ | `diagnose_instance/NP41CDB0: output è JSON valido` |
| ❌ | `diagnose_instance/NP41CDB0: .status = 'error' (atteso 'ok')` |
| ❌ | `diagnose_instance/NP41CDB0: .summary.stato_generale è null/vuoto` |
| ❌ | `diagnose_instance/NP41CDB0: .data array vuoto o assente` |
| ⏭ | `SKIP: diagnose_instance/NP41CDB0: nessuna criticità trovata (sistema scarico)` |
| ⏭ | `SKIP: diagnose_instance/NP41CDB0: pdbs non disponibili (Oracle 11g?)` |
| ✅ | `diagnose_instance/NP41CDB1: output è JSON valido` |
| ❌ | `diagnose_instance/NP41CDB1: .status = 'error' (atteso 'ok')` |
| ❌ | `diagnose_instance/NP41CDB1: .summary.stato_generale è null/vuoto` |
| ❌ | `diagnose_instance/NP41CDB1: .data array vuoto o assente` |
| ⏭ | `SKIP: diagnose_instance/NP41CDB1: nessuna criticità trovata (sistema scarico)` |
| ⏭ | `SKIP: diagnose_instance/NP41CDB1: pdbs non disponibili (Oracle 11g?)` |

### ORCHESTRAZIONE — check_memory_pressure: BUG-01+13 (limit e CDB$ROOT)
| Stato | Test |
|---|---|
| ✅ | `check_memory_pressure: output è JSON valido` |
| ✅ | `check_memory_pressure: .status = ok` |
| ✅ | `check_memory_pressure: .summary.livello_pressione non è null (bassa)` |
| ✅ | `check_memory_pressure: .summary.sessione_top_pga non è null (Nessuna sessione rilevata.)` |
| ✅ | `check_memory_pressure: pga_by_pdb_session.data.length=0 ≤ 50 (BUG-01)` |
| ❌ | `check_memory_pressure: .summary.distribuzione_per_pdb array vuoto o assente` |

### ORCHESTRAZIONE — diagnose_os_pressure: BUG-15 (io_collected → disk_io_await_p95_ms)
| Stato | Test |
|---|---|
| ✅ | `diagnose_os_pressure: output è JSON valido` |
| ✅ | `diagnose_os_pressure: .status = ok` |
| ✅ | `diagnose_os_pressure: .summary.livello_pressione_os non è null (bassa)` |
| ✅ | `diagnose_os_pressure: disk_io_await_p95_ms='null' (null o valore reale, non 0.0 falso)` |
| ✅ | `diagnose_os_pressure: os_type=unknown` |
