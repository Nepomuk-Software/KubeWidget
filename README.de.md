# KubeContext für Omarchy

Zeigt den aktiven `kubectl`-Context in der Bar, wechselt ihn per Klick (oder
einem Rechtsklick-Picker, der nie mit einem Cluster spricht), setzt den
aktuellen Namespace und gibt einen kurzen Überblick über den gewählten Cluster.

*(English version: [README.md](README.md) — die maßgebliche Fassung.)*

![Vorschau](preview.png)

- **Bar** — der Name des aktuellen Contexts neben einem Kubernetes-Icon, damit
  nie geraten werden muss, gegen welchen Cluster der nächste Befehl läuft.
  Optional der Namespace dazu. Färbt sich, wenn die letzte Probe den Cluster
  unerreichbar fand oder Pods nicht laufen — ohne bei geschlossenem Panel eine
  neue Probe zu starten.
- **Picker** — Rechtsklick auf das Icon wechselt den Context. Das ist ein
  lokaler Write; kein API-Server wird kontaktiert.
- **Contexts** — jede Kubeconfig-Datei direkt in `~/.kube` (nicht `cache/`),
  gruppiert nach Datei. Zwei Files mit Context `default` bleiben zwei Zeilen.
  Die Liste ist ein lokales YAML/JSON-Parse — `kubectl` läuft nicht gegen
  Extra-Dateien, damit ein Credential-`exec`-Plugin in einer Datei, die du
  nicht gewählt hast, beim Öffnen des Panels nicht startet.
  Wechsel in `~/.kube/config` erben neue Shells. Wechsel in einer anderen Datei
  bindet **dieses Widget** (`--kubeconfig`); neue Terminals bleiben auf der
  Default-Datei.
- **Cluster** — bereite Nodes, Rollen, laufende Pods, Namespaces, Server- und
  Kubelet-Version, dazu CPU und Speicher im Mittel, sofern ein Metrics-Server
  antwortet. Klick auf den Namespace wählt einen anderen; das ist
  `kubectl config set-context --current --namespace=`, dieselbe Datei wie beim
  Context-Wechsel.

## Warum es nicht im Weg steht

Eine kubeconfig zu lesen ist ein lokaler Dateizugriff und kostet nichts. Das
Label in der Bar folgt einem Context, den du im Terminal gewechselt hast, daher
innerhalb von Sekunden.

Mit einem Cluster zu reden ist das Gegenteil. Cluster scheitern auf mehr Arten
als sie gelingen — ein Credential-Plugin, das einen Fehler wirft, ein privater
Endpunkt, dessen DNS nicht auflöst, ein API-Server, der schlicht nie antwortet —
und dieses Widget läuft in dem Prozess, der deinen Desktop zeichnet. Also:

- Solange das Panel zu ist, verlässt nichts die Maschine.
- Extra-Kubeconfigs werden ohne `kubectl` gelesen. Nur der gebundene Context
  wird geprobt (`kubectl get --raw /version`), und nur bei offenem Panel.
- Jeder Aufruf ist doppelt begrenzt, durch `kubectl --request-timeout` und durch
  ein äußeres `timeout`. Ein toter Cluster kostet damit Sekunden statt ewig.
- Ein Cluster, der nicht antwortet, wird als nicht erreichbar gemeldet, nie als
  leerer Cluster mit null Nodes und null Pods.
- Ein `kind-*`-Context, dessen Node-Container nicht läuft, wird als **Kind
  cluster is not running** gemeldet, nicht als generisches API-Timeout. Der
  Check ist lokal (`docker inspect` / `kind get nodes`) und läuft nur bei
  offenem Panel.

## Voraussetzungen

`kubectl` im `PATH` und eine lesbare kubeconfig. Sonst nichts. Fehlt `kubectl`,
sagt das Panel das, statt eine leere Liste zu zeigen.

## Installation

```bash
omarchy plugin add https://github.com/Nepomuk-Software/KubeWidget.git --enable
```

## Deinstallation

```bash
omarchy plugin remove io.github.nepomuk-software.kubecontext
```

Das nimmt das Widget aus der Bar und löscht das Plugin-Verzeichnis. Mehr ist
nicht rückgängig zu machen: Es legt keine Dateien außerhalb dieses
Verzeichnisses an, keine Dienste und keinen privilegierten Helfer. Kind-Nodes,
die es gestartet oder gestoppt hat, bleiben in dem Zustand, in dem du sie
gelassen hast. Dasselbe gilt für die kubeconfig-Writes.

