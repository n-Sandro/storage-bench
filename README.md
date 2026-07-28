# storage-bench.sh — Dokumentation

Werkzeugkette (fio-basiert) für Storage-Performance- und Latenztests unter Linux:
Messung ausführen, Ergebnisse vergleichen, während eines Umschwenks live beobachten,
und alles als HTML-Report mit Diagrammen darstellen.

## Bestandteile

| Datei | Rolle |
|---|---|
| `storage-bench.sh` | Hauptskript — alle vier Subcommands (`run`, `compare`, `watch`, `report`) |
| `generate-report.py` | Wird von `report` aufgerufen — liest JSON/CSV-Ergebnisse, erzeugt den HTML-Report |
| `report-template.html` | Layout/CSS/JS-Vorlage für den Report (Platzhalter, die `generate-report.py` befüllt) |
| `results/` | Alle Ergebnisse, ein Unterordner pro `--label` plus Vergleichs- und Report-Dateien auf oberster Ebene |

Alle drei Skripte liegen nebeneinander im selben Verzeichnis (dieses Repo, z.B.
`~/projects/storage-bench/`). `generate-report.py` und `report-template.html`
müssen im selben Verzeichnis wie `storage-bench.sh` bleiben, da der Pfad relativ
zum Skript aufgelöst wird (`$SCRIPT_DIR`) — das Verzeichnis selbst kann beliebig
verschoben oder per `git clone` auf einen anderen Server kopiert werden, ohne
dass Code angepasst werden muss.

---

## Inhaltsverzeichnis

1. [Voraussetzungen](#voraussetzungen)
2. [Portabilität — andere Linux-Server](#portabilität--andere-linux-server)
3. [Sicherheitsmodell](#sicherheitsmodell)
4. [Subcommand: run](#subcommand-run)
5. [Subcommand: compare](#subcommand-compare)
6. [Subcommand: watch](#subcommand-watch--messung-während-eines-umschwenks)
7. [Subcommand: report](#subcommand-report--html-report-mit-diagrammen)
8. [Berechnung der Kennzahlen](#berechnung-der-kennzahlen)
9. [Aufräumverhalten & --force](#aufräumverhalten----force)
10. [Alle Ergebnisdateien im Überblick](#alle-ergebnisdateien-im-überblick)
11. [Empfohlene Abläufe](#empfohlene-abläufe)
12. [Interna für Anpassungen](#interna-für-anpassungen-generate-reportpy--report-templatehtml)
13. [Bekannte Grenzen](#bekannte-grenzen)

---

## Voraussetzungen

Werden vom Skript **nicht automatisch installiert** — bewusst, damit nichts ungefragt
am System verändert wird. Bei fehlender Abhängigkeit bricht das Skript mit einer
Meldung ab (außer im `--dry-run`, der auch ohne `fio`/`jq` funktioniert).

| Tool | Gebraucht für | Installation (Beispiele) |
|---|---|---|
| `fio` (≥ 3.x empfohlen) | `run`, `watch` | `apt install fio` · `dnf install fio` (ggf. EPEL nötig) · `pacman -S fio` |
| `jq` | `run`-Zusammenfassung, `compare` | `apt install jq` · `dnf install jq` |
| `python3` (nur Standardbibliothek) | `report` | so gut wie überall vorinstalliert |
| `smartctl` (optional) | SMART-Snapshot bei `run --device` | Paket `smartmontools` |
| `libaio` (Laufzeitbibliothek) | fio-Engine `libaio` (Default) | meist Abhängigkeit von `fio`, sonst `libaio1`/`libaio` nachinstallieren |

Kein Internetzugriff zur Laufzeit nötig — alles läuft lokal, auch der HTML-Report
lädt nichts von extern nach (kein CDN, keine Web-Fonts).

---

## Portabilität — andere Linux-Server

Das Skript nutzt nur POSIX-nahe Bash- und coreutils-Funktionen und läuft grundsätzlich
auf jeder gängigen Linux-Distribution. Ein paar Dinge vorher prüfen:

- **Paketmanager unterscheidet sich** (`apt`/`dnf`/`pacman`/`zypper`/`apk`) — das Skript
  meldet nur, was fehlt, installiert aber nichts selbst.
- **Alpine Linux (busybox)**: Standard-Shell ist `ash`, nicht `bash`; `date -d`, `dd`,
  `timeout` aus busybox verhalten sich teils anders als GNU-coreutils. Vorher gezielt
  testen, nicht einfach annehmen, dass es identisch läuft.
- **`--direct=1` (O_DIRECT)** wird von allen Tests standardmäßig genutzt — **niemals
  gegen `tmpfs`/`/dev/shm` testen.** Empirisch geprüft (Kernel 6.6): O_DIRECT schlägt
  dort nicht zuverlässig fehl, sondern lief anstandslos durch und lieferte ~27 GiB/s
  — offensichtlich RAM- statt Storage-Geschwindigkeit, aber ohne Fehlermeldung, die
  einen darauf hinweisen würde. Ältere Kernel gaben hier teils `EINVAL` (fio bricht
  dann mit Fehler ab) — verlass dich in keinem Fall darauf, dass ein falsches
  `--target` auf tmpfs auffliegt; das Testverzeichnis vorher selbst prüfen (`mount |
  grep <pfad>` bzw. `df -T <pfad>`).
  - in **Docker/Kubernetes** auf der beschreibbaren Container-Layer (overlay2) je nach
    Kernel-Version unzuverlässig — gegen einen **Bind-Mount oder ein echtes Volume**
    testen, nicht gegen den Container-Root.
- **Root-Rechte** nur für `run --device` (rohes Blockgerät) nötig. Der normale
  Datei-Modus (`--target`) läuft mit normalen User-Rechten, solange das Zielverzeichnis
  beschreibbar ist — wird vorab geprüft (`[ -w "$TARGET_DIR" ]`), damit ein Rechte-
  Problem (z.B. **NFS-Freigabe mit `root_squash`/falschem UID-Mapping**) sofort mit
  einer klaren Meldung auffällt statt erst mitten im fio-Lauf mit einem kryptischen
  `fstat`/`Permission denied`.
- **Freier Platz** wird ebenso vorab gegen `--size` geprüft (`df` am `--target`).
  Reicht der Platz nicht, bricht das Skript sofort mit einer klaren Meldung
  (benötigt vs. verfügbar) ab — statt dass fio erst mitten im Vorbelegen der
  Testdatei mit `err=28 ... No space left on device` abbricht, ohne zu sagen,
  wie viel eigentlich gefehlt hat.
- **fio-Version**: Der p99-Latenzwert wird aus dem JSON-Key `"99.000000"` gelesen
  (Format ab fio 3.x). Sehr alte fio-Versionen (2.x) könnten das anders benennen —
  dann zeigt p99 still `0` statt zu crashen. `fio --version` vorher prüfen.
- **Netzwerk-Storage in der Cloud** (AWS EBS, GCP Persistent Disk, Azure Disk) zeigt
  oft dasselbe Muster wie 9p-Mounts unter WSL: bei niedriger Queue-Tiefe kaum
  Unterschied zu lokalem SSD, bei hoher Parallelität bricht es ein — der Vergleich
  lohnt sich dort besonders.
- **Es ist ein echter Lastgenerator.** Auf geteilter/produktiver Infrastruktur die
  Defaults reduzieren (`--size 512M --runtime 10`), um andere Workloads nicht zu stören.

---

## Sicherheitsmodell

- Standardmäßig wird **nur eine Testdatei** in einem angegebenen Verzeichnis
  (`--target`) beschrieben — nie ein rohes Blockgerät.
- Ein rohes Gerät (`--device /dev/nvme1n1`) wird nur bei `run` unterstützt und
  **nur** zusammen mit dem expliziten Flag `--confirm-destructive` akzeptiert. Ohne
  dieses Flag bricht das Skript mit einer Fehlermeldung ab.
- `watch` unterstützt `--device` überhaupt nicht — während eines echten Umschwenks
  soll der Messlauf selbst kein zusätzliches Risiko einführen.
- `--dry-run` gibt bei `run` und `watch` alle fio-Kommandos aus, die ausgeführt
  würden, ohne sie zu starten. Kein I/O, keine Prozesse, keine Verzeichnisse werden
  angelegt außer einer Logzeile.
- `report` führt keinerlei I/O-Last aus — liest nur bereits vorhandene Ergebnisdateien.
- Ein existierendes Label wird bei `run`/`watch` **nicht** stillschweigend
  überschrieben — dafür ist explizit `--force` nötig (siehe
  [Aufräumverhalten](#aufräumverhalten----force)).
- **`--label` wird validiert:** darf kein `/` enthalten und nicht `.` oder `..`
  sein. `--label` landet direkt (unverändert) im Ergebnispfad
  `results/<label>/`, der bei `run`/`watch` per `rm -rf` geleert wird — ohne
  diese Prüfung könnte z.B. `--label ../../etc` den Ergebnisordner nach
  außerhalb von `results/` verlegen, und zwar schon beim allerersten Aufruf
  (nicht erst mit `--force`).
- **`--device` wird auf Existenz geprüft** (`[ -b "$DEVICE" ]`), bevor es zum
  eigentlichen (unwiderruflichen) fio-Aufruf kommt — ein vertippter Gerätepfad
  bricht dadurch sofort mit einer klaren Fehlermeldung ab, statt erst mitten im
  Lauf oder gegen das falsche Gerät zu laufen. Das prüft nur, dass der Pfad
  überhaupt ein Blockgerät ist — **nicht**, ob es das *richtige* ist. Vor jedem
  `--device`-Lauf selbst gegenchecken (`lsblk`, `blkid`), welches Gerät sich
  hinter dem Pfad verbirgt.
- **`report` escaped Label-/Pfad-Text im HTML** (Titel, Legende, Tabellen,
  Tooltips) — ein `--label` mit HTML/JS-Inhalt (z.B. versehentlich beim
  Copy-Paste) kann den generierten Report nicht mehr manipulieren, auch wenn
  der Report später geteilt wird.

---

## Subcommand: `run`

Führt sieben fio-Teiltests nacheinander aus und legt die Ergebnisse unter
`results/<label>/` ab:

| Test | fio-Parameter | Zweck |
|---|---|---|
| `seq_read` / `seq_write` | `bs=1M, iodepth=32` | Sequenzieller Durchsatz |
| `rand_read_iops` / `rand_write_iops` | `bs=4k, iodepth=32, numjobs=4` | Random-IOPS unter Last |
| `latency_read` / `latency_write` | `bs=4k, iodepth=1, ioengine=psync` | Reine Latenz ohne Queue-Effekte |
| `mixed_70r_30w` | `bs=4k, rwmixread=70, iodepth=16, numjobs=2` | Realistische Mischlast (z.B. DB-artig) |

**Sonderfall `mixed_70r_30w`:** Anders als die anderen drei Zeilen — die jeweils
*zwei separate* fio-Jobs sind (`seq_read` und `seq_write` sind zwei komplett
unabhängige Läufe, ebenso rand/latency) — ist `mixed_70r_30w` **ein einziger**
fio-Job, der gleichzeitig liest und schreibt. Report und Diagramme zeigen dafür
trotzdem zwei Zeilen ("Mischlast 70/30 — Lesen" / "— Schreiben"), damit sich die
Lese- und Schreibrichtung genauso vergleichen lässt wie bei den anderen Tests —
das sind aber Lese-/Schreib-Ergebnisse *aus demselben Lauf*, nicht zwei Läufe.

Alle Tests laufen mit `--direct=1` (Page-Cache wird umgangen, damit reale
Gerätewerte gemessen werden) und einer **fest eingestellten Rampe von 5 Sekunden**
(`--ramp_time=5`, nicht per Flag änderbar) vor jedem Teiltest — fio misst währenddessen
mit, wertet diese Anlaufphase aber nicht in Durchsatz/Latenz/IOPS. Ein Teiltest
dauert dadurch real `--runtime` + 5s, auch wenn nur `--runtime` in den Ergebnissen
auftaucht. Bei `watch` gibt es keine Rampe (ein einziger durchgehender Job).

**Beispiele:**

```bash
# Nicht-destruktiv, über Testdatei
./storage-bench.sh run --target /mnt/test --label baseline

# Rohes Gerät — nur mit explizitem Confirm-Flag
./storage-bench.sh run --device /dev/nvme1n1 --label baseline --confirm-destructive

# Nur anzeigen, was ausgeführt würde
./storage-bench.sh run --target /mnt/test --label baseline --dry-run
```

**Optionen:**

| Flag | Default | Bedeutung |
|---|---|---|
| `--target <dir>` | – | Verzeichnis für Testdatei |
| `--device <dev>` | – | Rohes Blockgerät (destruktiv) |
| `--confirm-destructive` | aus | Pflicht bei `--device` |
| `--label <name>` | – | Pflicht, Name des Ergebnis-Ordners |
| `--size <size>` | `4G` | Größe der Testdatei/des Testbereichs |
| `--runtime <sek>` | `30` | Laufzeit **pro Teiltest** |
| `--ioengine <engine>` | `libaio` | fio-I/O-Engine |
| `--force` | aus | Vorhandenes Label überschreiben (Ordner wird vollständig geleert) |
| `--dry-run` | aus | Nur simulieren |
| `-h`, `--help` | – | Hilfe anzeigen und beenden |

**Ergebnisdateien** unter `results/<label>/`:
- je Teiltest ein `<test>.json` (fio-Rohdaten) und `<test>.log`
- `summary.csv` — **automatisch generiert**, eine Zeile pro Test×Richtung:
  `label,test,direction,bw_MBps,iops,avg_lat_ms,p99_lat_ms`
- bei `--device` optional `smart-before.txt` / `smart-after.txt`

Am Ende druckt das Skript zusätzlich eine Text-Zusammenfassung (Bandbreite, IOPS,
Ø-Latenz, p99-Latenz je Test) auf dem Terminal.

---

## Subcommand: `compare`

Vergleicht zwei mit `run` erzeugte Labels und markiert Bandbreiten-Regressionen.

```bash
./storage-bench.sh compare baseline after-upgrade
```

Für jeden gemeinsamen Test (read/write) wird die Bandbreite gegenübergestellt und
die prozentuale Abweichung berechnet. Ein Rückgang von mehr als **10 %** wird als
`<-- REGRESSION` markiert.

**Ausgabedatei:** `results/compare_<label1>_vs_<label2>.csv` — **automatisch
generiert**, Spalten: `test,direction,bw_before_MBps,bw_after_MBps,delta_pct,regression`
(`regression` ist `ja`/`nein`).

Latenzwerte sind im Terminal-Output nicht enthalten — dafür direkt in den
`*.json`-Dateien unter `clat_ns` nachsehen (v.a. `latency_read.json` /
`latency_write.json`), oder den `report`-Subcommand nutzen, der Latenz mit anzeigt.

`compare` hat **kein** `--dry-run`, da es nur bereits vorhandene Ergebnisdateien
liest und nichts ausführt oder schreibt.

---

## Subcommand: `watch` — Messung während eines Umschwenks

Anders als `run`/`compare` (die einen Vorher/Nachher-Snapshot vergleichen), ist
`watch` für den Moment eines **laufenden** Storage-Umschwenks/Failovers gedacht:
ein durchgehender Messlauf ohne Lücken, plus unabhängige Ausfallerkennung.

```bash
./storage-bench.sh watch --target /mnt/test --label switchover-2026-07-24 --duration 1800
```

**Funktionsweise:**

1. **Ein einziger durchgehender fio-Job** über die komplette `--duration` (Default
   1800s): `randrw`, `rwmixread=70`, `bs=4k`, `iodepth=4` (bewusst niedrig, um den
   Umschwenk nicht zusätzlich zu belasten), `--continue_on_error=all` (bricht bei
   kurzen I/O-Fehlern während des Failovers nicht ab, sondern protokolliert weiter).
2. **Latenz-Zeitreihe:** `--write_lat_log` + `--log_avg_msec=1000` schreibt
   sekundengenaue Latenzwerte mit — ein reiner Durchschnitt über 30 Minuten würde
   einen kurzen Hänger verschlucken, die Zeitreihe zeigt ihn.
3. **Live-Status:** `--status-interval` (Default 5s) zeigt während des Laufs
   periodisch IOPS/Latenz auf dem Terminal. Da stdout hier durch `tee` läuft
   (keine echte TTY), reicht `--status-interval` allein nicht — fio würde die
   periodische Anzeige sonst standardmäßig unterdrücken; `--eta=always` +
   `--eta-newline` erzwingen sie trotzdem.
4. **Unabhängiger Heartbeat:** parallel zu fio läuft alle `--heartbeat-interval`
   Sekunden (Default 1s) ein einzelner `dd`-Schreibtest mit `timeout`. Überschreitet
   er `--heartbeat-timeout` (Default 2s), wird ein `STALL` in `heartbeat.log`
   geloggt — unabhängig davon, ob fio selbst gerade blockiert (z.B. weil ein LIF
   minutenlang nicht erreichbar ist und fios eigener I/O-Call im Kernel hängt).
   Bei jedem Wechsel OK→STALL bzw. STALL→OK erscheint zusätzlich sofort eine
   Zeile auf dem Terminal, nicht nur in der Log-Datei.
5. **Nach Laufende:** automatische Anomalie-Timeline — alle Latenzausreißer über
   `--spike-threshold` (Default 100ms) und alle Heartbeat-Stalls, jeweils mit
   geschätzter Wanduhrzeit, damit man sie gegen den tatsächlichen
   Failover-Zeitstempel (multipathd, dmesg, Storage-Array-Log) abgleichen kann.

**Optionen:**

| Flag | Default | Bedeutung |
|---|---|---|
| `--target <dir>` | – | Pflicht, Verzeichnis für Testdatei |
| `--label <name>` | – | Pflicht, Name des Beobachtungsfensters |
| `--duration <sek>` | `1800` | Gesamtdauer des durchgehenden Laufs |
| `--status-interval <sek>` | `5` | Live-Status-Ausgabe-Intervall |
| `--heartbeat-interval <sek>` | `1` | Abstand zwischen Puls-Checks |
| `--heartbeat-timeout <sek>` | `2` | Ab wann ein Puls als hängend gilt |
| `--spike-threshold <ms>` | `100` | Latenzschwelle für Anomalie-Markierung |
| `--size <size>` | `4G` | Größe der Testdatei |
| `--ioengine <engine>` | `libaio` | fio-I/O-Engine für den Hauptjob |
| `--force` | aus | Vorhandenes Label überschreiben (Ordner wird vollständig geleert) |
| `--dry-run` | aus | Nur simulieren |
| `-h`, `--help` | – | Hilfe anzeigen und beenden |

**Ergebnisdateien** unter `results/<label>/`: `watch-status.log` (kompletter
Live-Status-Verlauf inkl. fio-Endstatistik, da alles über stdout/tee läuft —
siehe oben), `<label>_lat.1.log` (Completion-Latenz-
Zeitreihe — das ist die Datei, die `analyze_watch` für die Anomalie-Timeline liest;
`--write_lat_log` schreibt daneben noch `<label>_clat.1.log` und `<label>_slat.1.log`
mit, die aber von `storage-bench.sh` selbst nicht ausgewertet werden),
`heartbeat.log` (Puls-Protokoll), `start_epoch.txt` / `start_time.txt`
(Referenzzeitpunkt für die Wanduhr-Umrechnung). Kein `summary.csv` — `watch` ist
für die Anomalie-Timeline gedacht, nicht für den `report`-Vergleich.

**Praxis-Tipp:** Den tatsächlichen Umschwenk-/Failover-Zeitpunkt separat notieren
(oder `multipathd -ll` / `dmesg -w` / Storage-Array-Log parallel mitlaufen lassen)
— die Anomalie-Timeline liefert nur die Symptome, die Korrelation mit dem Auslöser
muss man manuell herstellen.

---

## Subcommand: `report` — HTML-Report mit Diagrammen

Erzeugt aus einem oder mehreren `run`-Ergebnissen (plus allen dazu passenden
`compare`-CSVs) eine einzelne, in sich geschlossene HTML-Datei mit Diagrammen,
Vergleichstabelle und Glossar. Keine externen Abhängigkeiten (kein CDN, kein
Web-Font) — die Datei lässt sich per Doppelklick in jedem Browser öffnen, auch
offline.

```bash
# alle in results/ gefundenen Labels einbeziehen
./storage-bench.sh report

# gezielt bestimmte Labels
./storage-bench.sh report home tmp mnt-c mnt-d --out results/report.html
```

**Optionen:**

| Argument | Default | Bedeutung |
|---|---|---|
| `[label ...]` | alle Labels mit vorhandenen `*.json` in `results/` | welche Verzeichnisse einbeziehen |
| `--out <pfad>` | `results/report.html` | Ausgabedatei |

**Was der Report zeigt:**

1. **Kopfzeile** — fio-Version, Erzeugungszeitpunkt, einbezogene Labels (alles aus
   den fio-JSON-Dateien gelesen, nicht hartkodiert).
2. **Auto-generierte Kennzahlen-Kacheln** — größter und kleinster Durchsatz-Unterschied
   über alle Tests hinweg, Anzahl der Verzeichnisse (mit den **echten `--target`/
   `--device`-Pfaden** als Detail, nicht den Labels — aus dem `filename` in den
   fio-Job-Options zurückgerechnet), und eine **Aufrufparameter-Kachel**
   (`--size`/`--runtime`/`--ioengine`, auch wenn nur Default-Werte) als kompaktes
   Schlüssel/Wert-Raster. Weichen `--size`/`--runtime` zwischen Labels ab, wird die
   Kachel stattdessen zu einer Warnung mit Verweis auf die Testparameter-Tabelle.
   Alles aus den Daten berechnet, nicht von Hand geschrieben — bleibt also korrekt,
   egal welche Labels man übergibt.
3. **Farb-Legende** — ein Swatch pro Label, feste Reihenfolge aus einer
   farbenblind-sicher validierten Palette (max. 8 Labels gleichzeitig, danach müsste
   die Palette erweitert werden). **Klickbar:** ein Klick auf eine Kachel blendet
   dieses Verzeichnis in beiden Diagrammen aus (Kachel wird abgeblendet, Skala
   rechnet sich neu auf die verbliebenen sichtbaren Werte) und filtert gleichzeitig
   die Umschalter der Vergleichstabelle — ein Paar verschwindet dort aus der
   Auswahl, sobald eines seiner beiden Labels ausgeblendet ist. Nützlich, um einen
   extremen Ausreißer (z.B. eine viel langsamere Freigabe) kurzzeitig aus der Skala
   zu nehmen, damit die übrigen Werte besser vergleichbar werden.
4. **Zwei getrennte Glossar-Bereiche** (aufklappbar, nebeneinander ab ausreichender
   Fensterbreite) — "Was bedeuten die Kennzahlen?" (BW, IOPS, Ø-Latenz, p99-Latenz,
   Queue Depth, `direct=1`, `ioengine` sync/async) und "Was wird hier getestet?"
   (Klartext-Erklärung jeder tatsächlich im Report enthaltenen Testart, jeder
   Eintrag für sich verständlich). Nur die Begriffe/Testarten, die auch vorkommen.
5. **Zwei Diagramme** (Durchsatz, Latenz) — horizontale Balken, logarithmische
   Skala (nötig, da Werte über mehrere Größenordnungen streuen können), mit
   Hover-Tooltip und direkt angeschriebenem Exaktwert neben jedem Balken.
6. **Vergleichstabelle** — falls passende `compare_<a>_vs_<b>.csv`-Dateien für die
   übergebenen (und aktuell nicht über die Legende ausgeblendeten) Labels
   existieren, als Umschalter (Buttons) zwischen den Label-Paaren, mit
   Delta-Balken und REGRESSION/OK-Pills. Fehlen compare-Läufe komplett, zeigt der
   Report einen Hinweis mit dem passenden `compare`-Befehl; sind alle passenden
   Paare gerade über die Legende ausgeblendet, ein separater Hinweis dafür.
7. **Testparameter** (aufklappbar) — eine Zeile pro Testart mit den tatsächlich
   verwendeten fio-Optionen (`rw`, `bs`, `iodepth`, `numjobs`, `ioengine`, `size`,
   `direct`, `runtime`, `ramp_time`), direkt aus den "job options" im fio-JSON
   gelesen. Weicht ein Label bei einer Testart davon ab (z.B. anderes `--size`
   oder `--ioengine`), erscheint das separat als kurze Abweichungsliste darunter
   — nur dann, sonst steht dort "Keine Abweichungen". So fällt sofort auf, wenn
   zwei Labels gar nicht wirklich vergleichbar sind.
8. **Rohdaten-Tabelle** (aufklappbar) — alle Werte als klassische Tabelle,
   entspricht `combined_summary.csv`.

**Theme:** folgt automatisch dem System-Farbschema (hell/dunkel) des Browsers.

**Robustheit:** Eine einzelne beschädigte `*.json` (z.B. weil ein vorheriger `run`
per Ctrl-C mitten im Schreiben der fio-Ausgabe unterbrochen wurde) lässt den
Report nicht abstürzen — die Datei wird mit einer Warnung auf stderr übersprungen,
der Rest des Labels bzw. der übrigen Labels wird trotzdem ausgewertet.

---

## Berechnung der Kennzahlen

Alle Werte (Terminal, `summary.csv`, `report.html`) kommen aus **derselben Quelle**
— den vier fio-Rohwerten in `<test>.json` unter `.jobs[0].read.*` bzw.
`.jobs[0].write.*` — und durchlaufen dieselben zwei Umrechnungen, nur mit
unterschiedlicher Rundung je nach Ausgabestelle:

| Rohwert (fio-JSON) | Einheit | Umrechnung | Ergebnis |
|---|---|---|---|
| `.bw` | KiB/s | `/ 1024` | MB/s¹ |
| `.iops` | IOPS | – (keine Umrechnung) | IOPS |
| `.clat_ns.mean` | Nanosekunden | `/ 1000000` | Ø-Latenz in ms |
| `.clat_ns.percentile["99.000000"]` | Nanosekunden | `/ 1000000` | p99-Latenz in ms |

¹ Streng genommen MiB/s (Division durch 1024, nicht 1000) — im gesamten Skript
und Report aus Lesbarkeit als "MB/s" bezeichnet.

**Drei unabhängige Konsumenten derselben Formel, unterschiedlich gerundet:**

1. **Terminal-Ausgabe** (`parse_metric()`, von `run` am Ende gedruckt): BW und
   IOPS ganzzahlig gerundet, Latenzwerte auf 2 Nachkommastellen (`(...)*100|round/100`
   — der `jq`-Trick, um auf 2 Dezimalstellen zu runden, da `jq` kein natives
   `round(n)` mit Nachkommastellen kennt).
2. **`summary.csv`** (`csv_metric_values()`): **exakt dieselben Formeln, aber
   ungerundet** — bewusst andere Rundung als das Terminal, damit die CSV für
   Weiterverarbeitung/eigene Auswertung nicht durch Rundungsfehler verfälscht wird.
3. **`report.html`**: zweistufig gerundet — `generate-report.py` rundet beim Bau
   von `window.__REPORT_DATA__` (BW auf 2, IOPS auf 1, Latenzwerte auf 3
   Nachkommastellen), das Template rundet beim Anzeigen nochmal (Durchsatz-Diagramm
   0, Latenz-Diagramm 2 Nachkommastellen; Rohdaten-Tabelle: Latenzspalten
   `toFixed(2)`, BW/IOPS-Spalten unverändert aus den schon von Python gerundeten
   Werten).

**Konkret für "Mischlast 70/30 — Lesen":** Quelle ist `.jobs[0].read.*` aus
`mixed_70r_30w.json` — dieselben vier Formeln wie oben, angewandt auf die
Lese-Hälfte der Job-Statistik (siehe [Sonderfall `mixed_70r_30w`](#subcommand-run)
weiter oben: ein Job, aber read/write werden von fio getrennt gezählt). Keine
zusätzliche 70/30-Rechnung nötig — die Aufteilung hat fio schon während des Laufs
selbst umgesetzt, indem es tatsächlich ~70% Lese- und ~30% Schreibanfragen
ausgeführt hat; die Auswertung liest nur die bereits getrennten Ergebnisse ab.

**`compare`s Delta-Berechnung** (separat, nur Bandbreite): `awk` rechnet
`((bw_after - bw_before) / bw_before) * 100` mit voller Genauigkeit auf den rohen
KiB/s-Werten (macht rechnerisch keinen Unterschied zu MB/s, da es ein Verhältnis
ist), das Ergebnis wird erst danach auf 1 Nachkommastelle gerundet (`printf
"%.1f"`). REGRESSION-Schwelle: `delta_pct < -10`.

---

## Aufräumverhalten & `--force`

Sowohl `run` als auch `watch` schützen ein bestehendes Label vor versehentlichem
Überschreiben:

- Existiert `results/<label>/` bereits und enthält Dateien, **bricht das Skript ab**
  mit einer Fehlermeldung — ohne `--force` geht kein vorheriger Lauf verloren, auch
  nicht durch ein wiederverwendetes oder verwechseltes Label.
- Mit **`--force`** wird der Ordner **komplett geleert** (`rm -rf` + neu anlegen),
  bevor die neuen Tests hineinschreiben. Bewusst ein vollständiges Leeren statt nur
  gleichnamige Dateien zu ersetzen — sonst könnten Dateien von einem älteren Lauf
  mit anderem Testumfang (z.B. nach einem Skript-Update mit geänderten Teiltests)
  unbemerkt liegen bleiben.
- `--dry-run` zeigt an, ob der Ordner neu angelegt oder geleert **würde**, ohne
  etwas zu verändern.

**Interrupt-sichere Testdatei-Bereinigung:** Bricht ein `run`- oder `watch`-Lauf
per Ctrl-C, Absturz **oder ein fehlschlagendes `fio`** (z.B. Permission-Fehler auf
einer NFS-Freigabe) mitten in einem Teiltest ab, entfernt ein Trap (`EXIT INT
TERM`) die große (`--size`) Testdatei trotzdem automatisch aus `--target` — sie
bleibt nicht als Karteileiche liegen. Bei `run` beendet Ctrl-C dabei **die gesamte
Testsuite** (nicht nur den aktuellen Teiltest — ein Trap auf `INT`/`TERM` ohne
explizites `exit` würde bash sonst nach dem Aufräumen einfach mit dem nächsten
Teiltest weitermachen lassen). Bei `watch` läuft das Skript nach Ctrl-C dagegen
bewusst bis zur Anomalie-Timeline durch, damit die Auswertung des bisherigen
Beobachtungsfensters nicht verloren geht.
Die Testdatei-Pfade (`TESTFILE` bei `run`/`watch`, `HB_PID` beim Heartbeat-Prozess
in `watch`) sind bewusst **globale, nicht lokale** Shell-Variablen: Schlägt `fio`
fehl, lösen `set -e`/`pipefail` den `EXIT`-Trap aus, während Bash die lokale
Funktions-Scope bereits verlassen hat — eine `local`-Variable wäre dann im
Trap-Body unter `set -u` "unbound variable", und der Trap crasht, **bevor** er
aufräumen kann. Genau das würde die eigentlich beabsichtigte Absicherung im
Fehlerfall aushebeln.

**Kein Vermischen alter/neuer Daten bei `watch`:** `heartbeat.log` und
`watch-status.log` werden bei jedem Lauf neu angelegt (nicht angehängt) — ein
früherer Bug führte dazu, dass ein wiederholter `watch`-Lauf mit demselben Label
alte und neue Heartbeat-Zeitstempel in derselben Datei vermischte und dadurch die
Anomalie-Timeline verfälschte. Da der Ordner ohnehin vor jedem Lauf geleert wird
(s.o.), kann das jetzt nicht mehr passieren.

```bash
# Bricht ab, falls 'baseline' schon existiert:
./storage-bench.sh run --target /mnt/test --label baseline

# Bewusst überschreiben:
./storage-bench.sh run --target /mnt/test --label baseline --force
```

---

## Alle Ergebnisdateien im Überblick

```
results/
├── <label>/
│   ├── seq_read.json / .log
│   ├── seq_write.json / .log
│   ├── rand_read_iops.json / .log
│   ├── rand_write_iops.json / .log
│   ├── latency_read.json / .log
│   ├── latency_write.json / .log
│   ├── mixed_70r_30w.json / .log
│   ├── summary.csv                       ← von `run`
│   ├── smart-before.txt / smart-after.txt  ← nur bei --device
│   │
│   │  (bei `watch` stattdessen:)
│   ├── watch-status.log, heartbeat.log
│   ├── <label>_lat.1.log                 ← wird von analyze_watch ausgewertet
│   ├── <label>_clat.1.log / _slat.1.log  ← von fio mitgeschrieben, ungenutzt
│   ├── heartbeat.log
│   └── start_epoch.txt / start_time.txt
│
├── compare_<a>_vs_<b>.csv                ← von `compare`
├── combined_summary.csv                   ← optional von Hand zusammengeführt
│                                             (siehe Beispiel-Workflow unten)
└── report.html                            ← von `report`
```

---

## Empfohlene Abläufe

### A) Klassischer Vorher/Nachher-Vergleich (z.B. Storage-Upgrade)
```bash
./storage-bench.sh run --target /mnt/test --label vor-upgrade
# … Upgrade durchführen …
./storage-bench.sh run --target /mnt/test --label nach-upgrade
./storage-bench.sh compare vor-upgrade nach-upgrade
./storage-bench.sh report vor-upgrade nach-upgrade
```

### B) Messung während eines Umschwenks/Failovers
1. Optional vorher: `run --label vor-umschwenk` als Referenzwert.
2. `watch --label umschwenk-<datum> --duration <geschätzte Dauer + Puffer>`
   **starten, bevor** der Umschwenk ausgelöst wird.
3. Exakten Auslöse-Zeitpunkt separat notieren (Wanduhr).
4. Nach Laufende: Anomalie-Timeline mit dem notierten Zeitpunkt abgleichen.
5. Optional danach: `run --label nach-umschwenk` + `compare` + `report` für den
   klassischen Vergleich obendrauf.

### C) Mehrere Verzeichnisse/Mountpoints gegeneinander testen
(So haben wir es für den WSL-Vergleich `$HOME` vs. `/tmp` vs. `/mnt/c` vs. `/mnt/d`
gemacht.)
```bash
# Nicht per dynamischem Variablennamen (bash kann Variablen wie "$TARGET_FÜR_$label"
# nicht indirekt auflösen — das wäre nur eine Verkettung zweier leerer/falscher
# Werte), sondern über ein assoziatives Array:
declare -A targets=( [home]="$HOME" [tmp]="/tmp" [mnt-c]="/mnt/c" [mnt-d]="/mnt/d" )
for label in "${!targets[@]}"; do
  ./storage-bench.sh run --target "${targets[$label]}" --label "$label"
done
./storage-bench.sh compare home tmp
./storage-bench.sh compare tmp mnt-c
./storage-bench.sh report home tmp mnt-c mnt-d
```
Eine kombinierte `combined_summary.csv` über alle Labels ist kein eingebautes
Feature von `run` (das schreibt nur pro Label) — lässt sich aber mit einer Zeile
nachbauen:
```bash
{ head -1 results/home/summary.csv;
  for l in home tmp mnt-c mnt-d; do tail -n +2 "results/$l/summary.csv"; done
} > results/combined_summary.csv
```

---

## Interna für Anpassungen (generate-report.py / report-template.html)

Nur relevant, wenn du den Report selbst erweitern willst.

- **Platzhalter im Template**, die `generate-report.py` per String-Replace füllt:
  `__REPORT_TITLE__`, `/*__SERIES_CSS_LIGHT__*/`, `/*__SERIES_CSS_DARK__*/`,
  `/*__REPORT_DATA__*/`. Kein Templating-Framework, bewusst simpel gehalten.
- **`window.__REPORT_DATA__`** ist der einzige Datenkanal vom Python-Skript ins
  Frontend — ein JSON-Blob mit `meta`, `locations`, `tests`, `raw`, `paramsCommon`,
  `paramsDeviations`, `paramFields`, `compares`, `stats`, `callParams`, `glossary`,
  `footer`. Alles JS-seitige Rendern (Charts, Legende, Tabellen, Testparameter,
  Aufrufparameter-Kachel, Glossar) liest ausschließlich daraus.
- **`PARAM_FIELDS`** in `generate-report.py`: welche fio-Job-Options in der
  Testparameter-Tabelle erscheinen. `paramsCommon` enthält je Testart den über alle
  Labels häufigsten Wert (`collections.Counter`), `paramsDeviations` nur die
  tatsächlich abweichenden (Label, Test, Feld, Wert, erwarteter Wert) — neue Felder
  hier landen automatisch auch in der Tabellenspalte im Template (`FIELD_LABELS`
  dort ergänzen für eine lesbare Spaltenüberschrift, sonst wird der Feldname roh
  angezeigt). `callParams` (`size`/`runtime`/`ioengine`/`direct`/`deviates`) speist
  die Aufrufparameter-Kachel und nutzt dieselbe Mehrheits-/Abweichungslogik.
- **XSS-Escaping:** Alles, was letztlich aus `--label`/`--target` stammt (Labels,
  Zielpfade), wird escaped, bevor es per `innerHTML` eingesetzt wird — im Python-Teil
  via `html.escape()` (Titel, Footer-CSV-Liste), im Template über die `esc()`-
  Hilfsfunktion (Legende, Tooltip, Tabellen, Kacheln). Neue Stellen, die Label-/
  Pfad-Text rendern, brauchen dasselbe Escaping — sonst kann ein `--label` mit
  HTML/JS-Inhalt den (ggf. geteilten) Report manipulieren.
- **`PALETTE`** in `generate-report.py`: acht fest geordnete Farbpaare (hell/dunkel),
  farbenblind-sicher geprüft. Reihenfolge nicht verändern, ohne die Prüfung erneut
  durchzuführen — die Validierung hängt an dieser exakten Reihenfolge.
- **`NAME_MAP`** / **`TEST_GLOSSARY`** / **`METRIC_GLOSSARY`**: Klartext-Namen und
  -Erklärungen für Testarten bzw. Kennzahlen. Neue fio-Teiltests im Hauptskript
  brauchen hier einen zusätzlichen Eintrag, sonst erscheinen sie im Report nur mit
  ihrem internen Test-Key statt Klartext. Jeder `TEST_GLOSSARY`-Eintrag muss für
  sich verständlich sein (kein "Wie X, nur schreibend") — man kann direkt zu einem
  einzelnen Eintrag springen, ohne die anderen gelesen zu haben.
- **`hiddenLocs`** (Template-JS): Set der über die Legende ausgeblendeten
  Verzeichnis-Keys. `renderCharts()` und `renderCompareSection()` sind eigene
  Funktionen (nicht nur einmalige Inline-Blöcke), genau damit sie bei jedem
  Legende-Klick neu aufgerufen werden können, statt den Report einmalig beim Laden
  zu rendern.
- **Farbskalen der Diagramme** sind logarithmisch und werden pro Diagramm
  dynamisch aus den tatsächlich vorkommenden Werten berechnet (`computeBounds()`
  im Template-JS) — kein hartkodiertes Minimum/Maximum.

---

## Bekannte Grenzen

- `compare` vergleicht nur die Bandbreite automatisch in der CSV; der `report`
  zeigt zusätzlich Latenz in den Balkendiagrammen, aber die Compare-Tabelle im
  Report bleibt auf Bandbreiten-Deltas beschränkt (Spiegel der CSV-Struktur).
- Die Wanduhr-Zuordnung in `watch` ist eine Schätzung auf Sekundenbasis
  (`start_epoch + Zeitversatz`), keine hochpräzise NTP-synchronisierte Messung.
- Der Heartbeat in `watch` nutzt eine eigene kleine Datei (`<testfile>.hb`) im
  selben Verzeichnis wie die fio-Testdatei — beide teilen sich denselben
  Mountpoint/Pfad, sind aber unabhängige Dateien.
- Bei `numjobs=1` (Default bei `watch`) heißt die Latenz-Logdatei
  `<label>_lat.1.log`; bei höherem `numjobs` würde sich das Namensschema ändern —
  aktuell ist `watch` fest auf `numjobs=1` gesetzt.
- `--force` leert das komplette Label-Verzeichnis, nicht nur die vom aktuellen Lauf
  betroffenen Dateien — falls dort manuell eigene Zusatzdateien abgelegt wurden,
  gehen die beim nächsten `--force`-Lauf mit verloren.
- `report` unterstützt maximal 8 Labels gleichzeitig (Grenze der validierten
  Farbpalette). Für mehr Verzeichnisse: mehrere Reports mit Teilmengen erzeugen.
- `report` bezieht `watch`-Ergebnisse nicht ein — er liest nur `run`-Ergebnisse
  (`*.json` in `results/<label>/`) und passende `compare`-CSVs.