## Was es schreibt

Drei Dinge, alle nur auf ausdrücklichen Klick, immer gegen die Datei der Zeile:

- `kubectl --kubeconfig=<file> config use-context <name>` — setzt
  `current-context` in dieser Datei
- `kubectl --kubeconfig=<file> config set-context --current --namespace=<name>`
  — setzt den Namespace des aktuellen Contexts in dieser Datei
- `docker start` / `docker stop` der Kind-Node-Container mit Label
  `io.x-k8s.kind.cluster=<name>` (und `cloud-provider-kind-<name>`, falls
  vorhanden). Kind hat kein start/stop; das ist das lokale Äquivalent. Nur
  für `kind-*`-Contexts, deren Container wirklich da sind.

Änderungen an der Default-Kubeconfig (`~/.kube/config` bzw. dem ersten
`KUBECONFIG`-Eintrag) erben neue Shells. Änderungen an einer anderen Datei
bleiben dort; das Widget hält `--kubeconfig` darauf, bis du einen Context in
einer anderen Datei wählst. Neue Terminals bleiben auf kubectl-Default. Das
Widget kopiert keine Cluster nach `~/.kube/config`, exportiert kein
`KUBECONFIG` und ersetzt `~/.kube/config` nicht durch einen Symlink.

Docker start/stop passiert nie von allein. Alles andere ist lesend. Der
Rechtsklick-Picker wechselt nur den Context und spricht weder Cluster noch
Docker an.

## Bedienung

| Ort | Aktion |
|---|---|
| Bar, links | Panel auf/zu |
| Bar, rechts | Context wählen (kein Netz) |
| Bar, mitte | kubeconfig neu lesen; voller Refresh, wenn das Panel offen ist |
| Panel, Klick auf einen Context | dorthin wechseln |
| Panel, Start / Stop Kind cluster | `docker start` / `docker stop` der lokalen Kind-Nodes |
| Panel, Klick auf Namespace | Namespaces des aktuellen Clusters, Klick setzt |
| Panel, `n` | Namespace-Liste auf/zu |
| Panel, ↑ ↓ / Enter | Context oder Namespace wählen |
| Panel, `r` | neu einlesen |
| Panel, Esc | Panel schließen |

## Einstellungen

`omarchy bar set io.github.nepomuk-software.kubecontext <key> <value>`

| Key | Vorgabe | Wirkung |
|---|---|---|
| `showContext` | `true` | Context-Name neben dem Icon; auf vertikalen Bars ohne Wirkung |
| `showNamespace` | `false` | hängt `/namespace` an das Bar-Label |
| `maxLabel` | `18` | längere Namen werden in der Bar gekürzt |
| `contextIntervalSec` | `5` | wie oft die kubeconfig neu gelesen wird (lokal, kein Netz) |
| `probeIntervalSec` | `30` | wie oft der gebundene Cluster kontaktiert wird, solange das Panel offen ist |

## IPC

```
omarchy-shell io.github.nepomuk-software.kubecontext <method> [context]
```

| Methode | Tut |
|---|---|
| `open` `close` `toggle` | das Popup |
| `current` | Name des aktiven Contexts |
| `kubeconfig` | die Kubeconfig-Datei, an die das Widget gebunden ist |
| `rows` | jede Zeile als `name<TAB>file`, `*` an der gebundenen |
| `namespace` | Namespace des aktuellen Contexts |
| `use <context>` | Context in der gebundenen Datei, oder der eindeutige Name; `name@file` bei gleichem Namen in zwei Dateien |
| `useIn <file> <context>` | dasselbe, Datei als eigenes Argument |
| `useNamespace <name>` | Namespace des aktuellen Contexts setzen |
| `kindStart` `kindStop` | Kind-Node-Container des aktuellen `kind-*`-Contexts starten oder stoppen |
| `refresh` | kubeconfig neu lesen; Probe des gebundenen Contexts und Überblick nur bei offenem Panel |
| `status` | `<context> reachable <version> nodes=r/t pods=r/t ns=n`, sonst `unreachable`, `unprobed`, `no kubectl` |

## Lizenz

MIT — siehe [LICENSE](LICENSE). Plugins laufen unsandboxed im Omarchy-Shell-
Prozess; lies den Code, bevor du ihn installierst.
